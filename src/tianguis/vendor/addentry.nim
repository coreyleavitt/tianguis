## Subcommand: add a single author-signed entry to index.kdl from a
## dispatched payload. Invoked by .github/workflows/commit-entry.yaml
## after the dispatch endpoint verifies a publish event AND the
## workflow itself cosign-verifies the author signature.
##
## Per dispatch_security_architecture, trust authority lives in the
## commit-entry.yaml workflow: it does `cosign verify` before invoking
## this CLI. So by the time we run, the OCI artifact's author signature
## has already been validated against Rekor — we just pull, hash, merge.

import std/[os, options, strutils, times]
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
    signedBy*:    string    ## OIDC identity that cosign-signed the artifact
    publishedAt*: string    ## ISO 8601 UTC; empty → "now" (tianguis observed time)

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

proc cmdAddEntry*(projectDir: string, args: AddEntryArgs, driver: AddEntryDriver): int =
  ## Read index.kdl, pull + hash the OCI artifact, merge the author-signed
  ## entry, write back.
  ##
  ## Exit codes:
  ##   0 — entry added (or already present idempotently)
  ##   1 — index.kdl missing or malformed
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

  var pulled: tuple[hash, sha: string]
  try:
    pulled = driver.pullAndHash(args.ociRef)
  except CatchableError as e:
    stderr.writeLine("tianguis: pull+hash failed: " & e.msg)
    return 3

  let publishedAt =
    if args.publishedAt.len > 0: args.publishedAt
    else: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

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
      publishedAt: publishedAt,
      provenances: @[Provenance(
        kind:      pkOci,
        registry:  ociRegistry(args.ociRef),
        repository: ociRepository(args.ociRef),
        digest:    ociDigest(args.ociRef),
      )],
    ),
  )

  let outcome = mergeVendored(parsed.get, entry)
  # Drift (same package+version, different hash) is retained-not-overwritten
  # — same policy as vendor merges. Alerting is a future cycle.
  discard outcome.drift

  writeFile(indexPath, formatKdl(outcome.index))
  0
