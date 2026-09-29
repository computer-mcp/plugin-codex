import Foundation

#if os(Windows)
  import WinSDK
#else
  import Darwin
#endif

/// Filesystem ownership for managed Git operations; host authorization remains with the manager.
enum CodexWorktreeFileSystem {
  #if os(Windows)
    typealias Protection = WindowsPrivateDirectory
    static let gitExecutable = "git"
  #else
    struct Protection: Sendable {}
    static let gitExecutable = "/usr/bin/git"
  #endif

  static func prepareRoot(_ root: URL) throws -> Protection {
    #if os(Windows)
      return try WindowsPrivateDirectory(root)
    #else
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: root.path) {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw CodexManagedWorktreeError.invalid(
            "the managed worktree root must be a real directory"
          )
        }
        let attributes = try fileManager.attributesOfItem(atPath: root.path)
        if let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value != getuid() {
          throw CodexManagedWorktreeError.invalid(
            "the managed worktree root is owned by another user"
          )
        }
      } else {
        try fileManager.createDirectory(
          at: root,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
      }
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: root.path
      )

      return Protection()
    #endif
  }

  static func prepareParent(_ parent: URL, containedIn root: URL) throws -> Protection {
    #if os(Windows)
      return try WindowsPrivateDirectory(creatingDirectory: parent, containedIn: root)
    #else
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
      return try protectDirectory(parent, containedIn: root)
    #endif
  }

  /// Inspection never creates a missing directory or changes an existing directory's permissions.
  static func protectDirectory(_ directory: URL, containedIn root: URL) throws -> Protection {
    #if os(Windows)
      return try WindowsPrivateDirectory(existingDirectory: directory, containedIn: root)
    #else
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CodexManagedWorktreeError.invalid(
          "managed worktree paths must be real directories, not symbolic links"
        )
      }
      let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
      let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
      guard
        resolvedDirectory == resolvedRoot
          || resolvedDirectory.path.hasPrefix(resolvedRoot.path + "/")
      else {
        throw CodexManagedWorktreeError.invalid(
          "managed worktree path escaped the canonical managed root"
        )
      }

      return Protection()
    #endif
  }

  static func validateDirectory(_ directory: URL, containedIn root: URL) throws {
    let protection = try protectDirectory(directory, containedIn: root)
    withExtendedLifetime(protection) {}
  }

  /// A lexical precheck only. Existing directory containment also requires retained native ancestry.
  static func isDescendant(_ directory: URL, of root: URL) throws -> Bool {
    #if os(Windows)
      let path = try nativePath(directory)
      let parent = try nativePath(root)
      let prefix = parent + (parent.hasSuffix("\\") ? "" : "\\")
      let units = Array(path.utf16)
      let prefixUnits = Array(prefix.utf16)
      guard units.count > prefixUnits.count else { return false }
      return CompareStringOrdinal(
        units, Int32(prefixUnits.count), prefixUnits, Int32(prefixUnits.count), true) == CSTR_EQUAL
    #else
      return directory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    #endif
  }

  static func samePath(_ lhs: URL, _ rhs: URL) throws -> Bool {
    #if os(Windows)
      let left = Array(try nativePath(lhs).utf16)
      let right = Array(try nativePath(rhs).utf16)
      return CompareStringOrdinal(
        left, Int32(left.count), right, Int32(right.count), true) == CSTR_EQUAL
    #else
      return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    #endif
  }

  static func sameDirectory(_ lhs: URL, _ rhs: URL) throws -> Bool {
    #if os(Windows)
      let left = try openDirectory(lhs)
      defer { CloseHandle(left) }
      let right = try openDirectory(rhs)
      defer { CloseHandle(right) }
      return try WindowsDirectoryIdentity(left) == WindowsDirectoryIdentity(right)
    #else
      return lhs.path == rhs.path
    #endif
  }

  static func canonicalDirectory(_ path: String, relativeTo base: URL) throws -> URL {
    #if os(Windows)
      guard let absolute = WindowsFilePath.absolute(path, cwd: try nativePath(base)) else {
        throw WindowsPrivateDirectoryError.invalid("Git returned an invalid native directory path.")
      }
      let handle = try openDirectory(URL(fileURLWithPath: absolute, isDirectory: true))
      defer { CloseHandle(handle) }
      var output = [WCHAR](repeating: 0, count: 32_768)
      let count = GetFinalPathNameByHandleW(handle, &output, DWORD(output.count), 0)
      guard count > 0, count < output.count else {
        throw WindowsPrivateDirectoryError.native("Resolve Git directory", GetLastError())
      }
      var result = String(decoding: output.prefix(Int(count)), as: UTF16.self)
      if result.hasPrefix("\\\\?\\UNC\\") {
        result = "\\\\" + result.dropFirst(8)
      } else if result.hasPrefix("\\\\?\\") {
        result = String(result.dropFirst(4))
      }
      guard WindowsFilePath.isValid(result), WindowsFilePath.isAbsolute(result) else {
        throw WindowsPrivateDirectoryError.invalid(
          "Git directory is outside the native path namespace.")
      }
      return URL(fileURLWithPath: result, isDirectory: true)
    #else
      let url =
        path.hasPrefix("/")
        ? URL(fileURLWithPath: path, isDirectory: true)
        : base.appendingPathComponent(path, isDirectory: true)
      return url.standardizedFileURL.resolvingSymlinksInPath()
    #endif
  }

  static func isAbsent(_ url: URL) throws -> Bool {
    #if os(Windows)
      let handle = CreateFileW(
        Array(try nativePath(url).utf16) + [0], DWORD(FILE_READ_ATTRIBUTES),
        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil)
      if let handle, handle != INVALID_HANDLE_VALUE {
        CloseHandle(handle)
        return false
      }
      let code = GetLastError()
      guard code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) else {
        throw WindowsPrivateDirectoryError.native("Verify managed path absence", code)
      }
      return true
    #else
      var info = stat()
      return lstat(url.path, &info) != 0 && errno == ENOENT
    #endif
  }

  static func provisionPathIsAvailable(_ url: URL) throws -> Bool {
    #if os(Windows)
      return try isAbsent(url)
    #else
      return !FileManager.default.fileExists(atPath: url.path)
    #endif
  }

  #if os(Windows)
    private static func nativePath(_ url: URL) throws -> String {
      guard let native = WindowsFilePath.native(url), WindowsFilePath.isAbsolute(native),
        let absolute = WindowsFilePath.absolute(native, cwd: native)
      else {
        throw WindowsPrivateDirectoryError.invalid("Managed paths must be native absolute paths.")
      }
      return absolute
    }

    private static func openDirectory(_ url: URL) throws -> HANDLE {
      guard
        let handle = CreateFileW(
          Array(try nativePath(url).utf16) + [0], DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil), handle != INVALID_HANDLE_VALUE
      else { throw WindowsPrivateDirectoryError.native("Open Git directory", GetLastError()) }
      var information = BY_HANDLE_FILE_INFORMATION()
      guard GetFileType(handle) == DWORD(FILE_TYPE_DISK),
        GetFileInformationByHandle(handle, &information),
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
      else {
        let code = GetLastError()
        CloseHandle(handle)
        throw WindowsPrivateDirectoryError.native("Inspect Git directory", code)
      }
      return handle
    }
  #endif
}
