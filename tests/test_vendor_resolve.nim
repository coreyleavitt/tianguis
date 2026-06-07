## Unit tests for vendor/resolve.nim — bare→qualified require resolution.
##
## Per rfc-package-identity.md S5: pure mapping + unit tests only.
## No model persistence, no ingest wiring.

import std/[unittest, options, tables, sequtils]
import tianguis/vendor/resolve

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeIdx(entries: openArray[(string, string)]): PackagesIndex =
  result = initTable[string, string]()
  for (name, url) in entries:
    result[name] = url

# ---------------------------------------------------------------------------
# buildPackagesIndex
# ---------------------------------------------------------------------------

suite "buildPackagesIndex":
  test "git entries appear in the index":
    let pkgs = @[
      UpstreamPackage(name: "chronos", url: "https://github.com/status-im/nim-chronos", `method`: "git"),
      UpstreamPackage(name: "results", url: "https://github.com/arnetheduck/nim-results", `method`: "git"),
    ]
    let idx = buildPackagesIndex(pkgs)
    check "chronos" in idx
    check idx["chronos"] == "https://github.com/status-im/nim-chronos"
    check "results" in idx
    check idx["results"] == "https://github.com/arnetheduck/nim-results"

  test "non-git entries are excluded":
    let pkgs = @[
      UpstreamPackage(name: "hgpkg", url: "https://example.com/hgpkg", `method`: "hg"),
      UpstreamPackage(name: "gitpkg", url: "https://github.com/x/gitpkg", `method`: "git"),
    ]
    let idx = buildPackagesIndex(pkgs)
    check "hgpkg" notin idx
    check "gitpkg" in idx

  test "empty package list yields empty index":
    let idx = buildPackagesIndex(@[])
    check idx.len == 0

# ---------------------------------------------------------------------------
# resolveRequire — bare name in index
# ---------------------------------------------------------------------------

suite "resolveRequire — bare name in index":
  test "bare name present → qualified with namespace from its url":
    let idx = makeIdx({
      "chronos": "https://github.com/status-im/nim-chronos",
    })
    let r = resolveRequire("chronos", ">=4.0.0", idx)
    check r.isSome
    let rr = r.get
    check rr.namespace  == "github.com/status-im"
    check rr.name       == "chronos"
    check rr.constraint == ">=4.0.0"

  test "constraint is carried verbatim (wildcard)":
    let idx = makeIdx({"results": "https://github.com/arnetheduck/nim-results"})
    let r = resolveRequire("results", "*", idx)
    check r.isSome
    check r.get.constraint == "*"

  test "constraint is carried verbatim (caret range)":
    let idx = makeIdx({"stew": "https://github.com/status-im/nim-stew"})
    let r = resolveRequire("stew", "^0.1.0", idx)
    check r.isSome
    check r.get.constraint == "^0.1.0"

  test "bare name absent → none (unresolved)":
    let idx = makeIdx({"chronos": "https://github.com/status-im/nim-chronos"})
    let r = resolveRequire("unknownpkg", ">=1.0.0", idx)
    check r.isNone

  test "bare name whose packages.json url is underivable → none":
    # A url with no org segment can't be derived → treat as unresolved
    let idx = makeIdx({"badpkg": "https://github.com"})  # bare host, no org
    let r = resolveRequire("badpkg", ">=1.0.0", idx)
    check r.isNone

# ---------------------------------------------------------------------------
# resolveRequire — URL requires (self-qualify)
# ---------------------------------------------------------------------------

suite "resolveRequire — URL requires":
  test "https URL require self-qualifies":
    let idx = initTable[string, string]()
    let r = resolveRequire("https://github.com/x/y", ">=1.0.0", idx)
    check r.isSome
    let rr = r.get
    check rr.namespace  == "github.com/x"
    check rr.name       == "y"
    check rr.constraint == ">=1.0.0"

  test "https URL with .git suffix self-qualifies (repo stripped)":
    let idx = initTable[string, string]()
    let r = resolveRequire("https://github.com/status-im/nim-chronos.git", "*", idx)
    check r.isSome
    let rr = r.get
    check rr.namespace == "github.com/status-im"
    check rr.name      == "nim-chronos"

  test "SSH git@ URL require self-qualifies":
    let idx = initTable[string, string]()
    let r = resolveRequire("git@github.com:status-im/nim-chronos.git", ">=1.0.0", idx)
    check r.isSome
    let rr = r.get
    check rr.namespace == "github.com/status-im"
    check rr.name      == "nim-chronos"

  test "URL require that fails deriveRepo → none":
    # A URL with no repo segment (bare org) → deriveRepo returns empty repo
    let idx = initTable[string, string]()
    let r = resolveRequire("https://github.com/status-im", ">=1.0.0", idx)
    check r.isNone

# ---------------------------------------------------------------------------
# resolveRequires — batch, partitioning
# ---------------------------------------------------------------------------

suite "resolveRequires — batch partitioning":
  test "all resolved when all entries are in index":
    let idx = makeIdx({
      "chronos": "https://github.com/status-im/nim-chronos",
      "results": "https://github.com/arnetheduck/nim-results",
    })
    let reqs = {"chronos": ">=4.0.0", "results": "^0.5.0"}.toOrderedTable
    let res = resolveRequires(reqs, idx)
    check res.unresolved.len == 0
    check res.resolved.len   == 2

  test "all unresolved when index is empty":
    let idx = initTable[string, string]()
    let reqs = {"chronos": ">=4.0.0", "results": "^0.5.0"}.toOrderedTable
    let res = resolveRequires(reqs, idx)
    check res.resolved.len   == 0
    check res.unresolved.len == 2
    check "chronos" in res.unresolved
    check "results" in res.unresolved

  test "mixed set — correct partition":
    let idx = makeIdx({
      "chronos": "https://github.com/status-im/nim-chronos",
    })
    let reqs = {
      "chronos":    ">=4.0.0",
      "unknownpkg": ">=1.0.0",
      "https://github.com/x/y": "*",
    }.toOrderedTable
    let res = resolveRequires(reqs, idx)
    check res.unresolved == @["unknownpkg"]
    check res.resolved.len == 2
    # chronos via bare lookup
    let chronosR = res.resolved.filterIt(it.name == "chronos")
    check chronosR.len == 1
    check chronosR[0].namespace == "github.com/status-im"
    # y via URL self-qualify
    let yR = res.resolved.filterIt(it.name == "y")
    check yR.len == 1
    check yR[0].namespace == "github.com/x"

  test "empty requires yields empty resolution":
    let idx = makeIdx({"chronos": "https://github.com/status-im/nim-chronos"})
    let reqs = initOrderedTable[string, string]()
    let res = resolveRequires(reqs, idx)
    check res.resolved.len   == 0
    check res.unresolved.len == 0
