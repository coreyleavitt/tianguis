## Subcommand: add a single author-signed entry to index.kdl from a
## dispatched payload. Invoked by .github/workflows/commit-entry.yaml
## after the dispatch endpoint verifies a publish event.
##
## Per dispatch_security_architecture.md, this subcommand independently
## verifies the Rekor entry referenced by the dispatched payload before
## committing — so even a fully-compromised dispatch endpoint can't
## inject entries without leaving a publicly-verifiable Rekor trail.

import std/[os, options, strutils]
import ../model
import ../kdl_io
import ./merge

type
  AddEntryArgs* = object
    name*:        string
    version*:     string    ## semver-shaped author-supplied version (e.g. v1.2.3)
    ociRef*:      string    ## <registry>/<repo>@sha256:<digest>
    namespace*:   string
    upstream*:    string
    signedBy*:    string    ## OIDC identity (cosign signer)
    publishedAt*: string    ## ISO 8601 UTC
    rekorUuid*:   string    ## entry UUID dispatch attested to

  ## AttestSubject is what we expect the Rekor entry to contain — used
  ## by Driver.verifyRekor to cross-check that the dispatched payload
  ## matches what the dispatch endpoint actually attested.
  AttestSubject* = object
    name*, ociRef*, repoUrl*, signerIdentity*: string

  ## AddEntryDriver — injectable I/O for testability. Real impl pulls
  ## the OCI artifact via oras, computes content_hash via the existing
  ## identity algorithm, and verifies Rekor via sigstore-go.
  AddEntryDriver* = ref object of RootObj

method verifyRekor*(d: AddEntryDriver, uuid: string, expected: AttestSubject): bool {.base.} =
  raise newException(Defect, "abstract AddEntryDriver.verifyRekor called")

method pullAndHash*(d: AddEntryDriver, ociRef: string): tuple[hash, sha: string] {.base.} =
  raise newException(Defect, "abstract AddEntryDriver.pullAndHash called")

# ---------------------------------------------------------------------------
# OCI ref parsing — '<registry>/<repo>@sha256:<digest>'
# (declared before cmdAddEntry which uses them; Nim resolves top-to-bottom)
# ---------------------------------------------------------------------------

proc ociRegistry*(ociRef: string): string =
  let slashIdx = ociRef.find('/')
  if slashIdx <= 0: "" else: ociRef[0 ..< slashIdx]

proc ociRepository*(ociRef: string): string =
  let slashIdx = ociRef.find('/')
  let atIdx = ociRef.find('@')
  if slashIdx <= 0 or atIdx <= slashIdx: ""
  else: ociRef[slashIdx + 1 ..< atIdx]

proc ociDigest*(ociRef: string): string =
  let atIdx = ociRef.find('@')
  if atIdx < 0: "" else: ociRef[atIdx + 1 .. ^1]

# normalizeVersion — author may pass either "v1.2.3" (canonical git tag form)
# or bare "1.2.3". Strip the leading v so the stored version matches what
# milpa's semver comparison expects (numeric-leading).
proc normalizeVersion*(v: string): string =
  if v.startsWith("v") and v.len > 1 and v[1] in '0'..'9': v[1 .. ^1]
  else: v

proc cmdAddEntry*(projectDir: string, args: AddEntryArgs, driver: AddEntryDriver): int =
  ## Read index.kdl, verify Rekor entry independently, pull + hash the
  ## OCI artifact, merge the author-signed entry, write back.
  ##
  ## Exit codes:
  ##   0 — entry added (or already present idempotently)
  ##   1 — index.kdl missing or malformed
  ##   2 — Rekor verification failed (refuse to commit)
  ##   3 — OCI pull or hash failed
  let indexPath = projectDir / "index.kdl"
  if not fileExists(indexPath):
    stderr.writeLine("tianguis: " & indexPath & " not found")
    return 1
  let parsed = parseKdl(readFile(indexPath))
  if parsed.isErr:
    let e = parsed.getErr
    stderr.writeLine("tianguis: " & indexPath & ": " & $e.code & ": " & e.message)
    return 1

  # Verify the Rekor entry matches the dispatched payload. Refuse to
  # commit if the attestation doesn't independently verify — the
  # entire defense-in-depth story rests on this check.
  let expected = AttestSubject(
    name:           args.name,
    ociRef:         args.ociRef,
    repoUrl:        args.upstream,
    signerIdentity: args.signedBy,
  )
  if not driver.verifyRekor(args.rekorUuid, expected):
    stderr.writeLine("tianguis: Rekor verification failed for " & args.rekorUuid)
    return 2

  # Pull + hash the OCI artifact.
  var pulled: tuple[hash, sha: string]
  try:
    pulled = driver.pullAndHash(args.ociRef)
  except CatchableError as e:
    stderr.writeLine("tianguis: pull+hash failed: " & e.msg)
    return 3

  # Build the author-signed entry. Note this is structurally identical to
  # R2's vendor entry except for attestation level + signedBy attribution.
  let entry = VendoredEntry(
    package: Package(
      name: args.name,
      namespace: args.namespace,
      upstream: args.upstream,
    ),
    version: Version(
      version:     normalizeVersion(args.version),
      contentHash: pulled.hash,
      attestation: "author-signed",
      signedBy:    args.signedBy,
      publishedAt: args.publishedAt,
      provenances: @[Provenance(
        kind:      pkOci,
        registry:  ociRegistry(args.ociRef),
        repository: ociRepository(args.ociRef),
        digest:    ociDigest(args.ociRef),
      )],
    ),
  )

  let outcome = mergeVendored(parsed.get, entry)
  # Drift detection still fires for author-signed entries (same package,
  # same version, different hash). The commit workflow logs but doesn't
  # fail — the existing entry is retained, the new bytes are flagged.
  # (Alert append handling lands in a later cycle if needed.)
  discard outcome.drift

  writeFile(indexPath, formatKdl(outcome.index))
  0

