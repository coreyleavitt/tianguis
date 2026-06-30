## Tests for the epoch-migration reindex path:
##   mergeRebaseline — content-hash update instead of drift-reject
##   runVendor(rebaseline=true) — full orchestrator in rebaseline mode
##
## Mirror of test_vendor_merge.nim / test_vendor_orchestrate.nim patterns.
## Uses the same FakeDriver injection; no network, no filesystem.

import std/[unittest, strutils, tables]
import tianguis/[model]
import tianguis/vendor/[upstream, tagselect, merge, orchestrate, denylist]

const fixedPublishedAt = "2026-05-25T00:00:00Z"
const NowIso = "2026-05-25T00:00:00Z"

proc fakeUpstream(name = "chronos"): UpstreamPackage =
  UpstreamPackage(
    name: name,
    url: "https://github.com/coreyleavitt/" & name,
    `method`: "git",
  )

# ---------------------------------------------------------------------------
# FakeDriver — mirrors test_vendor_orchestrate.nim pattern exactly
# ---------------------------------------------------------------------------

type
  FakeDriver = ref object of Driver
    packages*:       seq[UpstreamPackage]
    tagsByUrl*:      Table[string, seq[string]]
    headShaByUrl*:   Table[string, string]
    cloneByUrlRef*:  Table[string, CloneResult]

method fetchPackagesJson*(d: FakeDriver): seq[UpstreamPackage] = d.packages

method listTags*(d: FakeDriver, url: string): seq[string] =
  d.tagsByUrl.getOrDefault(url, @[])

method headSha*(d: FakeDriver, url: string): string =
  d.headShaByUrl.getOrDefault(url, "")

method shallowCloneAndHash*(d: FakeDriver, url, refName: string): CloneResult =
  d.cloneByUrlRef.getOrDefault(url & "@" & refName,
    CloneResult(contentHash: "dag-sha256:UNSPECIFIED", commitSha: ""))

proc chronosDriver(newHash = "dag-sha256:cafebabe01234567"): FakeDriver =
  FakeDriver(
    packages: @[UpstreamPackage(
      name: "chronos",
      url:  "https://github.com/coreyleavitt/chronos",
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
        CloneResult(contentHash: newHash, commitSha: "deadbeef1234567"),
    }.toTable,
  )

# ---------------------------------------------------------------------------
# mergeRebaseline unit tests
# ---------------------------------------------------------------------------

suite "mergeRebaseline":
  test "updates stored hash when incoming hash differs (epoch migration)":
    let pkg = fakeUpstream()
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let oldEntry = buildVendoredEntry(pkg, sel, "sha256:abcdef", "c1", fixedPublishedAt).get
    let newEntry = buildVendoredEntry(pkg, sel, "dag-sha256:cafebabe01234567", "c1", fixedPublishedAt).get

    let (initial, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), oldEntry)
    # Confirm old hash is stored
    check initial.packages[0].versions[0].contentHash == "sha256:abcdef"

    let (after, outcome) = mergeRebaseline(initial, newEntry)

    check outcome.kind == mokRebaselined
    check outcome.rebaseline.existingHash == "sha256:abcdef"
    check outcome.rebaseline.newHash == "dag-sha256:cafebabe01234567"
    check outcome.rebaseline.packageName == "chronos"
    check outcome.rebaseline.version == "0.5.0"
    # Index was mutated — epoch-2 hash now stored
    check after.packages[0].versions[0].contentHash == "dag-sha256:cafebabe01234567"

  test "idempotent when incoming hash already matches stored":
    let pkg = fakeUpstream()
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let entry = buildVendoredEntry(pkg, sel, "dag-sha256:cafebabe01234567", "c1", fixedPublishedAt).get

    let (initial, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), entry)
    let (after, outcome) = mergeRebaseline(initial, entry)

    check outcome.kind == mokIdempotent
    # Index unchanged — no spurious write
    check after.packages[0].versions[0].contentHash == "dag-sha256:cafebabe01234567"
    check after.packages.len == 1

  test "new package not in index is added (same as mergeVendored)":
    let pkg = fakeUpstream()
    let sel = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let entry = buildVendoredEntry(pkg, sel, "dag-sha256:newentry", "c2", fixedPublishedAt).get

    let (after, outcome) = mergeRebaseline(Index(schemaVersion: 1, packages: @[]), entry)

    check outcome.kind == mokAdded
    check after.packages.len == 1
    check after.packages[0].versions[0].contentHash == "dag-sha256:newentry"

  test "identity-drift still rejected — rebaseline does not weaken this guard":
    ## An incoming version whose git provenance URL re-derives to a namespace
    ## different from the stored package namespace MUST still be rejected.
    ## The rebaseline flag relaxes content-drift ONLY.
    let storedPkg = Package(
      name:      "nimkdl",
      namespace: "github.com/coreyleavitt",
      upstream:  "https://github.com/coreyleavitt/nimkdl",
    )
    var storedVersion = Version(
      version:     "1.0.0",
      contentHash: "sha256:aaa",
      attestation: "milpa-vendored",
      signedBy:    "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
      publishedAt: fixedPublishedAt,
      provenances: @[Provenance(
        kind:      pkGit,
        url:       "https://github.com/coreyleavitt/nimkdl",
        gitRef:    "v1.0.0",
        commitSha: "deadbeef",
      )],
    )
    var storedIdx = Index(schemaVersion: 1, packages: @[storedPkg])
    storedIdx.packages[0].versions = @[storedVersion]

    # Incoming entry: namespace matches stored (foundPkgIdx >= 0) but version
    # provenance URL is from a different org → identity drift must fire.
    let driftEntry = VendoredEntry(
      package: Package(
        name:      "nimkdl",
        namespace: "github.com/coreyleavitt",
        upstream:  "https://github.com/coreyleavitt/nimkdl",
      ),
      version: Version(
        version:     "2.0.0",
        contentHash: "dag-sha256:cafebabe",
        attestation: "milpa-vendored",
        signedBy:    "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
        publishedAt: fixedPublishedAt,
        provenances: @[Provenance(
          kind:      pkGit,
          url:       "https://github.com/attacker/nimkdl",  # different namespace
          gitRef:    "v2.0.0",
          commitSha: "cafebabe",
        )],
      ),
    )

    let (returnedIdx, outcome) = mergeRebaseline(storedIdx, driftEntry)
    check outcome.kind == mokIdentityDrift
    check returnedIdx == storedIdx  # index unchanged

  test "intra-org collision still rejected — rebaseline does not weaken this guard":
    ## Two repos under same (namespace, name) from different repos.
    ## The second MUST still be rejected even in rebaseline mode.
    let sel = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let e1 = buildVendoredEntry(
      UpstreamPackage(name: "utils", url: "https://github.com/acme/utils-a", `method`: "git"),
      sel, "sha256:first", "aaa", fixedPublishedAt,
    ).get
    let e2 = buildVendoredEntry(
      UpstreamPackage(name: "utils", url: "https://github.com/acme/utils-b", `method`: "git"),
      sel, "dag-sha256:second", "bbb", fixedPublishedAt,
    ).get

    let (initial, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), e1)
    let (after, outcome) = mergeRebaseline(initial, e2)

    check outcome.kind == mokCollision
    check outcome.collision.namespace == "github.com/acme"
    check outcome.collision.name == "utils"
    # Index must be unchanged — first entry preserved
    check after.packages.len == 1
    check after.packages[0].versions[0].contentHash == "sha256:first"

# ---------------------------------------------------------------------------
# runVendor(rebaseline=true) integration tests
# ---------------------------------------------------------------------------

suite "runVendor rebaseline mode":
  test "rebaseline=true updates sha256: hash to dag-sha256: for existing version":
    # Start with an index containing the old sha256: hash
    let pkg = UpstreamPackage(
      name:     "chronos",
      url:      "https://github.com/coreyleavitt/chronos",
      `method`: "git",
    )
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let oldEntry = buildVendoredEntry(pkg, sel, "sha256:oldhash", "c1", NowIso).get
    let (initialIndex, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), oldEntry)
    check initialIndex.packages[0].versions[0].contentHash == "sha256:oldhash"

    let d = chronosDriver("dag-sha256:cafebabe01234567")
    let res = runVendor(d, initialIndex, Denylist(), "", NowIso, rebaseline = true)

    # Hash must be updated to epoch-2 form
    check res.index.packages[0].versions[0].contentHash == "dag-sha256:cafebabe01234567"
    # No drift alert should appear — rebaseline is not an alert condition
    check "drift " notin res.alerts

  test "rebaseline=false (default vendor) does NOT update existing hash":
    ## Confirms the normal vendor path is unaffected by the new parameter.
    let pkg = UpstreamPackage(
      name:     "chronos",
      url:      "https://github.com/coreyleavitt/chronos",
      `method`: "git",
    )
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let oldEntry = buildVendoredEntry(pkg, sel, "sha256:oldhash", "c1", NowIso).get
    let (initialIndex, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), oldEntry)

    let d = chronosDriver("dag-sha256:cafebabe01234567")
    let res = runVendor(d, initialIndex, Denylist(), "", NowIso, rebaseline = false)

    # Hash must NOT be updated — drift is rejected in normal vendor mode
    check res.index.packages[0].versions[0].contentHash == "sha256:oldhash"
    # Drift alert is emitted
    check "drift " in res.alerts

  test "rebaseline=true is idempotent when hashes already match":
    ## A second reindex pass after the migration is complete is a no-op.
    let pkg = UpstreamPackage(
      name:     "chronos",
      url:      "https://github.com/coreyleavitt/chronos",
      `method`: "git",
    )
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let alreadyMigratedEntry = buildVendoredEntry(
      pkg, sel, "dag-sha256:cafebabe01234567", "c1", NowIso,
    ).get
    let (initialIndex, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), alreadyMigratedEntry)

    let d = chronosDriver("dag-sha256:cafebabe01234567")
    let res = runVendor(d, initialIndex, Denylist(), "", NowIso, rebaseline = true)

    check res.index == initialIndex  # no change
    check res.alerts == ""           # no alerts
