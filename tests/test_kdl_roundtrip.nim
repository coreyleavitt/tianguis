## KDL projection round-trip tests beyond the empty-index tracer.
##
## Each test asserts: serialize an Index value to KDL, parse it back,
## get the same Index. Bijection through canonical KDL is the load-
## bearing property for spec conformance.

import std/[unittest, options, sequtils, strutils, tables]
import tianguis/[model, kdl_io]

suite "kdl roundtrip":
  test "one-package zero-versions round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://github.com/coreyleavitt/chronos",
        ),
      ],
    )
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original

  test "packages emerge alphabetical regardless of input":
    proc pkg(name: string): Package =
      Package(name: name, namespace: "ns", upstream: "https://x/" & name)
    let original = Index(
      schemaVersion: 1,
      packages: @[pkg("zoo"), pkg("alpha"), pkg("middle")],
    )
    let canonicalized = parseKdl(formatKdl(original))
    check canonicalized.isOk
    let names = canonicalized.get.packages.mapIt(it.name)
    check names == @["alpha", "middle", "zoo"]

  test "versions emerge in descending semver order regardless of input":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://example.com/chronos",
          versions: @[
            Version(version: "0.4.0", contentHash: "sha256:a",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-01-01T00:00:00Z"),
            Version(version: "0.5.0", contentHash: "sha256:b",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-02-01T00:00:00Z"),
            Version(version: "0.4.5", contentHash: "sha256:c",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-03-01T00:00:00Z"),
          ],
        ),
      ],
    )
    let canonicalized = parseKdl(formatKdl(original))
    check canonicalized.isOk
    let vs = canonicalized.get.packages[0].versions
    check vs.len == 3
    check vs[0].version == "0.5.0"
    check vs[1].version == "0.4.5"
    check vs[2].version == "0.4.0"

  test "version requires map round-trips through KDL (canonical input)":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "chronos", namespace: "ns", upstream: "https://x/c",
        versions: @[Version(
          version: "0.5.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-05-25T00:00:00Z",
          requires: {"results": "^0.5.0", "stew": "^0.1.0"}.toOrderedTable,
        )],
      )],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get == original

  test "version requires keys emit alphabetically regardless of input order":
    let backward = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "chronos", namespace: "ns", upstream: "https://x/c",
        versions: @[Version(
          version: "0.5.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-05-25T00:00:00Z",
          requires: {"stew": "^0.1.0", "results": "^0.5.0"}.toOrderedTable,
        )],
      )],
    )
    let serialized = formatKdl(backward)
    let resultsIdx = serialized.find("\"results\"")
    let stewIdx = serialized.find("\"stew\"")
    check resultsIdx < stewIdx

  test "version with git + oci provenances round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://github.com/coreyleavitt/chronos",
          versions: @[
            Version(
              version: "0.5.0",
              contentHash: "sha256:abc",
              attestation: "author-signed",
              signedBy: "https://github.com/coreyleavitt",
              publishedAt: "2026-05-25T00:00:00Z",
              provenances: @[
                Provenance(
                  kind: pkGit,
                  url: "https://github.com/coreyleavitt/chronos.git",
                  gitRef: "v0.5.0",
                  commitSha: "abcdef1234567890",
                ),
                Provenance(
                  kind: pkOci,
                  registry: "ghcr.io",
                  repository: "coreyleavitt/chronos",
                  digest: "sha256:fedcba",
                ),
              ],
            ),
          ],
        ),
      ],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get == original

  # ---------------------------------------------------------------------------
  # OCI provenance source (source git repo this artifact was published from)
  # ---------------------------------------------------------------------------

  test "oci provenance with source round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "nkdl", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/nkdl",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:dd907474",
          attestation: "author-signed",
          signedBy: "https://github.com/coreyleavitt",
          publishedAt: "2026-06-08T01:18:24Z",
          provenances: @[Provenance(
            kind: pkOci,
            registry: "ghcr.io",
            repository: "coreyleavitt/nkdl",
            digest: "sha256:fedcba",
            source: "https://github.com/coreyleavitt/nkdl.git",
          )],
        )],
      )],
    )
    let serialized = formatKdl(original)
    check "source (url)\"https://github.com/coreyleavitt/nkdl.git\"" in serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.packages[0].versions[0].provenances[0].source ==
      "https://github.com/coreyleavitt/nkdl.git"

  test "oci provenance without source stays absent (empty string, no source node emitted)":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "nkdl", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/nkdl",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:dd907474",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-08T01:18:24Z",
          provenances: @[Provenance(
            kind: pkOci,
            registry: "ghcr.io",
            repository: "coreyleavitt/nkdl",
            digest: "sha256:fedcba",
            # source deliberately omitted -> ""
          )],
        )],
      )],
    )
    let serialized = formatKdl(original)
    check "source" notin serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.packages[0].versions[0].provenances[0].source == ""

  test "one-package one-version round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://github.com/coreyleavitt/chronos",
          versions: @[
            Version(
              version: "0.5.0",
              contentHash: "sha256:abc",
              attestation: "milpa-vendored",
              signedBy: "milpa-bot",
              publishedAt: "2026-05-25T00:00:00Z",
            ),
          ],
        ),
      ],
    )
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original

  # ---------------------------------------------------------------------------
  # S3: host/org namespace round-trip + same-name/two-namespace survival
  # ---------------------------------------------------------------------------

  test "host/org namespace (dots and slashes) round-trips intact":
    ## Regression: namespace values like "github.com/coreyleavitt" contain
    ## '.' and '/' which are safe inside KDL quoted strings but must survive
    ## emit → parse unchanged.
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "nimkdl",
          namespace: "github.com/coreyleavitt",
          upstream: "https://github.com/coreyleavitt/nimkdl",
        ),
      ],
    )
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get.packages.len == 1
    check parsed.get.packages[0].namespace == "github.com/coreyleavitt"

  test "two packages with same name but different namespace survive round-trip as two distinct entries":
    ## S3 regression: (namespace, name) is the identity tuple. Two packages
    ## named "nimkdl" under different namespaces must NOT be collapsed, merged,
    ## or dropped at the serialization layer.
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "nimkdl",
          namespace: "github.com/greenm01",
          upstream: "https://github.com/greenm01/nimkdl",
        ),
        Package(
          name: "nimkdl",
          namespace: "github.com/coreyleavitt",
          upstream: "https://github.com/coreyleavitt/nimkdl",
        ),
      ],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get.packages.len == 2
    # Both namespaces must be present
    let namespaces = parsed.get.packages.mapIt(it.namespace)
    check "github.com/greenm01" in namespaces
    check "github.com/coreyleavitt" in namespaces
    # Both names must be "nimkdl"
    for pkg in parsed.get.packages:
      check pkg.name == "nimkdl"

  # ---------------------------------------------------------------------------
  # S5: partiallyResolved round-trip
  # ---------------------------------------------------------------------------

  test "partiallyResolved=true round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "somepkg", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/somepkg",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          partiallyResolved: true,
        )],
      )],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get.packages[0].versions[0].partiallyResolved == true

  test "partiallyResolved=false does not emit the node":
    ## A version with partiallyResolved=false (default) must NOT include the
    ## `partially_resolved` node in its KDL output — keeps the S6 migration
    ## noise-free (2613 existing entries don't gain a spurious field).
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "somepkg", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/somepkg",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          partiallyResolved: false,
        )],
      )],
    )
    let serialized = formatKdl(original)
    check "partially_resolved" notin serialized

  test "partiallyResolved=false round-trips as false":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "somepkg", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/somepkg",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          partiallyResolved: false,
        )],
      )],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get.packages[0].versions[0].partiallyResolved == false

  # ---------------------------------------------------------------------------
  # Durable Rekor reference (author-signed attestation pointer)
  # ---------------------------------------------------------------------------

  test "rekor block (uuid + log_index + integrated_time) round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "nkdl", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/nkdl",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:dd907474",
          attestation: "author-signed",
          signedBy: "https://github.com/coreyleavitt/tianguis/.github/workflows/publish.yaml@refs/heads/main",
          publishedAt: "2026-06-08T01:18:24Z",
          rekor: some(RekorRef(
            uuid: "108e9186e8c5677abce5a62d285437741218f878474a02d9a4dac01dc12e39b979336e712890d636",
            logIndex: "1753541583",
            integratedTime: "1780881469",
          )),
        )],
      )],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get == original
    check parsed.get.packages[0].versions[0].rekor.isSome
    check parsed.get.packages[0].versions[0].rekor.get.uuid ==
      "108e9186e8c5677abce5a62d285437741218f878474a02d9a4dac01dc12e39b979336e712890d636"

  test "rekor=none does NOT emit a rekor block":
    ## milpa-vendored versions carry no rekor pointer; the field must not
    ## leak an empty block into the index (keeps the 2600+ vendored entries
    ## noise-free, same discipline as partially_resolved).
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "vendored", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/vendored",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          rekor: none(RekorRef),
        )],
      )],
    )
    let serialized = formatKdl(original)
    check "rekor" notin serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get.packages[0].versions[0].rekor.isNone

  # ---------------------------------------------------------------------------
  # Bundle pin (delivery-integrity sha256 of the attestation bundle bytes)
  # ---------------------------------------------------------------------------

  test "bundle pin (sha256) round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "nkdl", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/nkdl",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:dd907474",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-08T01:18:24Z",
          bundlePin: some("ab".repeat(32)),
        )],
      )],
    )
    let serialized = formatKdl(original)
    check "bundle sha256=\"" & "ab".repeat(32) & "\"" in serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.packages[0].versions[0].bundlePin.isSome
    check parsed.get.packages[0].versions[0].bundlePin.get == "ab".repeat(32)

  test "bundle pin absent does NOT emit a bundle node":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "vendored", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/vendored",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          bundlePin: none(string),
        )],
      )],
    )
    let serialized = formatKdl(original)
    check "bundle" notin serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get.packages[0].versions[0].bundlePin.isNone

  test "rekor block with only log_index (no uuid) round-trips; absent fields stay empty":
    ## A publish that captured logIndex/integratedTime but could not resolve a
    ## UUID (best-effort Rekor lookup) must still round-trip; omitted sub-fields
    ## emit nothing and parse back as "".
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "p", namespace: "github.com/org",
        upstream: "https://github.com/org/p",
        versions: @[Version(
          version: "1.0.0", contentHash: "sha256:abc",
          attestation: "author-signed", signedBy: "https://github.com/org",
          publishedAt: "2026-06-08T00:00:00Z",
          rekor: some(RekorRef(uuid: "", logIndex: "42", integratedTime: "1780881469")),
        )],
      )],
    )
    let serialized = formatKdl(original)
    check "uuid" notin serialized
    check "log_index" in serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.packages[0].versions[0].rekor.get.uuid == ""
    check parsed.get.packages[0].versions[0].rekor.get.logIndex == "42"

  # ---------------------------------------------------------------------------
  # C1: KDL injection — crafted name/namespace must not corrupt the output
  # ---------------------------------------------------------------------------

  test "C1 injection: crafted name containing quote/newline/brace round-trips as one package (no phantom block)":
    ## Proof: a name that looks like a KDL injection payload does NOT produce
    ## extra top-level nodes when re-parsed. The formatter must escape all
    ## special characters inside quoted strings.
    let injectionName = "foo\"}\npackage \"evil\" {\n namespace \"github.com/victim\""
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name:      injectionName,
        namespace: "github.com/legit",
        upstream:  "https://github.com/legit/foo",
      )],
    )
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    # Must parse cleanly
    check parsed.isOk
    if parsed.isOk:
      # Exactly ONE package — no phantom "evil" block
      check parsed.get.packages.len == 1
      # The package name must be the literal injection string (round-trip)
      check parsed.get.packages[0].name == injectionName
      # The namespace must be as supplied, not hijacked
      check parsed.get.packages[0].namespace == "github.com/legit"

  # ---------------------------------------------------------------------------
  # Root-level attestation-epoch (rfc-attestation-delivery S2)
  # ---------------------------------------------------------------------------

  test "attestation-epoch round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      attestationEpoch: some("2026-07-01T00:00:00Z"),
      packages: @[],
    )
    let serialized = formatKdl(original)
    check "attestation-epoch \"2026-07-01T00:00:00Z\"" in serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.attestationEpoch.isSome
    check parsed.get.attestationEpoch.get == "2026-07-01T00:00:00Z"

  test "attestation-epoch absent does NOT emit an attestation-epoch node":
    let original = Index(
      schemaVersion: 1,
      attestationEpoch: none(string),
      packages: @[],
    )
    let serialized = formatKdl(original)
    check "attestation-epoch" notin serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get.attestationEpoch.isNone

  # ---------------------------------------------------------------------------
  # Root-level attestation-epoch-commitment (D-Watermark pre-epoch set
  # commitment C — milpa rfc-attestation-v1-normative.md S-EpochCommitment).
  # A NEW, distinct root field from attestation-epoch above.
  # ---------------------------------------------------------------------------

  test "attestation-epoch-commitment round-trips through KDL":
    let c = "5".repeat(64)
    let original = Index(
      schemaVersion: 1,
      attestationEpochCommitment: some(c),
      packages: @[],
    )
    let serialized = formatKdl(original)
    check ("attestation-epoch-commitment \"" & c & "\"") in serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.attestationEpochCommitment.isSome
    check parsed.get.attestationEpochCommitment.get == c

  test "attestation-epoch-commitment absent does NOT emit the node":
    let original = Index(
      schemaVersion: 1,
      attestationEpochCommitment: none(string),
      packages: @[],
    )
    let serialized = formatKdl(original)
    check "attestation-epoch-commitment" notin serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get.attestationEpochCommitment.isNone

  test "attestation-epoch and attestation-epoch-commitment coexist independently":
    ## D16: the two root fields are siblings, not a re-typed single field —
    ## arming one must never disturb the other.
    let c = "7".repeat(64)
    let original = Index(
      schemaVersion: 1,
      attestationEpoch: some("2026-07-01T00:00:00Z"),
      attestationEpochCommitment: some(c),
      packages: @[],
    )
    let serialized = formatKdl(original)
    check "attestation-epoch \"2026-07-01T00:00:00Z\"" in serialized
    check ("attestation-epoch-commitment \"" & c & "\"") in serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.attestationEpoch.get == "2026-07-01T00:00:00Z"
    check parsed.get.attestationEpochCommitment.get == c

  # ---------------------------------------------------------------------------
  # Package-level authorized-signer (rfc-attestation-delivery S8 Layer 3 —
  # per-package signer-continuity ratchet, tianguis#42)
  # ---------------------------------------------------------------------------

  test "authorizedSigner round-trips through KDL when set":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "libp2p", namespace: "github.com/alice",
        upstream: "https://github.com/alice/libp2p",
        authorizedSigner: some(
          "https://github.com/alice/libp2p/.github/workflows/publish.yaml@refs/heads/main"),
      )],
    )
    let serialized = formatKdl(original)
    check "authorized-signer \"https://github.com/alice/libp2p/.github/workflows/publish.yaml@refs/heads/main\"" in serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.packages[0].authorizedSigner.isSome

  test "authorizedSigner absent does NOT emit an authorized-signer node":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "vendoredonly", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/vendoredonly",
        authorizedSigner: none(string),
      )],
    )
    let serialized = formatKdl(original)
    check "authorized-signer" notin serialized
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get.packages[0].authorizedSigner.isNone

  test "same-name two-namespace pair emerges in canonical (namespace, name) order after round-trip":
    ## canonicalize sorts by (namespace, name). "github.com/coreyleavitt" <
    ## "github.com/greenm01" lexicographically, so coreyleavitt comes first
    ## regardless of insertion order.
    let insertedGreenFirst = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "nimkdl",
          namespace: "github.com/greenm01",
          upstream: "https://github.com/greenm01/nimkdl",
        ),
        Package(
          name: "nimkdl",
          namespace: "github.com/coreyleavitt",
          upstream: "https://github.com/coreyleavitt/nimkdl",
        ),
      ],
    )
    let insertedCoreyFirst = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "nimkdl",
          namespace: "github.com/coreyleavitt",
          upstream: "https://github.com/coreyleavitt/nimkdl",
        ),
        Package(
          name: "nimkdl",
          namespace: "github.com/greenm01",
          upstream: "https://github.com/greenm01/nimkdl",
        ),
      ],
    )
    let r1 = parseKdl(formatKdl(insertedGreenFirst))
    let r2 = parseKdl(formatKdl(insertedCoreyFirst))
    check r1.isOk
    check r2.isOk
    # Both must produce the same canonical ordering
    check r1.get == r2.get
    # coreyleavitt < greenm01 lexicographically → coreyleavitt comes first
    check r1.get.packages[0].namespace == "github.com/coreyleavitt"
    check r1.get.packages[1].namespace == "github.com/greenm01"
