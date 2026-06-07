import std/unittest
import tianguis/vendor/denylist

suite "denylist":
  test "empty denylist contains nothing":
    let dl = parseDenylist("")
    check not dl.contains("github.com/greenm01", "chronos")

  test "package listed in denylist matches on (namespace, name) tuple":
    let dl = parseDenylist("""
package "evil-pkg" {
    namespace "github.com/badactor"
    reason "abused namespace"
}
package "deprecated-pkg" {
    namespace "github.com/someorg"
    reason "author requested removal"
}
""")
    check dl.contains("github.com/badactor", "evil-pkg")
    check dl.contains("github.com/someorg", "deprecated-pkg")
    check not dl.contains("github.com/goodactor", "evil-pkg")
    check not dl.contains("github.com/badactor", "chronos")

  test "denylist entry for (github.com/greenm01, nimkdl) does NOT block (github.com/coreyleavitt, nimkdl)":
    let dl = parseDenylist("""
package "nimkdl" {
    namespace "github.com/greenm01"
    reason "test"
}
""")
    check dl.contains("github.com/greenm01", "nimkdl")
    check not dl.contains("github.com/coreyleavitt", "nimkdl")
