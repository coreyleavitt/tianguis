## Tests for the S7b candidate/pin persistence + apply flow
## (rfc-attestation-delivery.handoff.md S7b; tianguis#42):
##   candidates.nim   — BundleCandidate/BundlePin JSON (de)serialization
##   merge.nim        — buildVendoredEntryFromCandidate
##   orchestrate.nim  — applyBundlePins (NO Driver, NO network)

import std/[unittest, options, strutils, sequtils]
import tianguis/model
import tianguis/vendor/[merge, orchestrate, candidates]

const fixedPublishedAt = "2026-06-15T00:00:00Z"
const epoch = "2026-06-01T00:00:00Z"

proc sampleCandidate(
    namespace = "github.com/coreyleavitt",
    name = "chronos",
    version = "0.5.0",
    contentHash = "sha256:abcdef",
): BundleCandidate =
  BundleCandidate(
    namespace:   namespace,
    name:        name,
    version:     version,
    contentHash: contentHash,
    upstream:    "https://github.com/coreyleavitt/chronos",
    commitSha:   "deadbeef1234567",
    gitRef:      "v0.5.0",
    publishedAt: fixedPublishedAt,
  )

suite "BundleCandidate JSON round-trip":
  test "candidatesToJson -> parseCandidatesJson round-trips a single candidate":
    let cs = @[sampleCandidate()]
    let r = parseCandidatesJson(candidatesToJson(cs))
    check r.isOk
    check r.get == cs

  test "candidatesToJson -> parseCandidatesJson round-trips multiple candidates":
    let cs = @[
      sampleCandidate(name = "a", version = "1.0.0"),
      sampleCandidate(name = "b", version = "2.0.0", contentHash = "sha256:zzz"),
    ]
    let r = parseCandidatesJson(candidatesToJson(cs))
    check r.isOk
    check r.get == cs

  test "empty candidate list serializes to an empty JSON array":
    let json = candidatesToJson(@[])
    let r = parseCandidatesJson(json)
    check r.isOk
    check r.get.len == 0

  test "parseCandidatesJson rejects malformed JSON":
    let r = parseCandidatesJson("not json")
    check r.isErr

  test "parseCandidatesJson rejects a non-array root":
    let r = parseCandidatesJson("""{"namespace": "x"}""")
    check r.isErr

suite "BundlePin JSON parsing":
  test "parsePinsJson accepts a well-formed pin record":
    let pin = "a".repeat(64)
    let json = """
[
  {
    "namespace": "github.com/coreyleavitt",
    "name": "chronos",
    "version": "0.5.0",
    "content_hash": "sha256:abcdef",
    "upstream": "https://github.com/coreyleavitt/chronos",
    "commit_sha": "deadbeef1234567",
    "git_ref": "v0.5.0",
    "published_at": "2026-06-15T00:00:00Z",
    "bundle_pin": "$1"
  }
]
""" % pin
    let r = parsePinsJson(json)
    check r.isOk
    check r.get.len == 1
    check r.get[0].pin == pin
    check r.get[0].candidate.name == "chronos"
    check r.get[0].candidate.namespace == "github.com/coreyleavitt"

  test "parsePinsJson rejects a record with no bundle_pin":
    let json = """[{"namespace": "n", "name": "p", "version": "1.0.0",
      "content_hash": "sha256:a", "upstream": "u", "commit_sha": "c",
      "git_ref": "g", "published_at": "t"}]"""
    let r = parsePinsJson(json)
    check r.isErr

  test "parsePinsJson rejects a record with a malformed (non-hex64) bundle_pin":
    let json = """[{"namespace": "n", "name": "p", "version": "1.0.0",
      "content_hash": "sha256:a", "upstream": "u", "commit_sha": "c",
      "git_ref": "g", "published_at": "t", "bundle_pin": "not-hex"}]"""
    let r = parsePinsJson(json)
    check r.isErr

  test "parsePinsJson rejects malformed JSON":
    check parsePinsJson("{not json").isErr

  test "parsePinsJson rejects a non-array root":
    check parsePinsJson("""{"bundle_pin": "x"}""").isErr

suite "buildVendoredEntryFromCandidate":
  test "reconstructs the exact shape buildVendoredEntry would produce":
    let c = sampleCandidate()
    let pin = "b".repeat(64)
    let entry = buildVendoredEntryFromCandidate(c, pin)
    check entry.package.name == "chronos"
    check entry.package.namespace == "github.com/coreyleavitt"
    check entry.package.upstream == "https://github.com/coreyleavitt/chronos"
    check entry.version.version == "0.5.0"
    check entry.version.contentHash == "sha256:abcdef"
    check entry.version.attestation == "milpa-vendored"
    check entry.version.publishedAt == fixedPublishedAt
    check entry.version.provenances.len == 1
    check entry.version.provenances[0].kind == pkGit
    check entry.version.provenances[0].gitRef == "v0.5.0"
    check entry.version.provenances[0].commitSha == "deadbeef1234567"
    check entry.version.bundlePin.isSome
    check entry.version.bundlePin.get == pin

  test "empty bundlePin arg builds none (regression guard: no accidental pin)":
    let entry = buildVendoredEntryFromCandidate(sampleCandidate(), "")
    check entry.version.bundlePin.isNone

suite "applyBundlePins":
  test "applying a valid pin to an empty index merges the entry with bundle pin set":
    let pin = "c".repeat(64)
    let pins = @[BundlePin(candidate: sampleCandidate(), pin: pin)]
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let (newIdx, outcomes) = applyBundlePins(idx, pins)
    check outcomes.len == 1
    check outcomes[0].kind == mokAdded
    check newIdx.packages.len == 1
    check newIdx.packages[0].versions.len == 1
    check newIdx.packages[0].versions[0].bundlePin.isSome
    check newIdx.packages[0].versions[0].bundlePin.get == pin

  test "applying pins to multiple candidates merges all of them":
    let pinA = "1".repeat(64)
    let pinB = "2".repeat(64)
    let pins = @[
      BundlePin(candidate: sampleCandidate(name = "a", version = "1.0.0"), pin: pinA),
      BundlePin(candidate: sampleCandidate(name = "b", version = "1.0.0", contentHash = "sha256:bbb"), pin: pinB),
    ]
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let (newIdx, outcomes) = applyBundlePins(idx, pins)
    check outcomes.len == 2
    check outcomes.allIt(it.kind == mokAdded)
    check newIdx.packages.len == 2

  test "regression guard: a candidate reconstructed with NO pin still fails the S5 gate":
    ## Proves the candidate→entry reconstruction path cannot be used to sneak
    ## an unpinned entry past the epoch gate — mergeVendored must still
    ## reject it exactly as it would any other unpinned post-epoch entry.
    let entry = buildVendoredEntryFromCandidate(sampleCandidate(), "")
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let (returned, outcome) = mergeVendored(idx, entry)
    check outcome.kind == mokMissingAttestation
    check returned == idx
    check returned.packages.len == 0

  test "applying an empty pins list is a no-op":
    let idx = Index(schemaVersion: 1, attestationEpoch: some(epoch), packages: @[])
    let (newIdx, outcomes) = applyBundlePins(idx, @[])
    check outcomes.len == 0
    check newIdx == idx
