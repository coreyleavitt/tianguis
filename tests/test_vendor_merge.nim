## Vendored-entry construction + merge-into-index tests.

import std/[unittest, strutils, options]
import tianguis/[model, kdl_io]
import tianguis/vendor/[upstream, tagselect, merge]
import tianguis/namespace

const fixedPublishedAt = "2026-05-25T00:00:00Z"

proc fakeUpstream(name = "chronos"): UpstreamPackage =
  UpstreamPackage(
    name: name,
    url: "https://github.com/coreyleavitt/" & name,
    `method`: "git",
  )

suite "vendor build":
  test "buildVendoredEntry produces a milpa-vendored Version":
    let pkg = fakeUpstream()
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let r = buildVendoredEntry(
      pkg, sel,
      contentHash = "sha256:abcdef",
      commitSha   = "deadbeef1234567",
      publishedAt = fixedPublishedAt,
    )
    check r.isOk
    let entry = r.get
    check entry.package.name == "chronos"
    check entry.package.upstream == "https://github.com/coreyleavitt/chronos"
    check entry.version.version == "0.5.0"
    check entry.version.contentHash == "sha256:abcdef"
    check entry.version.attestation == "milpa-vendored"
    check entry.version.provenances.len == 1
    check entry.version.provenances[0].kind == pkGit
    check entry.version.provenances[0].gitRef == "v0.5.0"
    check entry.version.provenances[0].commitSha == "deadbeef1234567"

  test "buildVendoredEntry namespace is never empty for a valid url":
    let pkg = fakeUpstream()
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let r = buildVendoredEntry(pkg, sel, "sha256:abcdef", "abc", fixedPublishedAt)
    check r.isOk
    check r.get.package.namespace == "github.com/coreyleavitt"
    check r.get.package.namespace.len > 0

  test "buildVendoredEntry hard-rejects url with no org (derrNoOrg)":
    let pkg = UpstreamPackage(
      name: "bad",
      url: "https://github.com",   # bare host — no org
      `method`: "git",
    )
    let sel = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let r = buildVendoredEntry(pkg, sel, "sha256:abc", "commit", fixedPublishedAt)
    check r.isErr
    check r.error == derrNoOrg

  test "buildVendoredEntry hard-rejects unparseable url (derrUnparseable)":
    let pkg = UpstreamPackage(
      name: "bad",
      url: "not-a-url-at-all",
      `method`: "git",
    )
    let sel = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let r = buildVendoredEntry(pkg, sel, "sha256:abc", "commit", fixedPublishedAt)
    check r.isErr
    check r.error == derrUnparseable

suite "vendor merge":
  test "merging into empty Index adds the package":
    let pkg = fakeUpstream()
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let e = buildVendoredEntry(pkg, sel, "sha256:a", "c123", fixedPublishedAt).get
    let (idx, outcome) = mergeVendored(Index(schemaVersion: 1, packages: @[]), e)
    check outcome.kind == mokAdded
    check idx.packages.len == 1
    check idx.packages[0].name == "chronos"
    check idx.packages[0].versions.len == 1
    check idx.packages[0].versions[0].version == "0.5.0"

  test "merging a new version onto an existing package appends":
    let pkg = fakeUpstream()
    let v0_4 = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.4.0", version: "0.4.0"),
      "sha256:older", "olderSha", fixedPublishedAt,
    ).get
    let v0_5 = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0"),
      "sha256:newer", "newerSha", fixedPublishedAt,
    ).get
    let (after_v0_4, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), v0_4)
    let (after_v0_5, outcome2) = mergeVendored(after_v0_4, v0_5)
    check outcome2.kind == mokAdded
    check after_v0_5.packages.len == 1
    check after_v0_5.packages[0].versions.len == 2

  test "merging existing (package, version) with same hash is idempotent":
    let pkg = fakeUpstream()
    let e = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0"),
      "sha256:same", "abc", fixedPublishedAt,
    ).get
    let (idx1, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), e)
    let (idx2, outcome) = mergeVendored(idx1, e)
    check outcome.kind == mokIdempotent
    check idx2.packages[0].versions.len == 1  # not duplicated

  test "drift detected when existing (package, version) has different hash":
    let pkg = fakeUpstream()
    let oldEntry = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0"),
      "sha256:original", "abc", fixedPublishedAt,
    ).get
    let newEntry = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0"),
      "sha256:forcepushed", "abc", fixedPublishedAt,
    ).get
    let (initial, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), oldEntry)
    let (after, outcome) = mergeVendored(initial, newEntry)
    check outcome.kind == mokContentDrift
    check outcome.content.packageName == "chronos"
    check outcome.content.namespace == "github.com/coreyleavitt"
    check outcome.content.version == "0.5.0"
    check outcome.content.existingHash == "sha256:original"
    check outcome.content.newHash == "sha256:forcepushed"
    # Existing entry retained verbatim — no silent update.
    check after.packages[0].versions[0].contentHash == "sha256:original"

suite "namespace-identity collision pair":
  ## The #32 core test: two packages sharing leaf name `nimkdl` but from
  ## different namespaces survive mergeVendored as TWO distinct entries.
  proc nimkdlGreenm01(): UpstreamPackage =
    UpstreamPackage(name: "nimkdl",
                    url:  "https://github.com/greenm01/nimkdl",
                    `method`: "git")
  proc nimkdlCorey(): UpstreamPackage =
    UpstreamPackage(name: "nimkdl",
                    url:  "https://github.com/coreyleavitt/nimkdl",
                    `method`: "git")

  test "two nimkdl entries (different namespace) survive as distinct packages":
    let sel = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let e1 = buildVendoredEntry(nimkdlGreenm01(), sel, "sha256:a", "aaa", fixedPublishedAt).get
    let e2 = buildVendoredEntry(nimkdlCorey(),   sel, "sha256:b", "bbb", fixedPublishedAt).get

    let (idx1, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), e1)
    let (idx2, outcome2) = mergeVendored(idx1, e2)

    check outcome2.kind == mokAdded
    check idx2.packages.len == 2

    # Both retain their distinct identity
    let namespaces = @[idx2.packages[0].namespace,
                       idx2.packages[1].namespace]
    check "github.com/greenm01" in namespaces
    check "github.com/coreyleavitt" in namespaces

  test "canonicalize sorts collision pair deterministically by (namespace, name)":
    let sel = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let e1 = buildVendoredEntry(nimkdlGreenm01(), sel, "sha256:a", "aaa", fixedPublishedAt).get
    let e2 = buildVendoredEntry(nimkdlCorey(),   sel, "sha256:b", "bbb", fixedPublishedAt).get
    let (idx1, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), e1)
    let (afterIdx, _) = mergeVendored(idx1, e2)
    let canonical = canonicalize(afterIdx)
    check canonical.packages.len == 2
    # greenm01 < coreyleavitt lexicographically → greenm01 should sort first
    check canonical.packages[0].namespace == "github.com/coreyleavitt"
    check canonical.packages[1].namespace == "github.com/greenm01"

suite "intra-org leaf collision":
  ## Same (host/org, name) from two DIFFERENT repos under the same org.
  ## The second entry MUST be rejected; the first is preserved.
  proc acmeUtilsA(): UpstreamPackage =
    UpstreamPackage(name: "utils",
                    url:  "https://github.com/acme/utils-a",
                    `method`: "git")
  proc acmeUtilsB(): UpstreamPackage =
    UpstreamPackage(name: "utils",
                    url:  "https://github.com/acme/utils-b",
                    `method`: "git")

  test "intra-org collision: second entry rejected, first preserved":
    let sel = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let e1 = buildVendoredEntry(acmeUtilsA(), sel, "sha256:first", "aaa", fixedPublishedAt).get
    let e2 = buildVendoredEntry(acmeUtilsB(), sel, "sha256:second", "bbb", fixedPublishedAt).get

    let (idx1, outcome1) = mergeVendored(Index(schemaVersion: 1, packages: @[]), e1)
    check outcome1.kind == mokAdded
    check idx1.packages.len == 1

    let (idx2, outcome2) = mergeVendored(idx1, e2)
    # Second entry rejected
    check outcome2.kind == mokCollision
    # Index unchanged — still has only the first entry
    check idx2.packages.len == 1
    check idx2.packages[0].versions[0].contentHash == "sha256:first"
    # Collision carries both repos
    let col = outcome2.collision
    check col.namespace == "github.com/acme"
    check col.name == "utils"
    check "utils-a" in col.existingRepo
    check "utils-b" in col.newRepo

  test "same-repo new version is NOT a collision — merges normally":
    let sel1 = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let sel2 = TagSelection(kind: tskSemver, tag: "v2.0.0", version: "2.0.0")
    let e1 = buildVendoredEntry(acmeUtilsA(), sel1, "sha256:v1", "aaa", fixedPublishedAt).get
    let e2 = buildVendoredEntry(acmeUtilsA(), sel2, "sha256:v2", "bbb", fixedPublishedAt).get

    let (idx1, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), e1)
    let (idx2, outcome2) = mergeVendored(idx1, e2)
    check outcome2.kind notin [mokCollision, mokContentDrift, mokIdentityDrift]
    check idx2.packages.len == 1
    check idx2.packages[0].versions.len == 2

suite "identity drift guard":
  ## P1.1(C): checkIdentityStable wired as first check in foundPkgIdx >= 0 branch.

  test "same derived ns re-ingest → mokIdempotent, no identity drift":
    let pkg = UpstreamPackage(name: "nimkdl",
                              url: "https://github.com/coreyleavitt/nimkdl",
                              `method`: "git")
    let sel = TagSelection(kind: tskSemver, tag: "v1.0.0", version: "1.0.0")
    let e = buildVendoredEntry(pkg, sel, "sha256:aaa", "abc", fixedPublishedAt).get
    let (idx1, _) = mergeVendored(Index(schemaVersion: 1, packages: @[]), e)
    let (_, outcome) = mergeVendored(idx1, e)
    check outcome.kind == mokIdempotent

  test "org-only stored ns (no '/') → guard skipped, no false mokIdentityDrift":
    # Simulate a legacy entry with org-only namespace (pre-migration form).
    let orgOnlyPkg = Package(
      name:      "legacy",
      namespace: "coreyleavitt",   # no '/' — org-only, pre-P1.3 form
      upstream:  "https://github.com/coreyleavitt/legacy",
    )
    var legacyVersion = Version(
      version:     "1.0.0",
      contentHash: "sha256:aaa",
      attestation: "milpa-vendored",
      signedBy:    "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
      publishedAt: fixedPublishedAt,
      provenances: @[Provenance(
        kind:      pkGit,
        url:       "https://github.com/coreyleavitt/legacy",
        gitRef:    "v1.0.0",
        commitSha: "deadbeef",
      )],
    )
    var legacyIdx = Index(schemaVersion: 1, packages: @[orgOnlyPkg])
    legacyIdx.packages[0].versions = @[legacyVersion]

    # Incoming entry has same namespace as derived from URL (github.com/coreyleavitt)
    # but stored is "coreyleavitt" (no slash) → guard must be SKIPPED.
    let incomingPkg = UpstreamPackage(name: "legacy",
                                      url: "https://github.com/coreyleavitt/legacy",
                                      `method`: "git")
    let sel = TagSelection(kind: tskSemver, tag: "v2.0.0", version: "2.0.0")
    let incoming = buildVendoredEntry(incomingPkg, sel, "sha256:bbb", "ccc", fixedPublishedAt).get
    let (_, outcome) = mergeVendored(legacyIdx, incoming)
    # Must NOT fire identity drift — stored has no '/'
    check outcome.kind != mokIdentityDrift

  test "corrupted host/org stored ns → mokIdentityDrift, index unchanged":
    ## Identity drift fires when the version's git provenance URL re-derives
    ## to a namespace that does NOT match the stored package namespace.
    ## Scenario: package stored under "github.com/coreyleavitt", but incoming
    ## version has a provenance URL pointing to "github.com/attacker" — the
    ## package.namespace still matches so foundPkgIdx >= 0, but the version
    ## namespace check catches the discrepancy.
    let storedPkg = Package(
      name:      "nimkdl",
      namespace: "github.com/coreyleavitt",  # host/org form → guard active
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

    # Incoming entry: package.namespace matches stored (github.com/coreyleavitt)
    # so foundPkgIdx >= 0, but the version's provenance URL is from a different
    # org — re-deriving gives "github.com/attacker".
    let driftEntry = VendoredEntry(
      package: Package(
        name:      "nimkdl",
        namespace: "github.com/coreyleavitt",   # matches stored → foundPkgIdx >= 0
        upstream:  "https://github.com/coreyleavitt/nimkdl",
      ),
      version: Version(
        version:     "2.0.0",
        contentHash: "sha256:bbb",
        attestation: "milpa-vendored",
        signedBy:    "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
        publishedAt: fixedPublishedAt,
        provenances: @[Provenance(
          kind:      pkGit,
          url:       "https://github.com/attacker/nimkdl",  # DIFFERENT forge URL
          gitRef:    "v2.0.0",
          commitSha: "cafebabe",
        )],
      ),
    )

    let (returnedIdx, outcome) = mergeVendored(storedIdx, driftEntry)
    check outcome.kind == mokIdentityDrift
    check outcome.identity.name == "nimkdl"
    check outcome.identity.storedNamespace == "github.com/coreyleavitt"
    check outcome.identity.rederivedNamespace == "github.com/attacker"
    # Index must be UNCHANGED — no overwrite.
    check returnedIdx == storedIdx

  test "identity drift wins over collision (priority ordering)":
    ## Identity drift has higher priority than collision.
    ## Setup: an entry that BOTH triggers identity drift (version's provenance
    ## URL derives to a namespace different from stored) AND would be a collision
    ## (different repo segment under the same org). Identity drift must win.
    let storedPkg = Package(
      name:      "utils",
      namespace: "github.com/acme",
      upstream:  "https://github.com/acme/utils-a",
    )
    var storedVersion = Version(
      version:     "1.0.0",
      contentHash: "sha256:a",
      attestation: "milpa-vendored",
      signedBy:    "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
      publishedAt: fixedPublishedAt,
      provenances: @[Provenance(
        kind:      pkGit,
        url:       "https://github.com/acme/utils-a",
        gitRef:    "v1.0.0",
        commitSha: "aaa",
      )],
    )
    var storedIdx = Index(schemaVersion: 1, packages: @[storedPkg])
    storedIdx.packages[0].versions = @[storedVersion]

    # Incoming: matches (namespace="github.com/acme", name="utils") so
    # foundPkgIdx >= 0. But version provenance is from a different org
    # (→ identity drift fires) AND it's from a different repo (→ collision
    # would also fire). Identity drift has higher priority and must win.
    let driftAndCollisionEntry = VendoredEntry(
      package: Package(
        name:      "utils",
        namespace: "github.com/acme",
        upstream:  "https://github.com/acme/utils-b",   # different repo → collision condition
      ),
      version: Version(
        version:     "2.0.0",
        contentHash: "sha256:b",
        attestation: "milpa-vendored",
        signedBy:    "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
        publishedAt: fixedPublishedAt,
        provenances: @[Provenance(
          kind:      pkGit,
          url:       "https://github.com/attacker/utils",  # DIFFERENT namespace → identity drift
          gitRef:    "v2.0.0",
          commitSha: "bbb",
        )],
      ),
    )

    let (returnedIdx, outcome) = mergeVendored(storedIdx, driftAndCollisionEntry)
    check outcome.kind == mokIdentityDrift   # drift wins over collision
    check returnedIdx == storedIdx           # index unchanged

suite "M5: identity guard on derivation failure":
  ## When stored namespace is host/org (contains '/') AND deriveVersionNamespace
  ## fails on the incoming entry, the guard must NOT silently pass through.
  ## It must return mokIdentityDrift so the entry is rejected.

  test "M5: stored host/org + incoming version with underivable provenance → mokIdentityDrift":
    ## The incoming version has NO git provenance and NO signedBy →
    ## deriveVersionNamespace returns err. With stored ns containing '/',
    ## this must yield mokIdentityDrift, not silently proceed to merge.
    let storedPkg = Package(
      name:      "mypkg",
      namespace: "github.com/legit",
      upstream:  "https://github.com/legit/mypkg",
    )
    var storedVersion = Version(
      version:     "1.0.0",
      contentHash: "sha256:aaa",
      attestation: "milpa-vendored",
      signedBy:    "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
      publishedAt: fixedPublishedAt,
      provenances: @[Provenance(
        kind:      pkGit,
        url:       "https://github.com/legit/mypkg",
        gitRef:    "v1.0.0",
        commitSha: "deadbeef",
      )],
    )
    var storedIdx = Index(schemaVersion: 1, packages: @[storedPkg])
    storedIdx.packages[0].versions = @[storedVersion]

    # Incoming entry matches (namespace="github.com/legit", name="mypkg") so
    # foundPkgIdx >= 0. But the version has no provenances and no signedBy →
    # deriveVersionNamespace returns err(derrUnparseable).
    let underivableEntry = VendoredEntry(
      package: Package(
        name:      "mypkg",
        namespace: "github.com/legit",
        upstream:  "https://github.com/legit/mypkg",
      ),
      version: Version(
        version:     "2.0.0",
        contentHash: "sha256:bbb",
        attestation: "milpa-vendored",
        signedBy:    "",         # no signedBy
        publishedAt: fixedPublishedAt,
        provenances: @[],        # no provenances → deriveVersionNamespace → err
      ),
    )

    let (returnedIdx, outcome) = mergeVendored(storedIdx, underivableEntry)
    # Must reject (identity drift), not silently add
    check outcome.kind == mokIdentityDrift
    # Index must be unchanged
    check returnedIdx == storedIdx

suite "attestation epoch gate (S5)":
  ## rfc-attestation-delivery S5 / tianguis#42 deliverable 5: once the index
  ## carries a root attestation-epoch, every entry whose published_at is on
  ## or after it MUST carry a recognized attestation kind AND a bundle pin,
  ## or the merge is rejected as mokMissingAttestation.
  const epoch = "2026-06-01T00:00:00Z"

  test "post-epoch entry with no attestation is rejected":
    let entry = VendoredEntry(
      package: Package(name: "gate1", namespace: "github.com/acme",
                        upstream: "https://github.com/acme/gate1"),
      version: Version(version: "1.0.0", contentHash: "sha256:aaa",
                        attestation: "", publishedAt: "2026-06-15T00:00:00Z"),
    )
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let (returned, outcome) = mergeVendored(idx, entry)
    check outcome.kind == mokMissingAttestation
    check outcome.missingAttestation.packageName == "gate1"
    check outcome.missingAttestation.namespace == "github.com/acme"
    check outcome.missingAttestation.version == "1.0.0"
    check outcome.missingAttestation.publishedAt == "2026-06-15T00:00:00Z"
    check outcome.missingAttestation.epoch == epoch
    check returned == idx  # unchanged

  test "post-epoch entry with attestation but no bundle pin is rejected":
    let entry = VendoredEntry(
      package: Package(name: "gate2", namespace: "github.com/acme",
                        upstream: "https://github.com/acme/gate2"),
      version: Version(version: "1.0.0", contentHash: "sha256:aaa",
                        attestation: "milpa-vendored",
                        publishedAt: "2026-06-15T00:00:00Z",
                        bundlePin: none(string)),
    )
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let (returned, outcome) = mergeVendored(idx, entry)
    check outcome.kind == mokMissingAttestation
    check returned == idx

  test "post-epoch entry with attestation AND bundle pin is accepted":
    let entry = VendoredEntry(
      package: Package(name: "gate3", namespace: "github.com/acme",
                        upstream: "https://github.com/acme/gate3"),
      version: Version(version: "1.0.0", contentHash: "sha256:aaa",
                        attestation: "milpa-vendored",
                        publishedAt: "2026-06-15T00:00:00Z",
                        bundlePin: some("d" & "e".repeat(63))),
    )
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let (after, outcome) = mergeVendored(idx, entry)
    check outcome.kind == mokAdded
    check after.packages.len == 1
    check after.packages[0].versions[0].bundlePin.isSome

  test "pre-epoch entry with no attestation is unaffected (gate is forward-only)":
    let entry = VendoredEntry(
      package: Package(name: "gate4", namespace: "github.com/acme",
                        upstream: "https://github.com/acme/gate4"),
      version: Version(version: "1.0.0", contentHash: "sha256:aaa",
                        attestation: "", publishedAt: "2026-01-01T00:00:00Z"),
    )
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let (after, outcome) = mergeVendored(idx, entry)
    check outcome.kind == mokAdded
    check after.packages.len == 1

  test "no epoch set — gate is inert regardless of attestation":
    let entry = VendoredEntry(
      package: Package(name: "gate5", namespace: "github.com/acme",
                        upstream: "https://github.com/acme/gate5"),
      version: Version(version: "1.0.0", contentHash: "sha256:aaa",
                        attestation: "", publishedAt: "2026-06-15T00:00:00Z"),
    )
    let idx = Index(schemaVersion: 1, attestationEpoch: none(string), packages: @[])
    let (after, outcome) = mergeVendored(idx, entry)
    check outcome.kind == mokAdded
    check after.packages.len == 1

suite "checkIdentityStable":
  test "returns none when stored equals rederived":
    let r = checkIdentityStable("nimkdl", "github.com/coreyleavitt", "github.com/coreyleavitt")
    check r.isNone

  test "returns some(IdentityDrift) when stored != rederived":
    let r = checkIdentityStable("nimkdl", "github.com/coreyleavitt", "github.com/greenm01")
    check r.isSome
    check r.get.name == "nimkdl"
    check r.get.storedNamespace == "github.com/coreyleavitt"
    check r.get.rederivedNamespace == "github.com/greenm01"
