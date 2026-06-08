## Tests for deriveNamespace — the identity-equality function.
## RED first: all tests added before the module exists.

import std/unittest
import tianguis/namespace

suite "deriveNamespace — github.com":
  test "github https url derives (github.com, org)":
    let r = deriveNamespace("https://github.com/coreyleavitt/nimkdl")
    check r.isOk
    check r.get.host == "github.com"
    check r.get.org == "coreyleavitt"

  test "greenm01/nimkdl and coreyleavitt/nimkdl derive DISTINCT namespaces":
    let r1 = deriveNamespace("https://github.com/greenm01/nimkdl")
    let r2 = deriveNamespace("https://github.com/coreyleavitt/nimkdl")
    check r1.isOk
    check r2.isOk
    check namespaceString(r1.get) != namespaceString(r2.get)
    check r1.get.org == "greenm01"
    check r2.get.org == "coreyleavitt"

  test "github org is case-folded":
    let lower = deriveNamespace("https://github.com/myorg/repo")
    let upper = deriveNamespace("https://github.com/MyOrg/repo")
    check lower.isOk
    check upper.isOk
    check namespaceString(lower.get) == namespaceString(upper.get)
    check lower.get.org == "myorg"

  test "www.github.com host normalizes to github.com":
    let r = deriveNamespace("https://www.github.com/coreyleavitt/repo")
    check r.isOk
    check r.get.host == "github.com"
    check r.get.org == "coreyleavitt"

  test "trailing .git stripped from repo segment":
    let r = deriveNamespace("https://github.com/coreyleavitt/nimkdl.git")
    check r.isOk
    check r.get.org == "coreyleavitt"

  test "double-slash in path collapses":
    let r = deriveNamespace("https://github.com/coreyleavitt//nimkdl")
    check r.isOk
    check r.get.host == "github.com"
    check r.get.org == "coreyleavitt"

  test "SSH short form git@github.com:org/repo.git":
    let r = deriveNamespace("git@github.com:coreyleavitt/nimkdl.git")
    check r.isOk
    check r.get.host == "github.com"
    check r.get.org == "coreyleavitt"

  test "ssh://git@github.com/org/repo — git@ residue stripped, host is github.com":
    let r = deriveNamespace("ssh://git@github.com/coreyleavitt/repo")
    check r.isOk
    check r.get.host == "github.com"
    check r.get.org == "coreyleavitt"

suite "deriveNamespace — gitlab.com":
  test "gitlab depth-2 derives ok":
    let r = deriveNamespace("https://gitlab.com/nim-lang/nimble")
    check r.isOk
    check r.get.host == "gitlab.com"
    check r.get.org == "nim-lang"

  test "gitlab depth-2 org is case-folded":
    let r = deriveNamespace("https://gitlab.com/Nim-Lang/nimble")
    check r.isOk
    check r.get.org == "nim-lang"

  test "gitlab nested group (depth > 2) returns derrGitlabNestedGroup":
    let r = deriveNamespace("https://gitlab.com/group/subgroup/project")
    check r.isErr
    check r.error == derrGitlabNestedGroup

suite "deriveNamespace — bitbucket.org":
  test "bitbucket derives ok with folded org":
    let r = deriveNamespace("https://bitbucket.org/MyOrg/repo")
    check r.isOk
    check r.get.host == "bitbucket.org"
    check r.get.org == "myorg"

suite "deriveNamespace — codeberg.org":
  test "codeberg preserves mixed-case org":
    let r = deriveNamespace("https://codeberg.org/SomeUser/repo")
    check r.isOk
    check r.get.host == "codeberg.org"
    check r.get.org == "SomeUser"

  test "codeberg Foo vs foo derive DIFFERENT namespaces (preserve)":
    let r1 = deriveNamespace("https://codeberg.org/Foo/repo")
    let r2 = deriveNamespace("https://codeberg.org/foo/repo")
    check r1.isOk
    check r2.isOk
    check namespaceString(r1.get) != namespaceString(r2.get)

suite "deriveNamespace — git.sr.ht":
  test "git.sr.ht ~User preserved (case-sensitive)":
    let r = deriveNamespace("https://git.sr.ht/~SomeUser/repo")
    check r.isOk
    check r.get.host == "git.sr.ht"
    check r.get.org == "~SomeUser"

  test "git.sr.ht ~User vs ~user derive DIFFERENT namespaces":
    let r1 = deriveNamespace("https://git.sr.ht/~User/repo")
    let r2 = deriveNamespace("https://git.sr.ht/~user/repo")
    check r1.isOk
    check r2.isOk
    check namespaceString(r1.get) != namespaceString(r2.get)

suite "deriveNamespace — fallback (unknown host)":
  test "unknown host preserves case":
    let r = deriveNamespace("https://git.example.com/MyOrg/repo")
    check r.isOk
    check r.get.host == "git.example.com"
    check r.get.org == "MyOrg"

suite "deriveNamespace — error cases":
  test "bare host with no org returns derrNoOrg":
    let r = deriveNamespace("https://github.com")
    check r.isErr
    check r.error == derrNoOrg

  test "bare host with trailing slash returns derrNoOrg":
    let r = deriveNamespace("https://github.com/")
    check r.isErr
    check r.error == derrNoOrg

  test "unparseable input returns derrUnparseable":
    let r = deriveNamespace("not-a-url-at-all")
    check r.isErr
    check r.error == derrUnparseable

suite "deriveNamespace — percent-encoding":
  test "percent-encoded org segment is decoded":
    # %6F = 'o', so %6Frg = "org"
    let r = deriveNamespace("https://github.com/%6Frg/repo")
    check r.isOk
    check r.get.org == "org"

suite "deriveNamespace — namespaceString":
  test "namespaceString serializes as host/org":
    let r = deriveNamespace("https://github.com/coreyleavitt/nimkdl")
    check r.isOk
    check namespaceString(r.get) == "github.com/coreyleavitt"

suite "deriveRepo":
  test "github url with .git suffix yields (github.com, greenm01, nimkdl)":
    let r = deriveRepo("https://github.com/greenm01/nimkdl.git")
    check r.isOk
    check r.get.host == "github.com"
    check r.get.org == "greenm01"
    check r.get.repo == "nimkdl"

  test "github url without .git yields correct repo":
    let r = deriveRepo("https://github.com/coreyleavitt/nimkdl")
    check r.isOk
    check r.get.host == "github.com"
    check r.get.org == "coreyleavitt"
    check r.get.repo == "nimkdl"

  test "deriveRepo bare host (no org) returns derrNoOrg":
    let r = deriveRepo("https://github.com")
    check r.isErr
    check r.error == derrNoOrg

  test "deriveRepo unparseable returns derrUnparseable":
    let r = deriveRepo("not-a-url-at-all")
    check r.isErr
    check r.error == derrUnparseable

  test "deriveRepo url with only org (no repo) returns repo == empty string":
    # org-only URL has no repo segment; repo="" is acceptable
    let r = deriveRepo("https://github.com/coreyleavitt")
    check r.isOk
    check r.get.org == "coreyleavitt"
    check r.get.repo == ""

  test "deriveNamespace equals deriveRepo projected to (host, org)":
    let ns = deriveNamespace("https://github.com/coreyleavitt/nimkdl.git")
    let repo = deriveRepo("https://github.com/coreyleavitt/nimkdl.git")
    check ns.isOk
    check repo.isOk
    check ns.get.host == repo.get.host
    check ns.get.org == repo.get.org

  test "SSH short form with .git yields correct repo":
    let r = deriveRepo("git@github.com:coreyleavitt/nimkdl.git")
    check r.isOk
    check r.get.host == "github.com"
    check r.get.org == "coreyleavitt"
    check r.get.repo == "nimkdl"

suite "deriveNamespace — M1: query/fragment stripping":
  ## Regression tests for M1: ?/# in path segments must NOT survive into
  ## the namespace. The comment at ~line 163 of namespace.nim falsely claimed
  ## this was already handled for the path; it was not.

  test "M1: query string in path does not survive into namespace":
    ## https://github.com/org/repo?at=main → github.com/org
    ## (not github.com/org?at=main or similar)
    let r = deriveNamespace("https://github.com/org/repo?at=main")
    check r.isOk
    if r.isOk:
      check namespaceString(r.get) == "github.com/org"

  test "M1: fragment in path does not survive into namespace":
    ## https://github.com/org/repo#readme → github.com/org
    let r = deriveNamespace("https://github.com/org/repo#readme")
    check r.isOk
    if r.isOk:
      check namespaceString(r.get) == "github.com/org"

  test "M1: custom forge with query tenant in org segment → clean namespace":
    ## https://custom-forge.io/org?tenant=x/sub → custom-forge.io/org
    ## (the ? splits the segment; tenant=x/sub must be stripped)
    let r = deriveNamespace("https://custom-forge.io/org?tenant=x/sub")
    check r.isOk
    if r.isOk:
      check namespaceString(r.get) == "custom-forge.io/org"
