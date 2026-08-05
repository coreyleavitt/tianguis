## CLI tests for `tianguis set-epoch-commitment [--execute]` — the D-Watermark
## pre-epoch set commitment arming command (milpa
## `docs/rfc-attestation-v1-normative.md` §6 S-EpochCommitment).
##
## Mirrors `test_cmd_set_attestation_epoch.nim`'s `withTempProject` pattern
## and `test_cmd_migrate.nim`'s dry-run/--execute coverage shape: the
## default (dry-run) mode must never mutate index.kdl; --execute must be
## append-once (refuses a second arming); the armed value must equal
## `preepoch_commitment.commitmentDigest` of exactly the enumerated set.

import std/[unittest, os, options, tempfiles, strutils]
import tianguis/[model, kdl_io, preepoch_commitment]
import tianguis/cmd_set_epoch_commitment

template withTempProject(name: untyped, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-set-epoch-commitment-", "")
  try:
    body
  finally:
    removeDir(name)

proc singleEntryIndex(commitment = none(string)): Index =
  Index(schemaVersion: 1, attestationEpochCommitment: commitment, packages: @[
    Package(name: "chronos", namespace: "github.com/coreyleavitt",
      upstream: "https://github.com/coreyleavitt/chronos", versions: @[
        Version(
          version: "0.5.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-01-01T00:00:00Z",
        ),
      ]),
  ])

suite "cli set-epoch-commitment":
  # ---------------------------------------------------------------------------
  # Dry-run (default) — never mutates, prints S + C.
  # ---------------------------------------------------------------------------

  test "dry-run (no --execute) writes nothing":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(singleEntryIndex()))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetEpochCommitment(tmp, execute = false)
      check code == 0
      check readFile(tmp / "index.kdl") == original

  test "dry-run on an already-armed index still writes nothing (read-only)":
    withTempProject(tmp):
      let c = "a".repeat(64)
      writeFile(tmp / "index.kdl", formatKdl(singleEntryIndex(commitment = some(c))))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetEpochCommitment(tmp, execute = false)
      check code == 0
      check readFile(tmp / "index.kdl") == original

  # ---------------------------------------------------------------------------
  # renderPreepochDryRun — pure renderer
  # ---------------------------------------------------------------------------

  test "renderPreepochDryRun lists every identity and the commitment, and never writes":
    let identities = @[
      PreEpochIdentity(namespace: "ns", name: "pkg", version: "1.0.0", contentHash: "sha256:aa"),
    ]
    let c = commitmentDigest(identities)
    let text = renderPreepochDryRun(identities, c)
    check "ns/pkg@1.0.0" in text
    check c in text
    check "DRY RUN" in text

  test "renderPreepochDryRun on an empty set reports zero identities":
    let text = renderPreepochDryRun(@[], commitmentDigest(@[]))
    check "0 identities" in text

  # ---------------------------------------------------------------------------
  # --execute — arms the field, matches preepoch_commitment.commitmentDigest.
  # ---------------------------------------------------------------------------

  test "--execute arms attestation-epoch-commitment to commitmentDigest(enumerateCurrentSet(idx))":
    withTempProject(tmp):
      let original = singleEntryIndex()
      writeFile(tmp / "index.kdl", formatKdl(original))
      let expectedC = commitmentDigest(enumerateCurrentSet(original))
      let code = cmdSetEpochCommitment(tmp, execute = true)
      check code == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      check parsed.get.attestationEpochCommitment == some(expectedC)

  test "--execute on an empty index arms the empty-set commitment":
    withTempProject(tmp):
      let empty = Index(schemaVersion: 1, packages: @[])
      writeFile(tmp / "index.kdl", formatKdl(empty))
      let code = cmdSetEpochCommitment(tmp, execute = true)
      check code == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      check parsed.get.attestationEpochCommitment == some(commitmentDigest(@[]))

  test "--execute does not disturb an existing attestation-epoch timestamp":
    withTempProject(tmp):
      var idx = singleEntryIndex()
      idx.attestationEpoch = some("2026-06-01T00:00:00Z")
      writeFile(tmp / "index.kdl", formatKdl(idx))
      let code = cmdSetEpochCommitment(tmp, execute = true)
      check code == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      check parsed.get.attestationEpoch == some("2026-06-01T00:00:00Z")
      check parsed.get.attestationEpochCommitment.isSome

  # ---------------------------------------------------------------------------
  # Append-once guard — refuses a second arming, writes nothing.
  # ---------------------------------------------------------------------------

  test "--execute on an already-armed index refuses (append-once), index unchanged":
    withTempProject(tmp):
      let c = "b".repeat(64)
      writeFile(tmp / "index.kdl", formatKdl(singleEntryIndex(commitment = some(c))))
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetEpochCommitment(tmp, execute = true)
      check code == 3
      check readFile(tmp / "index.kdl") == original

  # ---------------------------------------------------------------------------
  # File-level plumbing.
  # ---------------------------------------------------------------------------

  test "missing index.kdl: exit 1 (dry-run)":
    withTempProject(tmp):
      let code = cmdSetEpochCommitment(tmp, execute = false)
      check code == 1

  test "missing index.kdl: exit 1 (--execute)":
    withTempProject(tmp):
      let code = cmdSetEpochCommitment(tmp, execute = true)
      check code == 1

  test "malformed index.kdl: exit 1, no changes possible to observe (file untouched)":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "not valid kdl {{{")
      let original = readFile(tmp / "index.kdl")
      let code = cmdSetEpochCommitment(tmp, execute = true)
      check code == 1
      check readFile(tmp / "index.kdl") == original
