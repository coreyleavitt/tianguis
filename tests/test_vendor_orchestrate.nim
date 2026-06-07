import std/[unittest, tables, strutils]
import tianguis/[model]
import tianguis/vendor/[upstream, denylist, orchestrate]

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

  test "denylisted package (tuple-keyed) is skipped":
    let d = chronosFakeDriver()
    let dl = parseDenylist("""
package "chronos" {
    namespace "github.com/coreyleavitt"
    reason "test"
}
""")
    let res = runVendor(d, Index(schemaVersion: 1, packages: @[]),
                        dl, "", NowIso)
    check res.index.packages.len == 0
    check "chronos" in res.skipped

  test "denylist for different namespace does NOT skip the package":
    let d = chronosFakeDriver()
    let dl = parseDenylist("""
package "chronos" {
    namespace "github.com/someoneelse"
    reason "test"
}
""")
    let res = runVendor(d, Index(schemaVersion: 1, packages: @[]),
                        dl, "", NowIso)
    # Not denylisted — should be vendored
    check res.index.packages.len == 1

  test "package with underivable URL is skipped and recorded":
    let d = FakeDriver(
      packages: @[UpstreamPackage(
        name: "bad-pkg",
        url: "https://github.com",  # bare host — no org → derrNoOrg
        `method`: "git",
      )],
      tagsByUrl: initTable[string, seq[string]](),
      headShaByUrl: initTable[string, string](),
      cloneByUrlRef: initTable[string, CloneResult](),
    )
    let res = runVendor(d, Index(schemaVersion: 1, packages: @[]),
                        Denylist(), "", NowIso)
    check res.index.packages.len == 0
    check "bad-pkg" in res.skipped

  test "intra-org collision is surfaced in alerts with IDX-INTRAORG-COLLISION":
    # Two packages under github.com/acme both named "utils" but from
    # different repos — second should be rejected with a logged collision.
    let d = FakeDriver(
      packages: @[
        UpstreamPackage(name: "utils", url: "https://github.com/acme/utils-a", `method`: "git"),
        UpstreamPackage(name: "utils", url: "https://github.com/acme/utils-b", `method`: "git"),
      ],
      tagsByUrl: {
        "https://github.com/acme/utils-a": @["v1.0.0"],
        "https://github.com/acme/utils-b": @["v1.0.0"],
      }.toTable,
      headShaByUrl: {
        "https://github.com/acme/utils-a": "aaa",
        "https://github.com/acme/utils-b": "bbb",
      }.toTable,
      cloneByUrlRef: {
        "https://github.com/acme/utils-a@v1.0.0": CloneResult(contentHash: "sha256:first", commitSha: "aaa"),
        "https://github.com/acme/utils-b@v1.0.0": CloneResult(contentHash: "sha256:second", commitSha: "bbb"),
      }.toTable,
    )
    let res = runVendor(d, Index(schemaVersion: 1, packages: @[]),
                        Denylist(), "", NowIso)
    # Only the first package survives in the index
    check res.index.packages.len == 1
    check res.index.packages[0].versions[0].contentHash == "sha256:first"
    # Collision is logged in alerts
    check "collision" in res.alerts

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
