import Foundation
import Testing
import WinSDK

@testable import ManagedProcess

@Suite("Windows private state directories", .timeLimit(.minutes(1)))
struct PrivateDirectoryTests {
  @Test("Creation and reopen preserve a protected owner DACL and private child inheritance")
  func creationAndInheritance() throws {
    let root = temporaryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("subjects/主体", isDirectory: true)
    do {
      let first = try WindowsPrivateDirectory(target)
      let second = try WindowsPrivateDirectory(target)
      defer { withExtendedLifetime((first, second)) {} }
      let security = try snapshot(target)
      #expect(security.protected)
      #expect(security.grantees == [security.owner])
      #expect(security.masks == [DWORD(FILE_ALL_ACCESS)])
      let file = target.appendingPathComponent("record.sqlite")
      try Data("private".utf8).write(to: file)
      let child = try snapshot(file)
      #expect(child.grantees == [security.owner])
      #expect(child.masks == [DWORD(FILE_ALL_ACCESS)])
      #expect(try Data(contentsOf: file) == Data("private".utf8))
    }
    let reopened = try WindowsPrivateDirectory(target)
    withExtendedLifetime(reopened) {}
  }

  @Test("Existing broader permissions are rejected without changing ACLs or contents")
  func existingDirectoryPreserved() throws {
    let root = temporaryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let file = root.appendingPathComponent("existing.txt")
    try Data("unrelated".utf8).write(to: file)
    let before = try snapshot(root)
    #expect(throws: WindowsPrivateDirectoryError.self) { try WindowsPrivateDirectory(root) }
    #expect(try snapshot(root) == before)
    #expect(try Data(contentsOf: file) == Data("unrelated".utf8))
  }

  @Test("Retained ancestors prevent parent and state-directory replacement until release")
  func retainsIdentity() throws {
    let root = temporaryURL()
    let replacement = root.appendingPathExtension("moved")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: replacement)
    }
    let target = root.appendingPathComponent("state")
    var guardDirectory: WindowsPrivateDirectory? = try WindowsPrivateDirectory(target)
    #expect(!MoveFileW(Array(root.path.utf16) + [0], Array(replacement.path.utf16) + [0]))
    #expect(
      !MoveFileW(
        Array(target.path.utf16) + [0],
        Array(target.appendingPathExtension("moved").path.utf16) + [0]))
    withExtendedLifetime(guardDirectory) {}
    guardDirectory = nil
    try #require(MoveFileW(Array(root.path.utf16) + [0], Array(replacement.path.utf16) + [0]))
  }

  @Test("Directory links are rejected at the state root and within its ancestry")
  func rejectsReparsePoints() throws {
    let root = temporaryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let destination = root.appendingPathComponent("destination")
    do {
      let directory = try WindowsPrivateDirectory(destination)
      withExtendedLifetime(directory) {}
    }
    let link = root.appendingPathComponent("alias")
    try #require(
      CreateSymbolicLinkW(
        Array(link.path.utf16) + [0], Array(destination.path.utf16) + [0],
        DWORD(SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) != 0)
    #expect(throws: WindowsPrivateDirectoryError.self) { try WindowsPrivateDirectory(link) }
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try WindowsPrivateDirectory(link.appendingPathComponent("child"))
    }
    #expect(
      !FileManager.default.fileExists(atPath: destination.appendingPathComponent("child").path))
  }

  @Test("File collisions remain untouched and system-owned directories are refused")
  func refusesUnownedOrNonDirectory() throws {
    let file = temporaryURL()
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("file".utf8).write(to: file)
    #expect(throws: WindowsPrivateDirectoryError.self) { try WindowsPrivateDirectory(file) }
    #expect(try Data(contentsOf: file) == Data("file".utf8))
    var path = [WCHAR](repeating: 0, count: 32_768)
    let count = GetWindowsDirectoryW(&path, UINT(path.count))
    try #require(count > 0 && count < path.count)
    let system = URL(fileURLWithPath: String(decoding: path.prefix(Int(count)), as: UTF16.self))
    let before = try snapshot(system)
    #expect(throws: WindowsPrivateDirectoryError.self) { try WindowsPrivateDirectory(system) }
    #expect(try snapshot(system) == before)
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("private 汉字 \(UUID())")
  }

  private struct Snapshot: Equatable {
    let owner: String
    let protected: Bool
    let grantees: [String]
    let masks: [DWORD]
    let sddl: String
  }

  private func snapshot(_ url: URL) throws -> Snapshot {
    let handle = try #require(
      CreateFileW(
        Array(url.path.utf16) + [0], DWORD(READ_CONTROL),
        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil))
    try #require(handle != INVALID_HANDLE_VALUE)
    defer { CloseHandle(handle) }
    var owner: PSID?
    var acl: PACL?
    var descriptor: PSECURITY_DESCRIPTOR?
    let information = DWORD(OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION)
    try #require(
      GetSecurityInfo(handle, SE_FILE_OBJECT, information, &owner, nil, &acl, nil, &descriptor)
        == DWORD(ERROR_SUCCESS))
    let value = try #require(descriptor)
    defer { LocalFree(value) }
    let ownerName = try sidString(try #require(owner))
    var control: SECURITY_DESCRIPTOR_CONTROL = 0
    var revision: DWORD = 0
    try #require(GetSecurityDescriptorControl(value, &control, &revision))
    var text: LPWSTR?
    try #require(
      ConvertSecurityDescriptorToStringSecurityDescriptorW(
        value, DWORD(SDDL_REVISION_1), information, &text, nil))
    let string = try #require(text)
    defer { LocalFree(string) }
    var grantees: [String] = []
    var masks: [DWORD] = []
    if let acl {
      for index in 0..<DWORD(acl.pointee.AceCount) {
        var raw: LPVOID?
        try #require(GetAce(acl, index, &raw))
        let entry = try #require(raw)
        let ace = entry.assumingMemoryBound(to: ACCESS_ALLOWED_ACE.self).pointee
        if ace.Header.AceType == BYTE(ACCESS_ALLOWED_ACE_TYPE) {
          grantees.append(
            try sidString(
              entry.advanced(by: MemoryLayout<ACCESS_ALLOWED_ACE>.offset(of: \.SidStart)!)))
          masks.append(ace.Mask)
        }
      }
    }
    return Snapshot(
      owner: ownerName, protected: control & SECURITY_DESCRIPTOR_CONTROL(SE_DACL_PROTECTED) != 0,
      grantees: grantees, masks: masks, sddl: String(decodingCString: string, as: UTF16.self))
  }

  private func sidString(_ sid: PSID) throws -> String {
    var text: LPWSTR?
    try #require(ConvertSidToStringSidW(sid, &text))
    let value = try #require(text)
    defer { LocalFree(value) }
    return String(decodingCString: value, as: UTF16.self)
  }
}
