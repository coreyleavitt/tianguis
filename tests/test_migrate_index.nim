## Tests for migrateIndex (P1.3) — pure namespace-migration function.
##
## Each gate is listed explicitly in the test name.

import std/[unittest, strutils, tables, algorithm, sequtils]
import tianguis/[model, kdl_io, json_io, namespace, migrate]

# ---------------------------------------------------------------------------
# Helpers — synthetic index builders
# ---------------------------------------------------------------------------

proc gitProv(url: string, gitRef = "v1.0.0", sha = "deadbeef"): Provenance =
  Provenance(kind: pkGit, url: url, gitRef: gitRef, commitSha: sha)

proc ociProv(registry = "ghcr.io", repository = "coreyleavitt/nimkdl",
             digest = "sha256:abcd"): Provenance =
  Provenance(kind: pkOci, registry: registry, repository: repository, digest: digest)

proc makeVersion(vstr: string, prov: Provenance,
                 contentHash = "sha256:aabbcc",
                 signedBy = "",
                 publishedAt = "2026-01-01T00:00:00Z",
                 partiallyResolved = false,
                 requires: OrderedTable[string, string] =
                   initOrderedTable[string, string]()): Version =
  Version(
    version:          vstr,
    contentHash:      contentHash,
    provenances:      @[prov],
    attestation:      "milpa-vendored",
    signedBy:         signedBy,
    publishedAt:      publishedAt,
    partiallyResolved: partiallyResolved,
    requires:         requires,
  )

## Org-only entry: namespace has no '/' (pre-migration form).
proc orgOnlyPackage(): Package =
  Package(
    name:      "milpa",
    namespace: "coreyleavitt",
    upstream:  "https://github.com/coreyleavitt/milpa",
    versions:  @[
      makeVersion("1.0.0",
        gitProv("https://github.com/coreyleavitt/milpa"),
        contentHash = "sha256:milpa100"),
    ],
  )

## Already-migrated host/org entry — migrateIndex should be a no-op.
proc alreadyMigratedPackage(): Package =
  Package(
    name:      "fresco",
    namespace: "github.com/coreyleavitt",
    upstream:  "https://github.com/coreyleavitt/fresco",
    versions:  @[
      makeVersion("2.0.0",
        gitProv("https://github.com/coreyleavitt/fresco"),
        contentHash = "sha256:fresco200"),
    ],
  )

## The known split: nimkdl from greenm01 (git) and coreyleavitt (oci+signedBy).
proc nimkdlGreenm01Version(): Version =
  makeVersion("0.5.0",
    gitProv("https://github.com/greenm01/nimkdl"),
    contentHash = "sha256:nimkdl-greenm01")

proc nimkdlCoreyVersion(): Version =
  Version(
    version:      "1.0.0",
    contentHash:  "sha256:nimkdl-corey",
    provenances:  @[ociProv()],
    attestation:  "author-signed",
    signedBy:     "https://github.com/coreyleavitt/tianguis/.github/workflows/publish.yaml@refs/heads/main",
    publishedAt:  "2026-01-01T00:00:00Z",
    partiallyResolved: false,
    requires:     initOrderedTable[string, string](),
  )

## Conflated nimkdl package (both versions in one package — pre-migration).
proc conflatedNimkdlPackage(): Package =
  Package(
    name:      "nimkdl",
    namespace: "greenm01",     # org-only, pre-migration
    upstream:  "https://github.com/greenm01/nimkdl",
    versions:  @[nimkdlGreenm01Version(), nimkdlCoreyVersion()],
  )

## A version with no git provenance and no signedBy — cannot derive.
proc underivableVersion(): Version =
  Version(
    version:     "1.0.0",
    contentHash: "sha256:noderi",
    provenances: @[],
    attestation: "milpa-vendored",
    signedBy:    "",
    publishedAt: "2026-01-01T00:00:00Z",
    partiallyResolved: false,
    requires:    initOrderedTable[string, string](),
  )

proc smallIndex(pkgs: seq[Package]): Index =
  Index(schemaVersion: 1, packages: pkgs)

# ---------------------------------------------------------------------------
# Gate 1 — KDL byte-identical round-trip + JSON shape
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 1: in-memory KDL round-trip":
  test "formatKdl re-parses to equal value (byte-identical KDL round-trip)":
    let idx = smallIndex(@[orgOnlyPackage()])
    let migrated = migrateIndex(idx)
    check migrated.isOk
    let migOut = migrated.get

    let kdlStr = formatKdl(migOut)
    let reparsed = parseKdl(kdlStr)
    check reparsed.isOk
    check reparsed.get == migOut

  test "formatJson is valid JSON containing expected namespace":
    let idx = smallIndex(@[orgOnlyPackage()])
    let migOut = migrateIndex(idx).get
    let jsonStr = formatJson(migOut)
    let reparsed = parseJson(jsonStr)
    check reparsed.isOk
    check reparsed.get.packages[0].namespace == "github.com/coreyleavitt"

# ---------------------------------------------------------------------------
# Gate 1b — full field-level KDL round-trip identity (catches silent field drops)
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 1b: full field-level KDL round-trip identity":
  test "migrateIndex(parseKdl(formatKdl(migOut))) == migOut (every field preserved)":
    # Use a version with partiallyResolved=true and a requires entry to exercise
    # ALL fields that Version == compares (partiallyResolved, requires, signedBy,
    # publishedAt, attestation, contentHash, provenances).
    var reqs = initOrderedTable[string, string]()
    reqs["chronos"] = ">=3.0.0"
    let fullVersion = Version(
      version:           "1.5.0",
      contentHash:       "sha256:full1234",
      provenances:       @[gitProv("https://github.com/coreyleavitt/milpa")],
      attestation:       "milpa-vendored",
      signedBy:          "https://github.com/coreyleavitt/tianguis/.github/workflows/pub.yaml@refs/heads/main",
      publishedAt:       "2026-03-01T12:00:00Z",
      partiallyResolved: true,    # the field json_io silently drops
      requires:          reqs,
    )
    let pkg = Package(
      name:      "milpa",
      namespace: "github.com/coreyleavitt",   # already host/org — migration no-op
      upstream:  "https://github.com/coreyleavitt/milpa",
      versions:  @[fullVersion],
    )
    let idx = smallIndex(@[pkg])
    let migOut = migrateIndex(idx).get

    let reparsedResult = parseKdl(formatKdl(migOut))
    check reparsedResult.isOk
    let reparsed = reparsedResult.get
    # Re-migrate the round-tripped value — must equal original output
    let remigratedResult = migrateIndex(reparsed)
    check remigratedResult.isOk
    check remigratedResult.get == migOut

  test "partiallyResolved field is preserved through KDL round-trip (not silently dropped)":
    let partialVersion = makeVersion("1.0.0",
      gitProv("https://github.com/coreyleavitt/test"),
      contentHash = "sha256:partial",
      partiallyResolved = true)
    let pkg = Package(
      name:      "test",
      namespace: "github.com/coreyleavitt",
      upstream:  "https://github.com/coreyleavitt/test",
      versions:  @[partialVersion],
    )
    let migOut = migrateIndex(smallIndex(@[pkg])).get
    let kdlStr = formatKdl(migOut)
    let reparsed = parseKdl(kdlStr)
    check reparsed.isOk
    check reparsed.get.packages[0].versions[0].partiallyResolved == true

# ---------------------------------------------------------------------------
# Gate 2 — no empty namespaces remain
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 2: zero empty namespace entries":
  test "org-only entry gets host/org namespace after migration":
    let migOut = migrateIndex(smallIndex(@[orgOnlyPackage()])).get
    for pkg in migOut.packages:
      check pkg.namespace.len > 0
      check '/' in pkg.namespace

  test "conflated nimkdl entry has no empty namespace after migration":
    let migOut = migrateIndex(smallIndex(@[conflatedNimkdlPackage()])).get
    for pkg in migOut.packages:
      check pkg.namespace.len > 0
      check '/' in pkg.namespace

# ---------------------------------------------------------------------------
# Gate 3 — every namespace matches ^[a-z0-9.-]+/[a-zA-Z0-9_.~-]+$
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 3: namespace regex conformance":
  ## The pattern ^[a-z0-9.-]+/[a-zA-Z0-9_.~-]+$ (host/org form).
  proc matchesPattern(ns: string): bool =
    ## Manual check: split on first '/', validate each part.
    let slashPos = ns.find('/')
    if slashPos <= 0: return false
    let host = ns[0 ..< slashPos]
    let org  = ns[slashPos + 1 .. ^1]
    if host.len == 0 or org.len == 0: return false
    for c in host:
      if c notin {'a'..'z', '0'..'9', '.', '-'}: return false
    for c in org:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '.', '~', '-'}: return false
    true

  test "all output namespaces match host/org pattern":
    let idx = smallIndex(@[
      orgOnlyPackage(),
      alreadyMigratedPackage(),
      conflatedNimkdlPackage(),
    ])
    let migOut = migrateIndex(idx).get
    for pkg in migOut.packages:
      check matchesPattern(pkg.namespace)

# ---------------------------------------------------------------------------
# Gate 4 — nimkdl pair splits into two packages with distinct namespaces
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 4: nimkdl pair splits into two packages":
  test "conflated nimkdl → 2 packages, greenm01 and coreyleavitt, versions intact":
    let idx = smallIndex(@[conflatedNimkdlPackage()])
    let result = migrateIndex(idx)
    check result.isOk
    let migOut = result.get

    check migOut.packages.len == 2

    let namespaces = migOut.packages.mapIt(it.namespace)
    check "github.com/greenm01" in namespaces
    check "github.com/coreyleavitt" in namespaces

    # Each package carries exactly its own version
    for pkg in migOut.packages:
      check pkg.name == "nimkdl"
      check pkg.versions.len == 1
      if pkg.namespace == "github.com/greenm01":
        check pkg.versions[0].version == "0.5.0"
        check pkg.versions[0].contentHash == "sha256:nimkdl-greenm01"
      elif pkg.namespace == "github.com/coreyleavitt":
        check pkg.versions[0].version == "1.0.0"
        check pkg.versions[0].contentHash == "sha256:nimkdl-corey"

# ---------------------------------------------------------------------------
# Gate 5a — output_package_count >= input_package_count
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 5a: only splits or preserves, never drops packages":
  test "output package count >= input package count (org-only + already-migrated)":
    let idx = smallIndex(@[orgOnlyPackage(), alreadyMigratedPackage()])
    let migOut = migrateIndex(idx).get
    check migOut.packages.len >= idx.packages.len

  test "output package count > input when conflated nimkdl is present (split)":
    let idx = smallIndex(@[conflatedNimkdlPackage()])
    let migOut = migrateIndex(idx).get
    check migOut.packages.len > idx.packages.len

# ---------------------------------------------------------------------------
# Gate 5b — version conservation bijection (multiset equality)
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 5b: version conservation bijection":
  ## Build multiset keyed on (version_string, content_hash). Assert input == output.
  ## Includes a fixture with same version_string but different content_hash
  ## to exercise the content_hash component of the key.

  proc versionMultiset(idx: Index): seq[tuple[vstr, ch: string]] =
    result = @[]
    for pkg in idx.packages:
      for v in pkg.versions:
        result.add((v.version, v.contentHash))
    result.sort(proc(a, b: tuple[vstr, ch: string]): int =
      if a.vstr != b.vstr: cmp(a.vstr, b.vstr) else: cmp(a.ch, b.ch)
    )

  test "version multiset is conserved across migration (nimkdl + milpa)":
    let idx = smallIndex(@[orgOnlyPackage(), conflatedNimkdlPackage()])
    let migOut = migrateIndex(idx).get
    let inSet  = versionMultiset(idx)
    let outSet = versionMultiset(migOut)
    check inSet == outSet

  test "same-version-string / different-content-hash pair is conserved (tests ch component)":
    ## Two packages where both have version "1.0.0" but different content hashes.
    ## Conservation must distinguish them by content_hash.
    let v1 = makeVersion("1.0.0",
      gitProv("https://github.com/coreyleavitt/pkgA"),
      contentHash = "sha256:aaaa")
    let v2 = makeVersion("1.0.0",
      gitProv("https://github.com/coreyleavitt/pkgB"),
      contentHash = "sha256:bbbb")
    let pkg1 = Package(name: "pkgA", namespace: "coreyleavitt",
                       upstream: "https://github.com/coreyleavitt/pkgA",
                       versions: @[v1])
    let pkg2 = Package(name: "pkgB", namespace: "coreyleavitt",
                       upstream: "https://github.com/coreyleavitt/pkgB",
                       versions: @[v2])
    let idx = smallIndex(@[pkg1, pkg2])
    let migOut = migrateIndex(idx).get
    let inSet  = versionMultiset(idx)
    let outSet = versionMultiset(migOut)
    check inSet == outSet

  test "conflated nimkdl: same-vstr-different-ch split is conserved":
    ## A single conflated package with two versions that share version string "1.0.0"
    ## but derive to different namespaces (different orgs) and carry different content
    ## hashes — the multiset must be preserved after the split.
    let vA = makeVersion("1.0.0",
      gitProv("https://github.com/alpha/nimkdl"),
      contentHash = "sha256:alpha")
    let vB = makeVersion("1.0.0",
      gitProv("https://github.com/beta/nimkdl"),
      contentHash = "sha256:beta")
    let conflatedPkg = Package(
      name:      "nimkdl",
      namespace: "alpha",
      upstream:  "https://github.com/alpha/nimkdl",
      versions:  @[vA, vB],
    )
    let idx = smallIndex(@[conflatedPkg])
    let migOut = migrateIndex(idx).get
    let inSet  = versionMultiset(idx)
    let outSet = versionMultiset(migOut)
    check inSet == outSet
    # Both versions split into two packages
    check migOut.packages.len == 2

# ---------------------------------------------------------------------------
# Gate 6 — idempotency
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 6: idempotency":
  test "migrateIndex(migrateIndex(idx)) == migrateIndex(idx) for all fixtures":
    let fixtures: seq[Index] = @[
      smallIndex(@[orgOnlyPackage()]),
      smallIndex(@[alreadyMigratedPackage()]),
      smallIndex(@[conflatedNimkdlPackage()]),
      smallIndex(@[orgOnlyPackage(), alreadyMigratedPackage(), conflatedNimkdlPackage()]),
    ]
    for idx in fixtures:
      let first  = migrateIndex(idx)
      check first.isOk
      let second = migrateIndex(first.get)
      check second.isOk
      check second.get == first.get

# ---------------------------------------------------------------------------
# Gate 6b — canonicalization is the mechanism, not luck
# ---------------------------------------------------------------------------

suite "migrateIndex — gate 6b: canonicalization on mis-ordered input":
  test "reversed-order input converges to same canonical output":
    let forward  = smallIndex(@[orgOnlyPackage(), alreadyMigratedPackage()])
    let reversed = smallIndex(@[alreadyMigratedPackage(), orgOnlyPackage()])
    let outForward  = migrateIndex(forward)
    let outReversed = migrateIndex(reversed)
    check outForward.isOk
    check outReversed.isOk
    check outForward.get == outReversed.get

  test "nimkdl: versions in reversed order → same canonical split":
    let conflated_reversed = Package(
      name:      "nimkdl",
      namespace: "greenm01",
      upstream:  "https://github.com/greenm01/nimkdl",
      versions:  @[nimkdlCoreyVersion(), nimkdlGreenm01Version()],  # reversed
    )
    let idx_fwd = smallIndex(@[conflatedNimkdlPackage()])
    let idx_rev = smallIndex(@[conflated_reversed])
    let out_fwd = migrateIndex(idx_fwd)
    let out_rev = migrateIndex(idx_rev)
    check out_fwd.isOk
    check out_rev.isOk
    check out_fwd.get == out_rev.get

# ---------------------------------------------------------------------------
# Derivation failure → err(mhkDerivationFailed) with correct diagnostic fields
# ---------------------------------------------------------------------------

suite "migrateIndex — derivation failure":
  test "version with no git provenance and empty signedBy → err(mhkDerivationFailed)":
    let pkg = Package(
      name:      "broken",
      namespace: "",
      upstream:  "https://github.com/coreyleavitt/broken",
      versions:  @[underivableVersion()],
    )
    let result = migrateIndex(smallIndex(@[pkg]))
    check result.isErr
    let halt = result.getErr
    check halt.kind == mhkDerivationFailed
    check halt.packageName == "broken"
    check halt.version == "1.0.0"
    check halt.error == derrUnparseable

  test "derivation failure carries empty provenanceUrl when no git prov":
    let pkg = Package(
      name:      "broken",
      namespace: "",
      upstream:  "https://github.com/coreyleavitt/broken",
      versions:  @[underivableVersion()],
    )
    let halt = migrateIndex(smallIndex(@[pkg])).getErr
    check halt.provenanceUrl == ""   # no git provenance → empty

  test "derivation failure on unparseable git URL":
    let v = makeVersion("1.0.0", gitProv("not-a-url-at-all"))
    let pkg = Package(
      name:      "broken-url",
      namespace: "",
      upstream:  "https://github.com/coreyleavitt/broken-url",
      versions:  @[v],
    )
    let result = migrateIndex(smallIndex(@[pkg]))
    check result.isErr
    let halt = result.getErr
    check halt.kind == mhkDerivationFailed
    check halt.error == derrUnparseable
    check halt.provenanceUrl == "not-a-url-at-all"
