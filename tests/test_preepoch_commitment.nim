## Tests for `preepoch_commitment.nim` — the D-Watermark pre-epoch set
## commitment construction (milpa `docs/rfc-attestation-v1-normative.md`
## §6 S-EpochCommitment).
##
## The golden `C` vectors (V1-V4) are the cross-impl byte-exactness gate
## (D16): copied verbatim from milpa's own pinned golden vectors
## (`impls/python/tests/test_epoch_commitment.py`,
## `impls/rust/crates/milpa-core/src/epoch_commitment_tests.rs`). If these
## fail, tianguis's `C` diverges from milpa's and every consumer's
## `EpochCommitmentStatus` will collapse to `ArmingInvalid` the moment a
## registry arms — this is the single most load-bearing test in this module.

import std/[unittest, strutils, json]
import tianguis/[model, preepoch_commitment]

proc mkId(namespace, name, version, contentHash: string): PreEpochIdentity =
  PreEpochIdentity(namespace: namespace, name: name, version: version, contentHash: contentHash)

suite "golden C vectors (D16) — byte-exact cross-impl parity":
  test "V1 — two entries, order-independent":
    let a = "a".repeat(64)
    let b = "b".repeat(64)
    let alice = mkId("alice", "leftpad", "1.0.0", "dag-sha256:" & a)
    let bob = mkId("bob", "rightpad", "2.0.0", "dag-sha256:" & b)

    # Passed REVERSED to prove order-independence (sorting, not input
    # order, determines the preimage).
    let identities = @[bob, alice]

    let expectedPreimage = "milpa-preepoch-v1:alice\x1fleftpad\x1f1.0.0\x1fdag-sha256:" & a &
      "\x1ebob\x1frightpad\x1f2.0.0\x1fdag-sha256:" & b
    check canonicalPreimage(identities) == expectedPreimage

    check commitmentDigest(identities) ==
      "53f35143feda939da3ecf1009a769ae01d522751a696b935fb8c8a881d44a6b9"

  test "V2 — tie case: precedence-equal, raw-string distinct":
    let c = "c".repeat(64)
    let build = mkId("acme", "x", "1.0.0+build", "dag-sha256:" & c)
    let plain = mkId("acme", "x", "1.0.0", "dag-sha256:" & c)

    # Passed REVERSED.
    let identities = @[build, plain]

    check commitmentDigest(identities) ==
      "17f9ae521c99bbc7051444de207b36830c18c66315aee5b2e87f89b57c7ce06a"

  test "V3 — empty set":
    let identities: seq[PreEpochIdentity] = @[]
    check canonicalBytes(identities) == ""
    check commitmentDigest(identities) ==
      "d5c23594d424a16e23b6c470c0c2d3040b7df729a58b7b36954d99a31f3ad7ea"

  test "V4 — namespace sensitivity":
    let d = "d".repeat(64)
    let alice = @[mkId("alice", "pkg", "1.2.3", "dag-sha256:" & d)]
    let mallory = @[mkId("mallory", "pkg", "1.2.3", "dag-sha256:" & d)]

    check commitmentDigest(alice) ==
      "bc9526e48be666d8cfba8c4a3005ddc5992796a3fa038ba0a9e783cffd14d254"
    check commitmentDigest(mallory) ==
      "8dd8314500a2ab22caf34da0cd34314ba079b676ab5eb28234926062ee07e7ad"
    check commitmentDigest(alice) != commitmentDigest(mallory)

suite "sortedDeduped":
  test "exact-duplicate 4-tuples collapse to one":
    let h = "e".repeat(64)
    let one = mkId("ns", "pkg", "1.0.0", "dag-sha256:" & h)
    let identities = @[one, one, one]
    check sortedDeduped(identities).len == 1

  test "namespace, then name, then version precedence, then content_hash order":
    let h1 = "1".repeat(64)
    let h2 = "2".repeat(64)
    let identities = @[
      mkId("b", "b", "1.0.0", h1),
      mkId("a", "b", "2.0.0", h1),
      mkId("a", "a", "1.0.0", h1),
      mkId("a", "a", "1.0.0", h2),
      mkId("a", "a", "2.0.0", h1),
    ]
    let ordered = sortedDeduped(identities)
    check ordered.len == 5
    check ordered[0] == mkId("a", "a", "1.0.0", h1)
    check ordered[1] == mkId("a", "a", "1.0.0", h2)
    check ordered[2] == mkId("a", "a", "2.0.0", h1)
    check ordered[3] == mkId("a", "b", "2.0.0", h1)
    check ordered[4] == mkId("b", "b", "1.0.0", h1)

  test "parseable versions sort before unparseable ones (two-bucket rule)":
    let h = "3".repeat(64)
    let identities = @[
      mkId("ns", "pkg", "not-a-version", h),
      mkId("ns", "pkg", "1.0.0", h),
      mkId("ns", "pkg", "0.1.0", h),
    ]
    let ordered = sortedDeduped(identities)
    check ordered[0].version == "0.1.0"
    check ordered[1].version == "1.0.0"
    check ordered[2].version == "not-a-version"

  test "prerelease sorts before its release (semver 2.0 §11)":
    let h = "4".repeat(64)
    let identities = @[
      mkId("ns", "pkg", "1.0.0", h),
      mkId("ns", "pkg", "1.0.0-alpha", h),
      mkId("ns", "pkg", "1.0.0-alpha.1", h),
    ]
    let ordered = sortedDeduped(identities)
    check ordered[0].version == "1.0.0-alpha"
    check ordered[1].version == "1.0.0-alpha.1"
    check ordered[2].version == "1.0.0"

  test "numeric prerelease identifiers compare numerically, not lexicographically":
    let h = "5".repeat(64)
    let identities = @[
      mkId("ns", "pkg", "1.0.0-alpha.10", h),
      mkId("ns", "pkg", "1.0.0-alpha.2", h),
    ]
    let ordered = sortedDeduped(identities)
    check ordered[0].version == "1.0.0-alpha.2"
    check ordered[1].version == "1.0.0-alpha.10"

  test "leading v-prefix parses (v1.2.3 == 1.2.3 precedence)":
    let h = "6".repeat(64)
    let identities = @[
      mkId("ns", "pkg", "v1.2.3", h),
      mkId("ns", "pkg", "1.2.4", h),
    ]
    let ordered = sortedDeduped(identities)
    check ordered[0].version == "v1.2.3"
    check ordered[1].version == "1.2.4"

suite "enumerateCurrentSet":
  test "one identity per version across all packages":
    let idx = Index(schemaVersion: 1, packages: @[
      Package(name: "pkg1", namespace: "ns1", upstream: "https://x", versions: @[
        Version(version: "1.0.0", contentHash: "sha256:aa"),
        Version(version: "2.0.0", contentHash: "sha256:bb"),
      ]),
      Package(name: "pkg2", namespace: "ns2", upstream: "https://y", versions: @[
        Version(version: "1.0.0", contentHash: "sha256:cc"),
      ]),
    ])
    let s = enumerateCurrentSet(idx)
    check s.len == 3
    check mkId("ns1", "pkg1", "1.0.0", "sha256:aa") in s
    check mkId("ns1", "pkg1", "2.0.0", "sha256:bb") in s
    check mkId("ns2", "pkg2", "1.0.0", "sha256:cc") in s

  test "empty index enumerates to the empty set":
    let idx = Index(schemaVersion: 1, packages: @[])
    check enumerateCurrentSet(idx).len == 0

suite "identitiesToJson":
  test "round-trips namespace/name/version/content_hash under the sidecar wire shape":
    let identities = @[mkId("ns", "pkg", "1.0.0", "sha256:aa")]
    let j = identitiesToJson(identities)
    check j.len == 1
    check j[0]["namespace"].getStr == "ns"
    check j[0]["name"].getStr == "pkg"
    check j[0]["version"].getStr == "1.0.0"
    check j[0]["content_hash"].getStr == "sha256:aa"

  test "canonically sorted regardless of input order":
    let identities = @[mkId("b", "b", "1.0.0", "h"), mkId("a", "a", "1.0.0", "h")]
    let j = identitiesToJson(identities)
    check j[0]["namespace"].getStr == "a"
    check j[1]["namespace"].getStr == "b"
