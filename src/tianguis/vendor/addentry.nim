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

## isValidPackageName is defined in kdl_io (the serialization boundary) and
## re-exported here so tests and the CLI layer can access it without a
## separate import. The canonical definition lives in one place only.
export kdl_io.isValidPackageName

proc cmdAddEntry*(projectDir: string, args: AddEntryArgs, driver: AddEntryDriver): int =
  ## Read index.kdl, pull + hash the OCI artifact, merge the author-signed
  ## entry, write back.
  ##
  ## Exit codes:
  ##   0 — entry added (or already present idempotently)
  ##   1 — index.kdl missing or malformed
  ##   3 — OCI pull or hash failed
  ##   4 — namespace could not be derived from signedBy (underivable OIDC SAN),
  ##       OR package name is not in the strict allowlist [A-Za-z0-9_.-]+.
  ##       No mutation performed, alerts.kdl appended with reject entry.
  ##       Replaces/promotes the former P1.4 host/org-form guard.

  # Name validation — hard-reject BEFORE any network I/O.
  # The allowlist keeps package names safe as KDL identifiers and prevents
  # injection even without escaping (defence in depth: escaping is the
  # primary fix; the allowlist is the input gate).
  if not isValidPackageName(args.name):
    stderr.writeLine("tianguis: add-entry: reject: invalid package name '" &
      args.name & "' (must match [A-Za-z0-9_.-]+)")
    return 4

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
      version:     normalizeVersion(args.version),
      contentHash: pulled.hash,
      attestation: "author-signed",
      signedBy:    args.signedBy,
      publishedAt: publishedAt,
      provenances: @[Provenance(
        kind:      pkOci,
        registry:  ociRegistry(args.ociRef),
        repository: ociRepository(args.ociRef),
        digest:    ociDigest(args.ociRef),
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
  0
