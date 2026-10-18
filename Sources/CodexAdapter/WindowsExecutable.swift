#if os(Windows)
  import Foundation

  enum WindowsExecutable {
    static func resolve(_ executable: String, workspace: URL, environment: [String: String]) throws
      -> URL
    {
      guard let directory = WindowsFilePath.native(workspace),
        WindowsFilePath.isValid(directory), WindowsFilePath.isAbsolute(directory),
        WindowsFilePath.isValid(executable)
      else {
        throw CommandRunnerError.launchFailed("Invalid Windows executable or working directory.")
      }
      let candidates: [String]
      if executable.contains(where: { "/\\:".contains($0) }) {
        candidates = [executable]
      } else {
        let entries = environment.filter { WindowsProcessEnvironment.namesMatch($0.key, "PATH") }
        guard entries.count <= 1, entries.first?.value.utf16.contains(0) != true else {
          throw CommandRunnerError.launchFailed("Invalid or ambiguous Windows PATH.")
        }
        let name = executable.lowercased().hasSuffix(".exe") ? executable : executable + ".exe"
        candidates = (entries.first?.value ?? "").split(separator: ";").compactMap { entry in
          var path = String(entry)
          if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
            path.removeFirst()
            path.removeLast()
          }
          return path.isEmpty ? nil : path + "\\" + name
        }
      }
      for candidate in candidates {
        guard let path = WindowsFilePath.absolute(candidate, cwd: directory) else {
          throw CommandRunnerError.launchFailed(
            "Executable paths must be native absolute or workspace-relative paths.")
        }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path)
        {
          return url
        }
      }
      throw CommandRunnerError.launchFailed(
        "Cannot resolve executable in the launch workspace and PATH.")
    }
  }
#endif
