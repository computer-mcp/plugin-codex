import Foundation
import Testing
import WinSDK

@testable import ManagedProcess

@Suite("Windows managed worktree filesystem", .timeLimit(.minutes(2)))
struct WorktreeFileSystemTests {
  private typealias FileSystem = CodexWorktreeFileSystem

  @Test("Real Git worktrees inherit private access, retain their parent and refuse dirty removal")
  func gitLifecycle() throws {
    let container = temporaryURL()
    defer { try? FileManager.default.removeItem(at: container) }
    let source = container.appendingPathComponent("source 汉字")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try git(["init", "--initial-branch=main"], in: source)
    try git(
      [
        "-c", "user.name=Native Test", "-c", "user.email=native@example.invalid", "commit",
        "--allow-empty", "-m", "fixture",
      ], in: source)
    let root = container.appendingPathComponent("managed")
    let parent = root.appendingPathComponent("repository")
    let target = parent.appendingPathComponent("worktree 汉字")
    let rootProtection = try FileSystem.prepareRoot(root)
    let parentProtection = try FileSystem.prepareParent(parent, containedIn: root)
    defer { withExtendedLifetime((rootProtection, parentProtection)) {} }
    try git(["worktree", "add", "-b", "candidate", target.path, "HEAD"], in: source)
    try FileSystem.validateDirectory(target, containedIn: root)
    let reported = try git(["rev-parse", "--show-toplevel"], in: target)
      .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonical = try FileSystem.canonicalDirectory(reported, relativeTo: target)
    #expect(try FileSystem.sameDirectory(canonical, target))
    let common = try git(["rev-parse", "--git-common-dir"], in: target)
      .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(
      try FileSystem.sameDirectory(
        FileSystem.canonicalDirectory(common, relativeTo: target),
        source.appendingPathComponent(".git")))
    try #require(
      !MoveFileW(
        Array(parent.path.utf16) + [0],
        Array(parent.appendingPathExtension("moved").path.utf16) + [0]))
    #expect(GetLastError() == DWORD(ERROR_SHARING_VIOLATION))
    let dirty = target.appendingPathComponent("untracked.txt")
    try Data("preserve".utf8).write(to: dirty)
    let refused = try runGit(["worktree", "remove", target.path], in: source)
    #expect(refused.exitCode != 0)
    #expect(try Data(contentsOf: dirty) == Data("preserve".utf8))
    try FileManager.default.removeItem(at: dirty)
    try git(["worktree", "remove", target.path], in: source)
    #expect(try FileSystem.isAbsent(target))
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try FileSystem.validateDirectory(target, containedIn: root)
    }
    #expect(try FileSystem.isAbsent(target))
    try parentProtection.validate()
  }

  @Test("Containment is physical and validation cannot create a missing or unrelated path")
  func containmentAndInspection() throws {
    let container = temporaryURL()
    defer { try? FileManager.default.removeItem(at: container) }
    let root = container.appendingPathComponent("managed")
    let other = container.appendingPathComponent("managed-other")
    let protection = try FileSystem.prepareRoot(root)
    let otherProtection = try FileSystem.prepareRoot(other)
    defer { withExtendedLifetime((protection, otherProtection)) {} }
    #expect(try !FileSystem.isDescendant(other, of: root))
    #expect(try !FileSystem.sameDirectory(other, root))
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try FileSystem.validateDirectory(other, containedIn: root)
    }
    let missing = root.appendingPathComponent("missing")
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try WindowsPrivateDirectory(existingDirectory: missing)
    }
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try FileSystem.validateDirectory(missing, containedIn: root)
    }
    #expect(try FileSystem.isAbsent(missing))
    let outside = other.appendingPathComponent("child")
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try FileSystem.prepareParent(outside, containedIn: root)
    }
    #expect(try FileSystem.isAbsent(outside))
    let inherited = root.appendingPathComponent("inherited")
    try FileManager.default.createDirectory(at: inherited, withIntermediateDirectories: false)
    try FileSystem.validateDirectory(inherited, containedIn: root)
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try WindowsPrivateDirectory(existingDirectory: inherited)
    }
  }

  @Test("Native identity resolves source aliases while managed roots reject directory reparses")
  func aliasesAndReparses() throws {
    let container = temporaryURL()
    defer { try? FileManager.default.removeItem(at: container) }
    let root = container.appendingPathComponent("root 汉字")
    let protection = try FileSystem.prepareRoot(root)
    defer { withExtendedLifetime(protection) {} }
    let link = container.appendingPathComponent("alias")
    try makeLink(link, to: root)
    #expect(try FileSystem.sameDirectory(link, root))
    #expect(
      try FileSystem.sameDirectory(
        FileSystem.canonicalDirectory(link.path, relativeTo: container), root))
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try FileSystem.validateDirectory(link, containedIn: root)
    }
    let dangling = root.appendingPathComponent("dangling")
    try makeLink(dangling, to: root.appendingPathComponent("missing"))
    #expect(try !FileSystem.isAbsent(dangling))
    #expect(try !FileSystem.provisionPathIsAvailable(dangling))
    #expect(throws: WindowsPrivateDirectoryError.self) {
      try FileSystem.validateDirectory(dangling, containedIn: root)
    }
  }

  @Test("An inaccessible path is never treated as absent")
  func unverifiableAbsence() throws {
    let file = temporaryURL()
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("preserve".utf8).write(to: file)
    let handle = try #require(
      CreateFileW(
        Array(file.path.utf16) + [0], DWORD(READ_CONTROL | WRITE_DAC),
        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING), 0,
        nil))
    try #require(handle != INVALID_HANDLE_VALUE)
    defer { CloseHandle(handle) }
    var original: PSECURITY_DESCRIPTOR?
    try #require(
      GetSecurityInfo(
        handle, SE_FILE_OBJECT, DWORD(DACL_SECURITY_INFORMATION), nil, nil, nil, nil, &original)
        == DWORD(ERROR_SUCCESS))
    let saved = try #require(original)
    defer { LocalFree(saved) }
    var empty: PSECURITY_DESCRIPTOR?
    try #require(
      ConvertStringSecurityDescriptorToSecurityDescriptorW(
        Array("D:P".utf16) + [0], DWORD(SDDL_REVISION_1), &empty, nil))
    let denied = try #require(empty)
    defer { LocalFree(denied) }
    try #require(SetKernelObjectSecurity(handle, DWORD(DACL_SECURITY_INFORMATION), denied))
    defer { #expect(SetKernelObjectSecurity(handle, DWORD(DACL_SECURITY_INFORMATION), saved)) }
    #expect(throws: WindowsPrivateDirectoryError.self) { try FileSystem.isAbsent(file) }
  }

  @discardableResult
  private func git(_ arguments: [String], in directory: URL) throws -> CommandResult {
    let result = try runGit(arguments, in: directory)
    try #require(result.exitCode == 0, "Git failed: \(result.stderr)")
    try #require(!result.timedOut)
    return result
  }

  private func runGit(_ arguments: [String], in directory: URL) throws -> CommandResult {
    try ProcessCommandRunner().run(
      executable: FileSystem.gitExecutable, arguments: arguments, workingDirectory: directory,
      environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"],
      timeoutMilliseconds: 30_000, maxOutputBytes: 1_048_576)
  }

  private func makeLink(_ link: URL, to destination: URL) throws {
    try #require(
      CreateSymbolicLinkW(
        Array(link.path.utf16) + [0], Array(destination.path.utf16) + [0],
        DWORD(SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) != 0)
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("worktree 汉字 \(UUID())")
  }
}
