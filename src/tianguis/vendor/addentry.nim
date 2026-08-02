## Subcommand: add a single author-signed entry to index.kdl from a
## dispatched payload. Invoked by .github/workflows/commit-entry.yaml
## after the dispatch endpoint verifies a publish event AND the
## workflow itself cosign-verifies the author signature.
##
## Per dispatch_security_architecture, trust authority lives in the
## commit-entry.yaml workflow: it does `cosign verify` before invoking
## this CLI. So by the time we run, the OCI artifact's author signature
## has already been validated against Rekor — we just pull, hash, merge.
##
## P2.1: the namespace is NO LONGER caller-supplied. It is derived from
## the verified OIDC SAN (`signedBy`) via `deriveNamespace`. Hard-reject
## if derivation fails (exit 4 + structured stderr + alerts.kdl append).
## The `--namespace` flag is removed from the CLI entirely.

import std/[os, options, strutils, times]
import ../model
import ../kdl_io
import ../namespace
import ../fileutil
import ../attestation
import ./merge
import ./alerts

type
  AddEntryArgs* = object
    name*:        string
    version*:     string    ## semver-shaped author-supplied version (e.g. v1.2.3)
    ociRef*:      string    ## <registry>/<repo>@sha256:<digest>
    ## NOTE: `namespace` field removed in P2.1 — namespace is derived from
    ## signedBy (the verified OIDC SAN) inside cmdAddEntry.
    upstream*:    string
    signedBy*:    string    ## verified OIDC SAN from cosign (GH Actions SAN)
    publishedAt*: string    ## ISO 8601 UTC; empty → "now" (tianguis observed time)
    ## Durable Rekor pointer, captured at publish from the same
    ## `cosign verify --output json` that extracted signedBy (Gate B). All
    ## optional — an empty trio yields no `rekor` block on the stored version.
    rekorUuid*:           string  ## Rekor entry UUID (content-addressed)
    rekorLogIndex*:       string  ## Rekor logIndex
    rekorIntegratedTime*: string  ## inclusion timestamp (epoch seconds)
    ## Delivery-integrity pin (rfc-attestation-delivery S1/S7a): sha256 hex
    ## of the per-entry attestation bundle's BYTES, minted by the workflow
    ## (S7b — cosign attest-blob over the S3 in-toto statement → S4
    ## content-addressed store → pin). Empty string == no pin (pre-epoch or
    ## not-yet-wired callers); threaded into `Version.bundlePin` as
    ## `none(string)` in that case.
    bundlePin*:           string
    ## Subject-binding proof (rfc-attestation-delivery S8): path to a
    ## CRYPTOGRAPHICALLY-VERIFIED in-toto statement JSON file (author-signed
    ## bundle DSSE payload, extracted + verified by the CI crypto step —
    ## SAN + OIDC issuer + Rekor inclusion — BEFORE add-entry ever runs).
    ## add-entry re-derives `subject[0].digest.sha256` /
    ## `subject[0].name` expectations from its OWN recomputed content_hash +
    ## the verified (namespace,name,version) tuple and rejects on any
    ## mismatch — crypto proves "the author signed THIS statement";
    ## add-entry proves "this statement matches what we actually admit."
    ## Empty string == not supplied. MUST be supplied together with
    ## `bundlePin` (both-or-neither, post-epoch admission is atomic) — see
    ## the exit-4 check in `cmdAddEntry`.
    entryStatementPath*:  string
    ## Source git repo URL this OCI artifact was published from (milpa
    ## `publish --output`'s `source_url` field, threaded via the composite
    ## action + dispatch + commit-entry.yaml's `--source` flag). Empty
    ## string == not supplied; recorded as `Provenance.source` (also empty)
    ## on the oci provenance, matching the empty-string-absent convention.
    sourceUrl*: string

  ## AddEntryDriver — injectable I/O for testability. Real impl pulls
  ## the OCI artifact via oras and computes content_hash via the
  ## existing identity algorithm. No crypto: the workflow does that.
  AddEntryDriver* = ref object of RootObj

method pullAndHash*(d: AddEntryDriver, ociRef: string): tuple[hash, sha: string] {.base.} =
  raise newException(Defect, "abstract AddEntryDriver.pullAndHash called")

# ---------------------------------------------------------------------------
# OCI ref parsing — '<registry>/<repo>@sha256:<digest>'
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

## isValidPackageName and isHex64 are defined in kdl_io (the serialization
## boundary) and re-exported here so tests and the CLI layer can access them
## without a separate import. Each canonical definition lives in one place
## only — the write-side validator IS the parse-side format check.
export kdl_io.isValidPackageName
export kdl_io.isHex64

proc cmdAddEntry*(projectDir: string, args: AddEntryArgs, driver: AddEntryDriver): int =
  ## Read index.kdl, pull + hash the OCI artifact, merge the author-signed
  ## entry, write back.
  ##
  ## Exit codes:
  ##   0 — entry added (or already present idempotently)
  ##   1 — index.kdl missing or malformed
  ##   3 — OCI pull or hash failed
  ##   4 — namespace could not be derived from signedBy (underivable OIDC SAN),
  ##       OR package name is not in the strict allowlist [A-Za-z0-9_.-]+,
  ##       OR --bundle-pin was supplied but is not 64 lowercase hex characters.
  ##       No mutation performed; the namespace-underivable case additionally
  ##       appends alerts.kdl with a reject entry.
  ##       Replaces/promotes the former P1.4 host/org-form guard.
  ##   5 — --entry-statement / --bundle-pin subject-binding admission failure
  ##       (rfc-attestation-delivery S8): either only one of the two flags was
  ##       supplied (both-or-neither), the --entry-statement file is missing
  ##       or not parseable as an in-toto statement, or the statement's
  ##       subject[0].digest.sha256 / subject[0].name does NOT match tianguis's
  ##       own recomputed content_hash / derived purl. No mutation performed.

  # Name validation — hard-reject BEFORE any network I/O.
  # The allowlist keeps package names safe as KDL identifiers and prevents
  # injection even without escaping (defence in depth: escaping is the
  # primary fix; the allowlist is the input gate).
  if not isValidPackageName(args.name):
    stderr.writeLine("tianguis: add-entry: reject: invalid package name '" &
      args.name & "' (must match [A-Za-z0-9_.-]+)")
    return 4

  # Bundle-pin validation (rfc-attestation-delivery S7a) — hard-reject BEFORE
  # any network I/O, same discipline as the name check above. Empty is valid
  # (means "no pin yet"); non-empty MUST be exactly 64 lowercase hex chars —
  # the same `isHex64` the KDL serializer enforces on write (single source
  # of truth; see kdl_io.isHex64), so a malformed pin can never reach
  # `formatKdl` in the first place.
  if args.bundlePin.len > 0 and not isHex64(args.bundlePin):
    stderr.writeLine("tianguis: add-entry: reject: invalid bundle pin '" &
      args.bundlePin & "' (must be 64 lowercase hex characters)")
    return 4

  # Entry-statement / bundle-pin both-or-neither (rfc-attestation-delivery
  # S8) — hard-reject BEFORE any network I/O, same discipline as the checks
  # above. A minted bundle pin with no verified statement to back it (or a
  # verified statement with no pin recorded) is a half-wired admission: the
  # pin is what milpa parses off the entry, the statement is what proves
  # the pin is trustworthy. Post-epoch admission is atomic — both or
  # neither. Pre-epoch/legacy callers that supply neither are unaffected.
  if (args.bundlePin.len > 0) != (args.entryStatementPath.len > 0):
    stderr.writeLine("tianguis: add-entry: reject: --bundle-pin and " &
      "--entry-statement must both be supplied together, or neither " &
      "(bundle-pin=" & (if args.bundlePin.len > 0: "set" else: "unset") &
      " entry-statement=" & (if args.entryStatementPath.len > 0: "set" else: "unset") & ")")
    return 5

  # Read + parse the (untrusted, pre-crypto-check-only-locally-visible)
  # statement file up front. The CI crypto step already verified this
  # statement's DSSE envelope (SAN + OIDC issuer + Rekor inclusion) before
  # add-entry ever runs — add-entry's job is ONLY to bind the statement's
  # claimed subject to what it is actually about to admit (below, after
  # the OCI pull + recomputed content_hash are available).
  var parsedSubject: StatementSubject
  if args.entryStatementPath.len > 0:
    if not fileExists(args.entryStatementPath):
      stderr.writeLine("tianguis: add-entry: reject: --entry-statement file not found: " &
        args.entryStatementPath)
      return 5
    let subjResult = extractStatementSubject(readFile(args.entryStatementPath))
    if subjResult.isErr:
      stderr.writeLine("tianguis: add-entry: reject: --entry-statement: " & subjResult.getErr)
      return 5
    parsedSubject = subjResult.get

  # P2.1 — derive namespace from the verified OIDC SAN.
  # Hard-reject BEFORE any network I/O if derivation fails.
  let nowStr = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let derived = deriveNamespace(args.signedBy)
  if derived.isErr:
    let reason = derived.getErr
    stderr.writeLine("tianguis: add-entry: reject: namespace-underivable" &
      " signed_by=" & args.signedBy &
      " reason=" & $reason)
    # Append to alerts.kdl in projectDir (create if absent; append-only).
    let alertsPath = projectDir / "alerts.kdl"
    let existing = if fileExists(alertsPath): readFile(alertsPath) else: ""
    writeFile(alertsPath, appendAlert(existing, args.signedBy, reason, nowStr))
    return 4

  let namespace = namespaceString(derived.get)

  let indexPath = projectDir / "index.kdl"
  if not fileExists(indexPath):
    stderr.writeLine("tianguis: " & indexPath & " not found")
    return 1
  let parsed = parseKdl(readFile(indexPath))
  if parsed.isErr:
    let e = parsed.getErr
    stderr.writeLine("tianguis: " & indexPath & ": " & $e.code & ": " & e.message)
    return 1

  var pulled: tuple[hash, sha: string]
  try:
    pulled = driver.pullAndHash(args.ociRef)
  except CatchableError as e:
    stderr.writeLine("tianguis: pull+hash failed: " & e.msg)
    return 3

  let normalizedVersion = normalizeVersion(args.version)

  # THE SECURITY INVARIANT (rfc-attestation-delivery S8): never trust the
  # author's claimed subject. tianguis just recomputed content_hash itself
  # (above); bind the CI-crypto-verified statement's claimed subject to
  # THAT value + the purl tianguis itself derives from the verified
  # (namespace, name, version) — not to anything the author asserted.
  # A malicious author who signs a statement bound to a DIFFERENT
  # content_hash than what they actually published (or to a different
  # package's purl, replaying a bundle cross-package) is rejected here.
  if args.entryStatementPath.len > 0:
    let expectedDigest = extractContentHashHex(pulled.hash)
    let expectedName = buildEntrySubjectName(namespace, args.name, normalizedVersion)
    if parsedSubject.digestSha256 != expectedDigest:
      stderr.writeLine("tianguis: add-entry: reject: entry-statement digest mismatch " &
        "(statement=" & parsedSubject.digestSha256 & " recomputed=" & expectedDigest & ")")
      return 5
    if parsedSubject.name != expectedName:
      stderr.writeLine("tianguis: add-entry: reject: entry-statement subject-name mismatch " &
        "(statement=" & parsedSubject.name & " expected=" & expectedName & ")")
      return 5

  let publishedAt =
    if args.publishedAt.len > 0: args.publishedAt
    else: nowStr

  let entry = VendoredEntry(
    package: Package(
      name: args.name,
      namespace: namespace,
      upstream: args.upstream,
    ),
    version: Version(
      version:     normalizedVersion,
      contentHash: pulled.hash,
      attestation: "author-signed",
      signedBy:    args.signedBy,
      publishedAt: publishedAt,
      provenances: @[Provenance(
        kind:      pkOci,
        registry:  ociRegistry(args.ociRef),
        repository: ociRepository(args.ociRef),
        digest:    ociDigest(args.ociRef),
        source:    args.sourceUrl,
      )],
      # Author-signed durable Rekor pointer. Recorded only when the workflow
      # captured at least one field; an all-empty trio leaves rekor = none so
      # we never emit a hollow block.
      rekor:
        if args.rekorUuid.len > 0 or args.rekorLogIndex.len > 0 or
            args.rekorIntegratedTime.len > 0:
          some(RekorRef(
            uuid:           args.rekorUuid,
            logIndex:       args.rekorLogIndex,
            integratedTime: args.rekorIntegratedTime,
          ))
        else:
          none(RekorRef),
      # Delivery-integrity pin (S7a): some(pin) iff the caller supplied one;
      # already validated as 64-lowercase-hex above. `none` otherwise — the
      # unchanged, pre-slice default.
      bundlePin:
        if args.bundlePin.len > 0: some(args.bundlePin)
        else: none(string),
    ),
  )

  let (newIdx, outcome) = mergeVendored(parsed.get, entry)
  # Reject kinds (mokIdentityDrift, mokCollision, mokContentDrift) leave the
  # index unchanged — same immutability policy as vendor merges.
  # Full alerting for these cases is a future cycle; log to stderr for now.
  case outcome.kind
  of mokAdded, mokIdempotent:
    atomicWrite(indexPath, formatKdl(newIdx))
  of mokIdentityDrift:
    stderr.writeLine("tianguis: add-entry: IDX-IDENTITY-DRIFT: " &
      outcome.identity.name &
      " stored=" & outcome.identity.storedNamespace &
      " rederived=" & outcome.identity.rederivedNamespace)
    return 1
  of mokCollision:
    stderr.writeLine("tianguis: add-entry: IDX-INTRAORG-COLLISION: " &
      outcome.collision.namespace & "/" & outcome.collision.name)
    return 1
  of mokContentDrift:
    stderr.writeLine("tianguis: add-entry: IDX-CONTENT-DRIFT: " &
      outcome.content.packageName & " " & outcome.content.version)
    return 1
  of mokSignerMismatch:
    # Signer-continuity ratchet (rfc-attestation-delivery S8 Layer 3,
    # tianguis#42): a different signer attempted to author-sign a version
    # under a package whose authorizedSigner is already pinned. The
    # anti-takeover guard this add-entry path exists to enforce.
    stderr.writeLine("tianguis: add-entry: IDX-SIGNER-MISMATCH: " &
      outcome.signerMismatch.namespace & "/" & outcome.signerMismatch.packageName &
      "@" & outcome.signerMismatch.version &
      " pinned=" & outcome.signerMismatch.pinnedSigner &
      " incoming=" & outcome.signerMismatch.incomingSigner)
    return 1
  of mokMissingAttestation:
    stderr.writeLine("tianguis: add-entry: IDX-MISSING-ATTESTATION: " &
      outcome.missingAttestation.namespace & "/" & outcome.missingAttestation.packageName &
      "@" & outcome.missingAttestation.version &
      " published_at=" & outcome.missingAttestation.publishedAt &
      " epoch=" & outcome.missingAttestation.epoch)
    return 1
  of mokRebaselined:
    # mergeVendored never returns mokRebaselined (only mergeRebaseline does);
    # this branch is unreachable here but required for exhaustive coverage.
    raise newException(Defect, "add-entry: unexpected mokRebaselined from mergeVendored")
  0
