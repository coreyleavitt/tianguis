## Pure orchestration of the vendor-en-absentia run.
##
## Driver-injected I/O means the entire decision graph (which packages
## to vendor, which tags to pick, when to flag drift, when to skip
## denylisted entries) is testable with fake drivers and deterministic
## inputs. The real driver (`driver.nim`) wraps subprocess calls to
## git + a HTTP client; this module never touches the network or disk
## directly.

import ./upstream
import ./tagselect
import ./merge
import ./denylist
import ./alerts
import ./candidates
import ../model
import ../namespace
import ../kdl_io

type
  CloneResult* = object
    contentHash*: string
    commitSha*:   string

  Driver* = ref object of RootObj

  VendorRunResult* = object
    index*:      Index
    alerts*:     string         ## full alerts.kdl log (existing + new)
    skipped*:    seq[string]    ## denylisted or undrivable packages we skipped
    candidates*: seq[BundleCandidate]
        ## rfc-attestation-delivery S7b: post-epoch entries this pass could
        ## NOT merge purely because they lack a bundle pin (and are not
        ## already pinned elsewhere in the index — see
        ## `alreadyPinnedInIndex`). Written to `--emit-bundle-candidates`;
        ## empty when no epoch is set or nothing needs minting.

# ---------------------------------------------------------------------------
# Driver protocol — concrete drivers override these.
# ---------------------------------------------------------------------------

method fetchPackagesJson*(d: Driver): seq[UpstreamPackage] {.base.} =
  raise newException(Defect, "abstract Driver.fetchPackagesJson called")

method listTags*(d: Driver, url: string): seq[string] {.base.} =
  raise newException(Defect, "abstract Driver.listTags called")

method headSha*(d: Driver, url: string): string {.base.} =
  raise newException(Defect, "abstract Driver.headSha called")

method shallowCloneAndHash*(d: Driver, url, refName: string): CloneResult {.base.} =
  raise newException(Defect, "abstract Driver.shallowCloneAndHash called")

# ---------------------------------------------------------------------------
# Pure orchestrator
# ---------------------------------------------------------------------------

proc alreadyPinnedInIndex(idx: Index, namespace, name, version, contentHash: string): bool =
  ## True when `idx` already carries a version at (namespace, name, version)
  ## with THIS exact content_hash AND a bundle pin already set.
  ##
  ## Needed because `mergeVendored`'s epoch gate (S5) checks the pin BEFORE
  ## the idempotent/content-drift checks — and `buildVendoredEntry` never
  ## carries a previously-stored pin forward (a live re-vendor pass has no
  ## reason to know about it; only the index does). Without this guard, a
  ## package that was already vendored+pinned on a prior run would get
  ## rebuilt with `bundlePin = none` on today's run, immediately fail the
  ## gate as `mokMissingAttestation`, and get needlessly re-emitted as a
  ## bundle candidate every single day — a wasted (and non-idempotent,
  ## since Sigstore signing embeds a fresh Rekor timestamp) re-mint. This
  ## check keeps candidate-emission scoped to entries that genuinely still
  ## need a pin.
  for p in idx.packages:
    if p.namespace != namespace or p.name != name: continue
    for v in p.versions:
      if v.version == version and v.contentHash == contentHash and v.bundlePin.isSome:
        return true
  false

proc runVendor*(
    driver:        Driver,
    initialIndex:  Index,
    denylist:      Denylist,
    initialAlerts: string,
    nowIso:        string,
    rebaseline:    bool = false,
): VendorRunResult =
  ## Walk every upstream package; for each one not denylisted, fetch
  ## tags + HEAD, select the right tag, shallow-clone-and-hash, merge
  ## the resulting entry into the index. Drift and collision alerts append
  ## to the alerts log.
  ##
  ## When `rebaseline` is true (epoch-migration mode), uses mergeRebaseline
  ## instead of mergeVendored: existing content_hashes for known (namespace,
  ## name, version) triples are REPLACED by the incoming epoch-2 dag-sha256
  ## value rather than triggering a drift alert. Identity and collision
  ## protections remain enforced regardless of this flag.
  var idx = initialIndex
  var alerts = initialAlerts
  var skipped: seq[string] = @[]
  var pending: seq[BundleCandidate] = @[]

  for pkg in driver.fetchPackagesJson():
    if pkg.`method` != "git":
      # Non-git transports get their own vendoring path when their
      # fetcher lands; skip silently for now.
      continue

    # Derive namespace up front from the git provenance URL.
    # If underivable → log + skip + continue (auditable, not silent).
    let nsResult = deriveNamespace(pkg.url)
    if nsResult.isErr:
      stderr.writeLine("tianguis: vendor: " & pkg.name &
        " skipped (undeivable namespace, " & $nsResult.error & "): " & pkg.url)
      skipped.add(pkg.name)
      continue
    let ns = namespaceString(nsResult.get)

    # Denylist check is tuple-keyed: (namespace, name).
    if denylist.contains(ns, pkg.name):
      skipped.add(pkg.name)
      continue

    # Name safety guard — same rule as the add-entry path (SSOT: kdl_io).
    # A name containing `..` or a leading `.` would make index.kdl
    # unparseable by milpa (registry-wide DoS). Log + skip, never write.
    if not isValidPackageName(pkg.name):
      stderr.writeLine("tianguis: vendor: " & pkg.name &
        " skipped (invalid package name — path-traversal or leading-dot): " &
        pkg.url)
      skipped.add(pkg.name)
      continue

    # Per-package isolation: a single bad upstream (deleted repo, network
    # blip, weird git state) must not abort the entire vendor pass. We
    # log + skip + continue, leaving the rest of the catalog to vendor.
    try:
      let tags = driver.listTags(pkg.url)
      let head = driver.headSha(pkg.url)
      let sel = selectTag(tags, head)
      let refName = if sel.tag.len > 0: sel.tag else: "HEAD"
      let clone = driver.shallowCloneAndHash(pkg.url, refName)

      let entryResult = buildVendoredEntry(
        pkg, sel,
        contentHash    = clone.contentHash,
        commitSha      = clone.commitSha,
        publishedAt    = nowIso,
        precomputedNs  = ns,  # ns already derived above (SSOT: derive once)
      )
      # buildVendoredEntry already checked derivability; if it errors
      # here it's a logic bug, but be robust.
      if entryResult.isErr:
        stderr.writeLine("tianguis: vendor: " & pkg.name &
          " skipped (buildVendoredEntry err, " & $entryResult.error & "): " & pkg.url)
        skipped.add(pkg.name)
        continue

      let entry = entryResult.get
      let (newIdx, outcome) =
        if rebaseline: mergeRebaseline(idx, entry)
        else: mergeVendored(idx, entry)
      case outcome.kind
      of mokAdded:
        # Only commit the mutated index on an actual add.
        idx = newIdx
      of mokIdempotent:
        # Safe no-op write avoided — index already contains identical entry.
        discard
      of mokRebaselined:
        # Epoch-migration: commit updated index and emit auditable log line.
        idx = newIdx
        let rb = outcome.rebaseline
        stderr.writeLine("reindex: REBASELINE " &
          rb.namespace & "/" & rb.packageName & "@" & rb.version & " " &
          rb.existingHash & "→" & rb.newHash)
      of mokIdentityDrift:
        alerts = appendAlert(alerts, outcome.identity, detectedAt = nowIso)
        stderr.writeLine("tianguis: vendor: IDX-IDENTITY-DRIFT: " &
          outcome.identity.name &
          " stored=" & outcome.identity.storedNamespace &
          " rederived=" & outcome.identity.rederivedNamespace)
      of mokCollision:
        let col = outcome.collision
        alerts = appendAlert(alerts, col, detectedAt = nowIso)
        stderr.writeLine("tianguis: vendor: IDX-INTRAORG-COLLISION: " &
          col.namespace & "/" & col.name &
          " existing=" & col.existingRepo & " incoming=" & col.newRepo)
      of mokContentDrift:
        alerts = appendAlert(alerts, outcome.content, detectedAt = nowIso)
      of mokMissingAttestation:
        let ma = outcome.missingAttestation
        alerts = appendAlert(alerts, ma, detectedAt = nowIso)
        stderr.writeLine("tianguis: vendor: IDX-MISSING-ATTESTATION: " &
          ma.namespace & "/" & ma.packageName & "@" & ma.version &
          " published_at=" & ma.publishedAt & " epoch=" & ma.epoch)
        # S7b: this entry needs a minted bundle before it can merge. Emit it
        # as a candidate UNLESS it's already fully pinned elsewhere in the
        # index (see alreadyPinnedInIndex's docstring for why that check is
        # necessary, not just an optimization).
        if not alreadyPinnedInIndex(idx, ns, pkg.name, sel.version, clone.contentHash):
          pending.add(BundleCandidate(
            namespace:   ns,
            name:        pkg.name,
            version:     sel.version,
            contentHash: clone.contentHash,
            upstream:    pkg.url,
            commitSha:   clone.commitSha,
            gitRef:      refName,
            publishedAt: nowIso,
          ))
    except CatchableError as e:
      stderr.writeLine("tianguis: vendor: " & pkg.name & " skipped: " & e.msg)
      skipped.add(pkg.name)
      continue

  VendorRunResult(index: idx, alerts: alerts, skipped: skipped, candidates: pending)

# ---------------------------------------------------------------------------
# S7b — apply previously-minted bundle pins (NO Driver, NO network)
# ---------------------------------------------------------------------------

proc applyBundlePins*(idx: Index, pins: seq[BundlePin]): tuple[index: Index, outcomes: seq[MergeOutcome]] =
  ## Apply previously-minted bundle pins to the entries they belong to.
  ##
  ## Each pin's candidate data was persisted verbatim by the candidate-emit
  ## pass (`runVendor`'s `pending`/`res.candidates`), so it's enough to
  ## reconstruct the exact `VendoredEntry` `buildVendoredEntry` would have
  ## produced — no Driver, no re-clone, no re-fetch. Threading the
  ## now-minted pin through `buildVendoredEntryFromCandidate` makes the S5
  ## epoch gate pass on this pass's `mergeVendored` call.
  ##
  ## Reuses `mergeVendored` (not a bespoke insert) so every existing
  ## invariant — identity drift, intra-org collision, content drift,
  ## idempotency — is enforced identically here as on a live vendor pass.
  var current = idx
  var outcomes: seq[MergeOutcome] = @[]
  for p in pins:
    let entry = buildVendoredEntryFromCandidate(p.candidate, p.pin)
    let (newIdx, outcome) = mergeVendored(current, entry)
    outcomes.add(outcome)
    if outcome.kind == mokAdded:
      current = newIdx
  (index: current, outcomes: outcomes)
