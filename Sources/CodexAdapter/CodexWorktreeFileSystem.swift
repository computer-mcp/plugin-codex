import Darwin
import Foundation

/// Filesystem ownership for managed Git operations; host authorization remains with the manager.
enum CodexWorktreeFileSystem {
  static let gitExecutable = "/usr/bin/git"

  static func prepareRoot(_ root: URL) throws {
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
  }

  static func prepareParent(_ parent: URL, containedIn root: URL) throws {
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    try validateDirectory(parent, containedIn: root)
  }

  /// Inspection never creates a missing directory or changes an existing directory's permissions.
  static func validateDirectory(_ directory: URL, containedIn root: URL) throws {
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
  }

  /// A lexical precheck only. Existing directory containment requires canonical path validation.
  static func isDescendant(_ directory: URL, of root: URL) throws -> Bool {
    return directory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
  }

  static func samePath(_ lhs: URL, _ rhs: URL) throws -> Bool {
    return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
  }

  static func sameDirectory(_ lhs: URL, _ rhs: URL) throws -> Bool {
    return lhs.path == rhs.path
  }

  static func canonicalDirectory(_ path: String, relativeTo base: URL) throws -> URL {
    let url =
      path.hasPrefix("/")
      ? URL(fileURLWithPath: path, isDirectory: true)
      : base.appendingPathComponent(path, isDirectory: true)
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  static func isAbsent(_ url: URL) throws -> Bool {
    var info = stat()
    return lstat(url.path, &info) != 0 && errno == ENOENT
  }

  static func provisionPathIsAvailable(_ url: URL) throws -> Bool {
    return !FileManager.default.fileExists(atPath: url.path)
  }

}
