import std/[unittest, tables, strutils, options]
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

suite "candidate emission (S7b)":
  ## rfc-attestation-delivery S7b / tianguis#42: `runVendor` must list exactly
  ## the post-epoch entries that still need a minted bundle — pre-epoch
  ## entries and entries already pinned elsewhere in the index are excluded.
  const epoch = "2026-07-01T00:00:00Z"
  const preEpochIso = "2026-06-01T00:00:00Z"
  const postEpochIso = "2026-07-15T00:00:00Z"

  test "pre-epoch vendor pass emits no candidates":
    let d = chronosFakeDriver()
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let res = runVendor(d, idx, Denylist(), "", preEpochIso)
    check res.candidates.len == 0
    check res.index.packages.len == 1   # merged normally — gate is forward-only

  test "no epoch set: post-epoch-shaped vendor pass emits no candidates":
    let d = chronosFakeDriver()
    let idx = Index(schemaVersion: 1, packages: @[])   # no attestationEpoch
    let res = runVendor(d, idx, Denylist(), "", postEpochIso)
    check res.candidates.len == 0
    check res.index.packages.len == 1

  test "post-epoch vendor pass emits exactly one candidate for the unpinned entry":
    let d = chronosFakeDriver()
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let res = runVendor(d, idx, Denylist(), "", postEpochIso)
    check res.candidates.len == 1
    check res.index.packages.len == 0   # rejected — needs a minted pin first
    let c = res.candidates[0]
    check c.namespace == "github.com/coreyleavitt"
    check c.name == "chronos"
    check c.version == "0.5.0"
    check c.contentHash == "sha256:hashabc"
    check c.upstream == "https://github.com/coreyleavitt/chronos"
    check c.commitSha == "deadbeef1234567"
    check c.gitRef == "v0.5.0"
    check c.publishedAt == postEpochIso

  test "already-pinned entry is excluded from candidates on a subsequent run":
    let d = chronosFakeDriver()
    # Simulate a prior run that already vendored + minted a pin for this
    # exact (namespace, name, version, content_hash).
    let pinnedVersion = Version(
      version: "0.5.0", contentHash: "sha256:hashabc",
      attestation: "milpa-vendored", publishedAt: postEpochIso,
      bundlePin: some("d".repeat(64)),
      provenances: @[Provenance(kind: pkGit,
        url: "https://github.com/coreyleavitt/chronos",
        gitRef: "v0.5.0", commitSha: "deadbeef1234567")],
    )
    var pinnedPkg = Package(name: "chronos", namespace: "github.com/coreyleavitt",
      upstream: "https://github.com/coreyleavitt/chronos")
    pinnedPkg.versions = @[pinnedVersion]
    let idxWithPin = Index(schemaVersion: 1, attestationEpoch: some(epoch),
      packages: @[pinnedPkg])

    let res = runVendor(d, idxWithPin, Denylist(), "", postEpochIso)
    check res.candidates.len == 0
    # The already-pinned entry is preserved untouched — not re-emitted, not lost.
    check res.index.packages.len == 1
    check res.index.packages[0].versions[0].bundlePin.isSome
    check res.index.packages[0].versions[0].bundlePin.get == "d".repeat(64)
