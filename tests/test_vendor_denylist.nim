import std/unittest
import tianguis/vendor/denylist

suite "denylist":
  test "empty denylist contains nothing":
    let dl = parseDenylist("")
    check not dl.contains("chronos")

  test "package listed in denylist matches":
    let dl = parseDenylist("""
package "evil-pkg" {
    reason "abused namespace"
}
package "deprecated-pkg" {
    reason "author requested removal"
}
""")
    check dl.contains("evil-pkg")
    check dl.contains("deprecated-pkg")
    check not dl.contains("chronos")
