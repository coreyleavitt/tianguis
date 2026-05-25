import std/[unittest, tables, options, strutils]
import tianguis/[model]
import tianguis/vendor/[upstream, tagselect, merge, denylist, orchestrate]

# ---------------------------------------------------------------------------
# Fake driver — canned responses for deterministic tests.
# ---------------------------------------------------------------------------

type
  FakeDriver = ref object of Driver
    packages*: seq[UpstreamPackage]
    tagsByUrl*: Table[string, seq[string]]
    headShaByUrl*: Table[string, string]
    cloneByUrlRef*: Table[string, CloneResult]

method fetchPackagesJson*(d: FakeDriver): seq[UpstreamPackage] =
  d.packages

method listTags*(d: FakeDriver, url: string): seq[string] =
  d.tagsByUrl.getOrDefault(url, @[])

method headSha*(d: FakeDriver, url: string): string =
  d.headShaByUrl.getOrDefault(url, "")

method shallowCloneAndHash*(d: FakeDriver, url, refName: string): CloneResult =
  d.cloneByUrlRef.getOrDefault(url & "@" & refName,
    CloneResult(contentHash: "sha256:UNSPECIFIED", commitSha: ""))

proc chronosFakeDriver(contentHash = "sha256:hashabc"): FakeDriver =
  FakeDriver(
    packages: @[UpstreamPackage(
      name: "chronos",
      url: "https://github.com/coreyleavitt/chronos",
      `method`: "git",
    )],
    tagsByUrl: {
      "https://github.com/coreyleavitt/chronos": @["v0.5.0"],
    }.toTable,
    headShaByUrl: {
      "https://github.com/coreyleavitt/chronos": "deadbeef1234567",
    }.toTable,
    cloneByUrlRef: {
      "https://github.com/coreyleavitt/chronos@v0.5.0":
        CloneResult(contentHash: contentHash, commitSha: "deadbeef1234567"),
    }.toTable,
  )

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

const NowIso = "2026-05-25T00:00:00Z"
const LaterIso = "2026-05-25T12:00:00Z"

suite "vendor orchestrate":
  test "running vendor against a fake driver populates index":
    let d = chronosFakeDriver()
    let res = runVendor(
      d,
      initialIndex = Index(schemaVersion: 1, packages: @[]),
      denylist     = Denylist(),
      initialAlerts = "",
      nowIso       = NowIso,
    )
    check res.index.packages.len == 1
    check res.index.packages[0].name == "chronos"
    check res.index.packages[0].versions[0].version == "0.5.0"
    check res.index.packages[0].versions[0].contentHash == "sha256:hashabc"

  test "second run with same upstream state is idempotent":
    let d = chronosFakeDriver()
    let first = runVendor(d, Index(schemaVersion: 1, packages: @[]),
                          Denylist(), "", NowIso)
    let second = runVendor(d, first.index, Denylist(), first.alerts, LaterIso)
    check second.index == first.index
    check second.alerts == first.alerts

  test "denylisted package is skipped":
    let d = chronosFakeDriver()
    let dl = parseDenylist("""package "chronos" { reason "test" }""")
    let res = runVendor(d, Index(schemaVersion: 1, packages: @[]),
                        dl, "", NowIso)
    check res.index.packages.len == 0
    check "chronos" in res.skipped

  test "drift triggers alert append without index mutation":
    let d = chronosFakeDriver()
    let first = runVendor(d, Index(schemaVersion: 1, packages: @[]),
                          Denylist(), "", NowIso)
    # Simulate force-push: same URL+ref now resolves to different bytes.
    d.cloneByUrlRef["https://github.com/coreyleavitt/chronos@v0.5.0"] =
      CloneResult(contentHash: "sha256:forced", commitSha: "deadbeef1234567")
    let second = runVendor(d, first.index, Denylist(), first.alerts, LaterIso)
    check second.index == first.index   # bytes unchanged
    check "drift " in second.alerts
    check "sha256:forced" in second.alerts
    check "sha256:hashabc" in second.alerts
