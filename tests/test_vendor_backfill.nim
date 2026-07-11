## Tests for S9 backfill candidate enumeration (rfc-attestation-delivery
## .handoff.md S9; tianguis#42):
##   orchestrate.nim — enumerateBackfillCandidates (full-index sweep)
##                    — applyCandidateCap (bounded-batch helper)
##
## Unlike test_vendor_candidates.nim (S7b: candidates captured DURING a
## single vendor pass's own merge attempt), this exercises the full-index
## sweep over entries ALREADY committed to an Index — pinned, pinless-
## vendored, and author-signed, mixed together.

import std/[unittest, options, strutils, sequtils]
import tianguis/model
import tianguis/vendor/[orchestrate, candidates]

proc vendoredVersion(
    version = "0.5.0",
    contentHash = "sha256:abcdef",
    bundlePin = none(string),
    commitSha = "deadbeef1234567",
    gitRef = "v0.5.0",
    publishedAt = "2026-06-15T00:00:00Z",
): Version =
  Version(
    version:     version,
    contentHash: contentHash,
    attestation: "milpa-vendored",
    signedBy:    "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
    publishedAt: publishedAt,
    provenances: @[Provenance(
      kind:      pkGit,
      url:       "https://github.com/coreyleavitt/chronos",
      gitRef:    gitRef,
      commitSha: commitSha,
    )],
    bundlePin: bundlePin,
  )

proc authorSignedVersion(
    version = "1.0.0",
    contentHash = "sha256/author",
    bundlePin = none(string),
): Version =
  Version(
    version:     version,
    contentHash: contentHash,
    attestation: "author-signed",
    signedBy:    "https://github.com/some-author/repo/.github/workflows/publish.yaml@refs/heads/main",
    publishedAt: "2026-06-15T00:00:00Z",
    provenances: @[Provenance(kind: pkOci, registry: "ghcr.io", repository: "some-author/repo", digest: "sha256:zzz")],
    bundlePin: bundlePin,
  )

suite "enumerateBackfillCandidates":
  test "empty index yields no candidates":
    let idx = Index(schemaVersion: 1, packages: @[])
    check enumerateBackfillCandidates(idx).len == 0

  test "a mix of pinned, pinless-vendored, and author-signed entries: only pinless-vendored are emitted":
    let idx = Index(schemaVersion: 1, packages: @[
      Package(
        name: "chronos", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/chronos",
        versions: @[
          vendoredVersion(version = "0.4.0", bundlePin = some("a".repeat(64))),  # already pinned
          vendoredVersion(version = "0.5.0", bundlePin = none(string)),          # ELIGIBLE
          authorSignedVersion(version = "1.0.0", bundlePin = none(string)),      # excluded: author-signed
        ],
      ),
    ])
    let cs = enumerateBackfillCandidates(idx)
    check cs.len == 1
    check cs[0].name == "chronos"
    check cs[0].namespace == "github.com/coreyleavitt"
    check cs[0].version == "0.5.0"
    check cs[0].contentHash == "sha256:abcdef"
    check cs[0].upstream == "https://github.com/coreyleavitt/chronos"
    check cs[0].commitSha == "deadbeef1234567"
    check cs[0].gitRef == "v0.5.0"
    check cs[0].publishedAt == "2026-06-15T00:00:00Z"

  test "an author-signed-only package (no vendored versions at all) yields nothing":
    let idx = Index(schemaVersion: 1, packages: @[
      Package(name: "solo", namespace: "github.com/someauthor",
        upstream: "https://github.com/someauthor/solo",
        versions: @[authorSignedVersion()]),
    ])
    check enumerateBackfillCandidates(idx).len == 0

  test "a fully-pinned package (no pinless versions) yields nothing":
    let idx = Index(schemaVersion: 1, packages: @[
      Package(name: "chronos", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/chronos",
        versions: @[vendoredVersion(bundlePin = some("b".repeat(64)))]),
    ])
    check enumerateBackfillCandidates(idx).len == 0

  test "multiple packages each with an eligible version are all captured":
    let idx = Index(schemaVersion: 1, packages: @[
      Package(name: "a", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/a",
        versions: @[vendoredVersion(version = "1.0.0")]),
      Package(name: "b", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/b",
        versions: @[vendoredVersion(version = "2.0.0", contentHash = "sha256:bbb")]),
    ])
    let cs = enumerateBackfillCandidates(idx)
    check cs.len == 2

  test "a milpa-vendored version with no git provenance is skipped (defensive; unreachable in practice)":
    let v = Version(
      version: "0.1.0", contentHash: "sha256:nogit",
      attestation: "milpa-vendored", signedBy: "bot",
      publishedAt: "2026-06-15T00:00:00Z",
      provenances: @[], bundlePin: none(string),
    )
    let idx = Index(schemaVersion: 1, packages: @[
      Package(name: "x", namespace: "github.com/coreyleavitt", upstream: "u", versions: @[v]),
    ])
    check enumerateBackfillCandidates(idx).len == 0

  test "emitted candidates round-trip through candidatesToJson/parseCandidatesJson":
    let idx = Index(schemaVersion: 1, packages: @[
      Package(name: "chronos", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/chronos",
        versions: @[vendoredVersion()]),
    ])
    let cs = enumerateBackfillCandidates(idx)
    let r = parseCandidatesJson(candidatesToJson(cs))
    check r.isOk
    check r.get == cs

suite "applyCandidateCap":
  proc sample(n: int): seq[BundleCandidate] =
    for i in 0 ..< n:
      result.add(BundleCandidate(namespace: "ns", name: "n" & $i, version: "1.0.0"))

  test "cap <= 0 means no cap: all candidates kept, zero skipped":
    let (kept, skipped) = applyCandidateCap(sample(5), 0)
    check kept.len == 5
    check skipped == 0
    let (kept2, skipped2) = applyCandidateCap(sample(5), -1)
    check kept2.len == 5
    check skipped2 == 0

  test "cap >= len is a no-op":
    let (kept, skipped) = applyCandidateCap(sample(3), 10)
    check kept.len == 3
    check skipped == 0

  test "cap < len truncates and reports the exact skipped count":
    let (kept, skipped) = applyCandidateCap(sample(5), 2)
    check kept.len == 2
    check skipped == 3
    check kept[0].name == "n0"
    check kept[1].name == "n1"

  test "cap == 0 candidates is a no-op on an empty list":
    let (kept, skipped) = applyCandidateCap(@[], 5)
    check kept.len == 0
    check skipped == 0

suite "applyBackfillPins":
  proc backfillIdx(bundlePin = none(string), contentHash = "sha256:abcdef"): Index =
    Index(schemaVersion: 1, packages: @[
      Package(name: "chronos", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/chronos",
        versions: @[vendoredVersion(contentHash = contentHash, bundlePin = bundlePin)]),
    ])

  proc candidateFor(idx: Index): BundleCandidate =
    BundleCandidate(
      namespace: "github.com/coreyleavitt", name: "chronos", version: "0.5.0",
      contentHash: idx.packages[0].versions[0].contentHash,
      upstream: "https://github.com/coreyleavitt/chronos",
      commitSha: "deadbeef1234567", gitRef: "v0.5.0",
      publishedAt: "2026-06-15T00:00:00Z",
    )

  test "pins an existing pinless entry whose content_hash matches (the primary backfill case)":
    let idx = backfillIdx()
    let pin = "1".repeat(64)
    let (newIdx, outcomes) = applyBackfillPins(idx, @[BundlePin(candidate: candidateFor(idx), pin: pin)])
    check outcomes.len == 1
    check outcomes[0].kind == bokPinned
    check newIdx.packages[0].versions[0].bundlePin.isSome
    check newIdx.packages[0].versions[0].bundlePin.get == pin

  test "re-applying the same pin is idempotent (bokAlreadyPinned, index unchanged)":
    let existingPin = "2".repeat(64)
    let idx = backfillIdx(bundlePin = some(existingPin))
    let newPin = "3".repeat(64)
    let (newIdx, outcomes) = applyBackfillPins(idx, @[BundlePin(candidate: candidateFor(idx), pin: newPin)])
    check outcomes.len == 1
    check outcomes[0].kind == bokAlreadyPinned
    check newIdx.packages[0].versions[0].bundlePin.get == existingPin  # NOT overwritten

  test "no matching package: bokNotFound, index unchanged":
    let idx = Index(schemaVersion: 1, packages: @[])
    let cand = BundleCandidate(namespace: "github.com/coreyleavitt", name: "chronos",
      version: "0.5.0", contentHash: "sha256:abcdef")
    let (newIdx, outcomes) = applyBackfillPins(idx, @[BundlePin(candidate: cand, pin: "4".repeat(64))])
    check outcomes.len == 1
    check outcomes[0].kind == bokNotFound
    check newIdx == idx

  test "no matching version on an existing package: bokNotFound":
    let idx = backfillIdx()
    var cand = candidateFor(idx)
    cand.version = "9.9.9"
    let (_, outcomes) = applyBackfillPins(idx, @[BundlePin(candidate: cand, pin: "5".repeat(64))])
    check outcomes[0].kind == bokNotFound

  test "content_hash mismatch: bokContentMismatch, refuses to pin (does not overwrite)":
    let idx = backfillIdx(contentHash = "sha256:actual")
    var cand = candidateFor(idx)
    cand.contentHash = "sha256:stale"
    let (newIdx, outcomes) = applyBackfillPins(idx, @[BundlePin(candidate: cand, pin: "6".repeat(64))])
    check outcomes[0].kind == bokContentMismatch
    check newIdx.packages[0].versions[0].bundlePin.isNone

  test "applying an empty pins list is a no-op":
    let idx = backfillIdx()
    let (newIdx, outcomes) = applyBackfillPins(idx, @[])
    check outcomes.len == 0
    check newIdx == idx

  test "multiple pins across different packages all apply independently":
    let idx = Index(schemaVersion: 1, packages: @[
      Package(name: "a", namespace: "github.com/coreyleavitt", upstream: "u",
        versions: @[vendoredVersion(version = "1.0.0", contentHash = "sha256:a")]),
      Package(name: "b", namespace: "github.com/coreyleavitt", upstream: "u",
        versions: @[vendoredVersion(version = "2.0.0", contentHash = "sha256:b")]),
    ])
    let pins = @[
      BundlePin(candidate: BundleCandidate(namespace: "github.com/coreyleavitt", name: "a", version: "1.0.0", contentHash: "sha256:a"), pin: "7".repeat(64)),
      BundlePin(candidate: BundleCandidate(namespace: "github.com/coreyleavitt", name: "b", version: "2.0.0", contentHash: "sha256:b"), pin: "8".repeat(64)),
    ]
    let (newIdx, outcomes) = applyBackfillPins(idx, pins)
    check outcomes.allIt(it.kind == bokPinned)
    check newIdx.packages[0].versions[0].bundlePin.get == "7".repeat(64)
    check newIdx.packages[1].versions[0].bundlePin.get == "8".repeat(64)
