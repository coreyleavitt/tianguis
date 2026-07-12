## CLI tests for `tianguis set-attestation-epoch --epoch=<ISO8601>` — the
## one-shot admin command that arms the S5 strict-attestation gate
## registry-wide (rfc-attestation-delivery.handoff.md S5 deliverable 5;
## tianguis#42). SET-ONCE + safety-guarded: this is a ratchet, so both the
## "already armed" and "would break the current index" refusals get their
## own coverage, mirroring test_cmd_backfill.nim's withTempProject pattern.
## Fixture indices are built via `formatKdl` over typed model objects
## (test_cmd_migrate.nim's precedent), never hand-transcribed KDL.

import std/[unittest, os, options, tempfiles, strutils]
import tianguis/[model, kdl_io]
import tianguis/cmd_set_attestation_epoch

template withTempProject(name: untyped, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-set-epoch-", "")
  try:
    body
  finally:
    removeDir(name)

proc gitProv(url, gitRef, commitSha: string): Provenance =
  Provenance(kind: pkGit, url: url, gitRef: gitRef, commitSha: commitSha)

proc vendoredVersion(version, contentHash, publishedAt, commitSha: string,
    bundlePin = none(string)): Version =
  Version(
    version: version, contentHash: contentHash,
    attestation: "milpa-vendored",
    signedBy: "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
    publishedAt: publishedAt,
    provenances: @[gitProv("https://github.com/coreyleavitt/chronos", "v" & version, commitSha)],
    bundlePin: bundlePin,
  )

proc singleEntryIndex(publishedAt: string, bundlePin = none(string), epoch = none(string)): Index =
  Index(schemaVersion: 1, attestationEpoch: epoch, packages: @[
    Package(name: "chronos", namespace: "github.com/coreyleavitt",
      upstream: "https://github.com/coreyleavitt/chronos", versions: @[
        vendoredVersion("0.5.0", "sha256:pinless", publishedAt,
          "bbbb000000000000000000000000000000000000", bundlePin = bundlePin),
      ]),
  ])

suite "cli set-attestation-epoch":
  # ---------------------------------------------------------------------------
  # Epoch format validation — hard-reject before any file I/O consequence.
  # ---------------------------------------------------------------------------

  test "date-only shape (no time component) is rejected: index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl",
        formatKdl(singleEntryIndex("2026-01-01T00:00:00Z", bundlePin = some("a".repeat(64)))))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "2026-07-12")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  test "non-date garbage is rejected: index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl",
        formatKdl(singleEntryIndex("2026-01-01T00:00:00Z", bundlePin = some("a".repeat(64)))))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "not-a-date")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  test "trailing junk after a well-formed timestamp is rejected: index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl",
        formatKdl(singleEntryIndex("2026-01-01T00:00:00Z", bundlePin = some("a".repeat(64)))))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "2026-07-12T00:00:00Zjunk")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  test "empty --epoch is rejected: index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl",
        formatKdl(singleEntryIndex("2026-01-01T00:00:00Z", bundlePin = some("a".repeat(64)))))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  test "out-of-range calendar values (month 13) rejected despite matching shape":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl",
        formatKdl(singleEntryIndex("2026-01-01T00:00:00Z", bundlePin = some("a".repeat(64)))))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "2026-13-01T00:00:00Z")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  test "a control character embedded in the epoch is rejected (fails the strict charset)":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl",
        formatKdl(singleEntryIndex("2026-01-01T00:00:00Z", bundlePin = some("a".repeat(64)))))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "2026-0\x0001T00:00:00Z")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  # ---------------------------------------------------------------------------
  # Happy path — epoch-less index whose entries are all pre-epoch/attested.
  # ---------------------------------------------------------------------------

  test "sets the epoch on an epoch-less index whose entries are all pre-epoch or attested":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl",
        formatKdl(singleEntryIndex("2026-01-01T00:00:00Z", bundlePin = some("a".repeat(64)))))
      let code = cmdSetAttestationEpoch(tmp, "2026-06-01T00:00:00Z")
      check code == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      check parsed.get.attestationEpoch == some("2026-06-01T00:00:00Z")

  # ---------------------------------------------------------------------------
  # SET-ONCE guard.
  # ---------------------------------------------------------------------------

  test "already-set epoch: refuses, index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(singleEntryIndex(
        "2026-01-01T00:00:00Z",
        bundlePin = some("a".repeat(64)),
        epoch = some("2026-01-15T00:00:00Z"),
      )))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "2026-06-01T00:00:00Z")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  # ---------------------------------------------------------------------------
  # Safety guard — reuses vendor/merge.mergeVendored's S5 predicate.
  # ---------------------------------------------------------------------------

  test "safety guard: a pinless vendored entry published on/after the proposed epoch refuses":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(singleEntryIndex("2026-06-15T00:00:00Z")))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "2026-06-01T00:00:00Z")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  test "safety guard: an entry published EXACTLY at the proposed epoch (>=) refuses":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(singleEntryIndex("2026-06-01T00:00:00Z")))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "2026-06-01T00:00:00Z")
      check code != 0
      check readFile(tmp / "index.kdl") == original

  test "safety guard: the SAME entry but pre-epoch (publishedAt < epoch) is allowed":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(singleEntryIndex("2026-05-01T00:00:00Z")))
      let code = cmdSetAttestationEpoch(tmp, "2026-06-01T00:00:00Z")
      check code == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      check parsed.get.attestationEpoch == some("2026-06-01T00:00:00Z")

  test "safety guard: a pinned entry published on/after the epoch is fine":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl",
        formatKdl(singleEntryIndex("2026-06-15T00:00:00Z", bundlePin = some("c".repeat(64)))))
      let code = cmdSetAttestationEpoch(tmp, "2026-06-01T00:00:00Z")
      check code == 0

  # ---------------------------------------------------------------------------
  # File-level plumbing.
  # ---------------------------------------------------------------------------

  test "missing index.kdl: exit 1":
    withTempProject(tmp):
      let code = cmdSetAttestationEpoch(tmp, "2026-06-01T00:00:00Z")
      check code == 1

  test "malformed index.kdl: exit 1, no changes possible to observe (file untouched)":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "not valid kdl {{{")
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetAttestationEpoch(tmp, "2026-06-01T00:00:00Z")
      check code == 1
      check readFile(tmp / "index.kdl") == original
