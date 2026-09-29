#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsPrivateDirectoryError: Error, LocalizedError, Sendable {
    case invalid(String)
    case native(String, DWORD)

    var errorDescription: String? {
      switch self {
      case .invalid(let message): message
      case .native(let operation, let code): "\(operation) failed (Windows error \(code))."
      }
    }
  }

  /// Keeps the private directory and its ancestry stable for its consumer's lifetime.
  final class WindowsPrivateDirectory: @unchecked Sendable {
    // These non-inherited kernel handles are immutable, never exposed and closed only on deinit.
    private let handles: [HANDLE]
    private let security: PrivateSecurity
    private let ancestor: WindowsPrivateDirectory?
    private let requiresPrivateDACL: Bool
    let url: URL

    convenience init(_ url: URL) throws {
      try self.init(url, createMissing: true, ancestor: nil, requiresPrivateDACL: true)
    }

    convenience init(existingDirectory url: URL) throws {
      try self.init(url, createMissing: false, ancestor: nil, requiresPrivateDACL: true)
    }

    convenience init(existingDirectory url: URL, containedIn root: URL) throws {
      try self.init(
        url, createMissing: false, ancestor: WindowsPrivateDirectory(existingDirectory: root),
        requiresPrivateDACL: false)
    }

    convenience init(creatingDirectory url: URL, containedIn root: URL) throws {
      try self.init(
        url, createMissing: true, ancestor: WindowsPrivateDirectory(existingDirectory: root),
        requiresPrivateDACL: true)
    }

    private init(
      _ url: URL, createMissing: Bool, ancestor: WindowsPrivateDirectory?,
      requiresPrivateDACL: Bool
    ) throws {
      guard let native = WindowsFilePath.native(url), WindowsFilePath.isAbsolute(native),
        let path = WindowsFilePath.absolute(native, cwd: native)
      else {
        throw WindowsPrivateDirectoryError.invalid(
          "Private state requires a native absolute directory.")
      }
      let prefixes = try Self.ancestors(path)
      let security = try PrivateSecurity()
      let ancestorIdentity = try ancestor.map { try WindowsDirectoryIdentity($0.handles.last!) }
      var foundAncestor = ancestor == nil
      var retained: [HANDLE] = []
      do {
        for (index, prefix) in prefixes.enumerated() {
          let final = index == prefixes.count - 1
          var inspectSecurity = final && requiresPrivateDACL
          var handle = Self.open(prefix, inspectSecurity: inspectSecurity)
          if handle == nil || handle == INVALID_HANDLE_VALUE {
            let code = GetLastError()
            guard createMissing, foundAncestor, index > 0,
              code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND)
            else {
              throw WindowsPrivateDirectoryError.native("Open private directory ancestry", code)
            }
            var attributes = SECURITY_ATTRIBUTES()
            attributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
            attributes.lpSecurityDescriptor = security.descriptor
            attributes.bInheritHandle = false
            if !CreateDirectoryW(Array(prefix.utf16) + [0], &attributes) {
              let code = GetLastError()
              guard code == DWORD(ERROR_ALREADY_EXISTS) else {
                throw WindowsPrivateDirectoryError.native("Create private directory", code)
              }
            }
            inspectSecurity = true
            handle = Self.open(prefix, inspectSecurity: true)
          }
          guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw WindowsPrivateDirectoryError.native("Open private directory", GetLastError())
          }
          retained.append(handle)
          try Self.validateDirectory(handle)
          if inspectSecurity { try security.validate(handle) }
          if let ancestorIdentity, try WindowsDirectoryIdentity(handle) == ancestorIdentity {
            foundAncestor = true
          }
        }
        guard foundAncestor else {
          throw WindowsPrivateDirectoryError.invalid(
            "Managed directory ancestry does not contain the owned private root.")

        }
      } catch {
        for handle in retained.reversed() { CloseHandle(handle) }
        throw error
      }
      handles = retained
      self.security = security
      self.ancestor = ancestor
      self.requiresPrivateDACL = requiresPrivateDACL
      self.url = URL(fileURLWithPath: path, isDirectory: true)
    }

    deinit { for handle in handles.reversed() { CloseHandle(handle) } }

    func validate() throws {
      for handle in handles { try Self.validateDirectory(handle) }
      try ancestor?.validate()
      if requiresPrivateDACL { try security.validate(handles[handles.count - 1]) }
    }

    private static func open(_ path: String, inspectSecurity: Bool) -> HANDLE? {
      // Attribute-only handles do not participate in data/delete sharing checks.
      // Directory read access makes denial of rename/delete effective for this handle's lifetime.
      CreateFileW(
        Array(path.utf16) + [0],
        DWORD(FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES)
          | (inspectSecurity ? DWORD(READ_CONTROL) : 0),
        DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil)
    }

    private static func validateDirectory(_ handle: HANDLE) throws {
      var information = BY_HANDLE_FILE_INFORMATION()
      guard GetFileType(handle) == DWORD(FILE_TYPE_DISK),
        GetFileInformationByHandle(handle, &information)
      else {
        throw WindowsPrivateDirectoryError.native("Inspect private directory", GetLastError())
      }
      guard information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        throw WindowsPrivateDirectoryError.invalid(
          "Private state paths must be real directories without reparse points.")
      }
    }

    private static func ancestors(_ path: String) throws -> [String] {
      let components = path.split(separator: "\\")
      var current: String
      let suffix: ArraySlice<Substring>
      if path.hasPrefix("\\\\") {
        guard components.count >= 3 else {
          throw WindowsPrivateDirectoryError.invalid(
            "A network share root cannot be private adapter state.")
        }
        current = "\\\\" + components[0] + "\\" + components[1]
        suffix = components.dropFirst(2)
      } else {
        guard components.count >= 2 else {
          throw WindowsPrivateDirectoryError.invalid(
            "A volume root cannot be private adapter state.")
        }
        current = String(path.prefix(3))
        suffix = components.dropFirst()
      }
      guard components.count <= 1_024 else {
        throw WindowsPrivateDirectoryError.invalid(
          "Private directory ancestry exceeds its inspection bound.")
      }
      var result = [current]
      for component in suffix {
        current += (current.hasSuffix("\\") ? "" : "\\") + component
        result.append(current)
      }
      return result
    }

    private final class PrivateSecurity {
      // FILE_ALL_ACCESS from winnt.h; Swift cannot import its mixed-type C expression.
      private static let fileAllAccess =
        DWORD(STANDARD_RIGHTS_REQUIRED) | DWORD(SYNCHRONIZE) | 0x1FF
      let descriptor: PSECURITY_DESCRIPTOR
      private let owner: PSID

      init() throws {
        let sid = try Self.currentUserSID()
        let text = "O:\(sid)D:P(A;OICI;FA;;;\(sid))"
        var value: PSECURITY_DESCRIPTOR?
        guard
          ConvertStringSecurityDescriptorToSecurityDescriptorW(
            Array(text.utf16) + [0], DWORD(SDDL_REVISION_1), &value, nil), let value
        else {
          throw WindowsPrivateDirectoryError.native(
            "Create private security descriptor", GetLastError())
        }
        var owner: PSID?
        var defaulted: WindowsBool = false
        guard GetSecurityDescriptorOwner(value, &owner, &defaulted), let owner, IsValidSid(owner)
        else {
          let code = GetLastError()
          LocalFree(value)
          throw WindowsPrivateDirectoryError.native("Inspect private security owner", code)
        }
        descriptor = value
        self.owner = owner
      }

      deinit { LocalFree(descriptor) }

      func validate(_ handle: HANDLE) throws {
        var flags: DWORD = 0
        guard GetVolumeInformationByHandleW(handle, nil, 0, nil, nil, &flags, nil, 0),
          flags & DWORD(FILE_PERSISTENT_ACLS) != 0
        else {
          throw WindowsPrivateDirectoryError.invalid(
            "Private state requires a filesystem with persistent access controls.")
        }
        var actualOwner: PSID?
        var acl: PACL?
        var actual: PSECURITY_DESCRIPTOR?
        let result = GetSecurityInfo(
          handle, SE_FILE_OBJECT,
          DWORD(OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION), &actualOwner, nil, &acl,
          nil, &actual)
        guard result == DWORD(ERROR_SUCCESS), let actual else {
          throw WindowsPrivateDirectoryError.native("Read private directory security", result)
        }
        defer { LocalFree(actual) }
        guard let actualOwner, IsValidSid(actualOwner), EqualSid(actualOwner, owner) else {
          throw WindowsPrivateDirectoryError.invalid(
            "Private state directory belongs to a different or unverifiable Windows user.")
        }
        var control: SECURITY_DESCRIPTOR_CONTROL = 0
        var revision: DWORD = 0
        guard GetSecurityDescriptorControl(actual, &control, &revision),
          control & SECURITY_DESCRIPTOR_CONTROL(SE_DACL_PROTECTED) != 0,
          let acl, IsValidAcl(acl), acl.pointee.AceCount == 1
        else {
          throw WindowsPrivateDirectoryError.invalid(
            "Existing state directory is not protected by the adapter's private DACL; it was left unchanged."
          )
        }
        var entry: LPVOID?
        guard GetAce(acl, 0, &entry), let entry else {
          throw WindowsPrivateDirectoryError.native(
            "Read private directory access entry", GetLastError())
        }
        let allowed = entry.assumingMemoryBound(to: ACCESS_ALLOWED_ACE.self)
        let header = allowed.pointee.Header
        guard header.AceType == BYTE(ACCESS_ALLOWED_ACE_TYPE),
          header.AceFlags == BYTE(OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE),
          allowed.pointee.Mask == Self.fileAllAccess,
          Int(header.AceSize) >= MemoryLayout<ACCESS_ALLOWED_ACE>.size + MemoryLayout<DWORD>.size
        else {
          throw WindowsPrivateDirectoryError.invalid(
            "Existing state directory has incompatible access entries; it was left unchanged.")
        }
        let sid = entry.advanced(by: MemoryLayout<ACCESS_ALLOWED_ACE>.offset(of: \.SidStart)!)
        guard IsValidSid(sid),
          Int(GetLengthSid(sid)) <= Int(header.AceSize) - MemoryLayout<ACCESS_ALLOWED_ACE>.offset(
            of: \.SidStart)!,
          EqualSid(sid, owner)
        else {
          throw WindowsPrivateDirectoryError.invalid(
            "Existing state directory grants access to another principal; it was left unchanged.")
        }
      }

      private static func currentUserSID() throws -> String {
        var token: HANDLE?
        if !OpenThreadToken(GetCurrentThread(), DWORD(TOKEN_QUERY), true, &token) {
          let code = GetLastError()
          guard code == DWORD(ERROR_NO_TOKEN) else {
            throw WindowsPrivateDirectoryError.native("Open effective user token", code)
          }
          guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token) else {
            throw WindowsPrivateDirectoryError.native("Open process user token", GetLastError())
          }
        }
        guard let token else {
          throw WindowsPrivateDirectoryError.invalid("Windows user token is unavailable.")
        }
        defer { CloseHandle(token) }
        var count: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &count)
        guard count >= MemoryLayout<TOKEN_USER>.size, count <= 4_096 else {
          throw WindowsPrivateDirectoryError.invalid("Windows user token has an invalid size.")
        }
        let storage = UnsafeMutableRawPointer.allocate(
          byteCount: Int(count), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { storage.deallocate() }
        guard GetTokenInformation(token, TokenUser, storage, count, &count),
          let sid = storage.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid,
          IsValidSid(sid)
        else {
          throw WindowsPrivateDirectoryError.native("Read Windows user identity", GetLastError())
        }
        var text: LPWSTR?
        guard ConvertSidToStringSidW(sid, &text), let text else {
          throw WindowsPrivateDirectoryError.native("Encode Windows user identity", GetLastError())
        }
        defer { LocalFree(text) }
        return String(decodingCString: text, as: UTF16.self)
      }
    }
  }
  struct WindowsDirectoryIdentity: Equatable {
    private let volume: UInt64
    private let fileID: Data

    init(_ handle: HANDLE) throws {
      var information = FILE_ID_INFO()
      guard
        GetFileInformationByHandleEx(
          handle, FileIdInfo, &information, DWORD(MemoryLayout<FILE_ID_INFO>.size))
      else {
        throw WindowsPrivateDirectoryError.native("Read directory identity", GetLastError())
      }
      volume = information.VolumeSerialNumber
      fileID = withUnsafeBytes(of: information.FileId.Identifier) { Data($0) }
    }
  }
#endif
