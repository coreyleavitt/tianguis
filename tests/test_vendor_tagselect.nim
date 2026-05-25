## Tag-selection heuristic tests.
##
## The bot picks the most "release-shaped" tag per upstream:
## semver-shaped > any tag > fallback to HEAD with synthetic version.

import std/unittest
import tianguis/vendor/tagselect

suite "tag selection":
  test "highest semver tag wins when multiple semver-shaped tags exist":
    let sel = selectTag(@["v0.4.0", "v0.5.0", "v0.4.5"], "deadbeef1234567")
    check sel.kind == tskSemver
    check sel.tag == "v0.5.0"
    check sel.version == "0.5.0"

  test "highest semver tag wins regardless of v prefix mixture":
    let sel = selectTag(@["0.4.0", "v0.5.0", "v0.4.5"], "deadbeef1234567")
    check sel.kind == tskSemver
    check sel.tag == "v0.5.0"
    check sel.version == "0.5.0"

  test "falls back to lex-last tag when no semver-shaped":
    let sel = selectTag(@["alpha", "candidate", "release-beta"], "deadbeef1234567")
    check sel.kind == tskAnyTag
    check sel.tag == "release-beta"
    check sel.version == "release-beta"

  test "falls back to HEAD with synthetic version when no tags exist":
    let sel = selectTag(@[], "deadbeef1234567")
    check sel.kind == tskHead
    check sel.version == "0.0.0+commit-deadbee"
