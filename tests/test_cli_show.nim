## Tests for `tianguis show <url>` — the S4 operability surface.
##
## cmdShow does I/O, so we test via the pure-core `showResult` proc
## that returns (code, stdout, stderr) without side effects.
## This follows the driver-injection / pure-core discipline used elsewhere.

import std/[unittest, strutils]
import tianguis/cli

suite "cmdShow — success path":
  test "github url returns code 0 and stdout contains namespace":
    let r = showResult("https://github.com/coreyleavitt/nimkdl")
    check r.code == 0
    check "github.com/coreyleavitt" in r.stdout
    check r.stderr == ""

  test "stdout also contains repo hint":
    let r = showResult("https://github.com/coreyleavitt/nimkdl")
    check r.code == 0
    check "nimkdl" in r.stdout

  test "greenm01 and coreyleavitt derive distinct namespaces":
    let r1 = showResult("https://github.com/greenm01/nimkdl")
    let r2 = showResult("https://github.com/coreyleavitt/nimkdl")
    check r1.code == 0
    check r2.code == 0
    check "github.com/greenm01" in r1.stdout
    check "github.com/coreyleavitt" in r2.stdout
    # namespaces differ
    check r1.stdout != r2.stdout

  test "gitlab url with org+repo returns code 0":
    let r = showResult("https://gitlab.com/nim-lang/nimble")
    check r.code == 0
    check "gitlab.com/nim-lang" in r.stdout

  test "ssh short form url derives correctly":
    let r = showResult("git@github.com:coreyleavitt/nimkdl.git")
    check r.code == 0
    check "github.com/coreyleavitt" in r.stdout
    check "nimkdl" in r.stdout

suite "cmdShow — error path":
  test "bare host with no org returns non-zero and stderr contains derrNoOrg":
    let r = showResult("https://github.com")
    check r.code != 0
    check "derrNoOrg" in r.stderr
    check r.stdout == ""

  test "bare host with trailing slash returns non-zero and stderr contains derrNoOrg":
    let r = showResult("https://github.com/")
    check r.code != 0
    check "derrNoOrg" in r.stderr

  test "unparseable input returns non-zero and stderr contains derrUnparseable":
    let r = showResult("not-a-url-at-all")
    check r.code != 0
    check "derrUnparseable" in r.stderr
    check r.stdout == ""

  test "gitlab nested group returns non-zero and stderr contains derrGitlabNestedGroup":
    let r = showResult("https://gitlab.com/group/subgroup/project")
    check r.code != 0
    check "derrGitlabNestedGroup" in r.stderr
