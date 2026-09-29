#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsProcessEnvironment {
    static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
      compare(lhs, rhs) == CSTR_EQUAL
    }

    static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
      compare(lhs, rhs) == CSTR_LESS_THAN
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Int32 {
      let left = Array(lhs.utf16)
      let right = Array(rhs.utf16)
      guard !left.isEmpty, !right.isEmpty, left.count <= Int32.max, right.count <= Int32.max else {
        return lhs == rhs ? CSTR_EQUAL : (lhs < rhs ? CSTR_LESS_THAN : CSTR_GREATER_THAN)
      }
      return left.withUnsafeBufferPointer { l in
        right.withUnsafeBufferPointer { r in
          CompareStringOrdinal(l.baseAddress, Int32(l.count), r.baseAddress, Int32(r.count), true)
        }
      }
    }

    static func merging(_ base: [String: String], overrides: [String: String]) throws -> [String:
      String]
    {
      var result: [String: String] = [:]
      for (index, input) in [base, overrides].enumerated() {
        var admitted: [String] = []
        for (key, value) in input {
          let units = Array(key.utf16)
          // Win32 may inherit drive-specific current directories such as =C:.
          let inheritedDrive =
            index == 0 && units.count == 3 && units[0] == 61
            && ((65...90).contains(units[1]) || (97...122).contains(units[1])) && units[2] == 58
          guard !key.isEmpty, !units.contains(0), !value.utf16.contains(0),
            inheritedDrive || !key.contains("="),
            !admitted.contains(where: { namesMatch($0, key) })
          else { throw CommandRunnerError.launchFailed("Invalid or ambiguous child environment.") }
          admitted.append(key)
          if let previous = result.keys.first(where: { namesMatch($0, key) }) {
            result.removeValue(forKey: previous)
          }
          result[key] = value
        }
      }
      if !result.keys.contains(where: { namesMatch($0, "PATH") }) { result["PATH"] = "" }
      return result
    }
  }
#endif
