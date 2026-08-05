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
      of mokSignerMismatch:
        # Unreachable in practice: runVendor only ever builds milpa-vendored
        # entries (buildVendoredEntry always sets attestation="milpa-vendored"),
        # and the ratchet only gates author-signed incoming versions. Kept
        # exhaustive + logged (not `discard`) so a future author-signed
        # vendoring path doesn't silently swallow a takeover attempt.
        let sm = outcome.signerMismatch
        alerts = appendAlert(alerts, sm, detectedAt = nowIso)
        stderr.writeLine("tianguis: vendor: IDX-SIGNER-MISMATCH: " &
          sm.namespace & "/" & sm.packageName & "@" & sm.version &
          " pinned=" & sm.pinnedSigner & " incoming=" & sm.incomingSigner)
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

# ---------------------------------------------------------------------------
# S9 — backfill candidate enumeration (full-index sweep, no Driver, no network)
# ---------------------------------------------------------------------------

proc enumerateBackfillCandidates*(idx: Index): seq[BundleCandidate] =
  ## Full-index sweep (rfc-attestation-delivery.handoff.md S9; tianguis#42):
  ## every EXISTING entry already in `idx` that lacks a bundle pin and is
  ## eligible for a bot-minted vendored bundle.
  ##
  ## Unlike S7b's `runVendor`, which only captures entries rejected by THIS
  ## pass's own merge attempt (`pending` above), this walks every
  ## (namespace, name, version) already committed to the index — the
  ## backfill for whatever the delivery gate wasn't live to catch when those
  ## entries were first admitted.
  ##
  ## Eligibility is deliberately narrower than "any pinless entry": ONLY
  ## `milpa-vendored` versions qualify. An `author-signed` version must
  ## NEVER be given a bot-minted vendored bundle — the bundle's `signed_by`
  ## would claim the vendor-bot identity, misattributing an entry that
  ## really has its own author. Author-signed backfill (if ever needed) is
  ## the S8 author-attested flow, not this one.
  ##
  ## Returns `BundleCandidate`s in the SAME shape S7b emits, so the existing
  ## `tianguis vendor --bundle-pins=<path>` apply path (`applyBundlePins` /
  ## `buildVendoredEntryFromCandidate`) consumes them completely unchanged —
  ## no new apply logic, no duplicated merge/gate code.
  for pkg in idx.packages:
    for v in pkg.versions:
      if v.bundlePin.isSome: continue
      if v.attestation != AttestationMilpaVendored: continue
      var gitProv: Provenance
      var hasGit = false
      for prov in v.provenances:
        if prov.kind == pkGit:
          gitProv = prov
          hasGit = true
          break
      if not hasGit:
        # Every real milpa-vendored entry carries a git Provenance
        # (buildVendoredEntry always attaches one; it's the only producer
        # of milpa-vendored entries). Unreachable in practice, but a
        # candidate can't be reconstructed without it — skip rather than
        # emit a candidate with fabricated commit/ref fields.
        continue
      result.add(BundleCandidate(
        namespace:   pkg.namespace,
        name:        pkg.name,
        version:     v.version,
        contentHash: v.contentHash,
        upstream:    pkg.upstream,
        commitSha:   gitProv.commitSha,
        gitRef:      gitProv.gitRef,
        publishedAt: v.publishedAt,
      ))

type
  BackfillOutcomeKind* = enum
    bokPinned          ## matching pinless entry found; bundlePin now set
    bokAlreadyPinned   ## entry already carried a bundlePin (no-op, not an error —
                       ## e.g. a re-applied pins file, or another backfill run won the race)
    bokNotFound        ## no (namespace, name, version) match in the index
    bokContentMismatch ## version found but contentHash differs from the candidate's —
                       ## refuse to touch it (content drift; surface for human review)

  BackfillOutcome* = object
    kind*:        BackfillOutcomeKind
    namespace*:   string
    packageName*: string
    version*:     string

proc applyBackfillPins*(idx: Index, pins: seq[BundlePin]): tuple[index: Index, outcomes: seq[BackfillOutcome]] =
  ## Apply previously-minted bundle pins onto EXISTING entries (S9 backfill;
  ## tianguis#42) — deliberately NOT `mergeVendored`/`applyBundlePins` (S7b).
  ##
  ## S7b's `applyBundlePins` reuses `mergeVendored` because its candidates
  ## describe versions that were REJECTED before ever entering the index —
  ## the pinned re-application always inserts a genuinely new version, so
  ## `mergeVendored`'s full admission machinery (identity drift, collision,
  ## signer ratchet, content drift) is exactly what's wanted.
  ##
  ## A backfill candidate is the opposite: `enumerateBackfillCandidates`
  ## only emits entries that are ALREADY committed in the index (that's the
  ## whole point of "backfill" — legacy pre-epoch entries the delivery gate
  ## never required to carry a pin). Feeding such a candidate through
  ## `mergeVendored` hits its same-version/same-contentHash idempotent
  ## branch, which returns the ORIGINAL index unchanged and silently
  ## discards the freshly-minted pin — the admission checks were never
  ## designed to update a field on an entry that already matches. This
  ## proc instead does the narrower, correct thing: find the exact existing
  ## (namespace, name, version) entry, confirm its content_hash still
  ## matches the candidate's (refuse — don't overwrite — on drift), and set
  ## `bundlePin` in place. No identity/collision/signer re-checks: those
  ## guard ADMISSION of new/incoming data, and this entry was already
  ## admitted; only its previously-absent pin is being filled in.
  var packages = idx.packages
  var outcomes: seq[BackfillOutcome] = @[]
  for p in pins:
    let c = p.candidate
    var pkgIdx = -1
    for i, pkg in packages:
      if pkg.namespace == c.namespace and pkg.name == c.name:
        pkgIdx = i
        break
    if pkgIdx < 0:
      outcomes.add(BackfillOutcome(kind: bokNotFound, namespace: c.namespace, packageName: c.name, version: c.version))
      continue
    var verIdx = -1
    for i, v in packages[pkgIdx].versions:
      if v.version == c.version:
        verIdx = i
        break
    if verIdx < 0:
      outcomes.add(BackfillOutcome(kind: bokNotFound, namespace: c.namespace, packageName: c.name, version: c.version))
      continue
    if packages[pkgIdx].versions[verIdx].bundlePin.isSome:
      outcomes.add(BackfillOutcome(kind: bokAlreadyPinned, namespace: c.namespace, packageName: c.name, version: c.version))
      continue
    if packages[pkgIdx].versions[verIdx].contentHash != c.contentHash:
      outcomes.add(BackfillOutcome(kind: bokContentMismatch, namespace: c.namespace, packageName: c.name, version: c.version))
      continue
    packages[pkgIdx].versions[verIdx].bundlePin = some(p.pin)
    outcomes.add(BackfillOutcome(kind: bokPinned, namespace: c.namespace, packageName: c.name, version: c.version))
  (
    index: Index(schemaVersion: idx.schemaVersion, attestationEpoch: idx.attestationEpoch, attestationEpochCommitment: idx.attestationEpochCommitment, packages: packages),
    outcomes: outcomes,
  )

proc applyCandidateCap*(candidates: seq[BundleCandidate], cap: int): tuple[kept: seq[BundleCandidate], skipped: int] =
  ## Optionally cap the number of candidates a single backfill pass emits —
  ## a full-index sweep can be large, and a CI mint-loop's runtime should
  ## stay bounded. `cap <= 0` means "no cap" (backfill.nim's CLI wrapper
  ## treats an absent/zero `--cap` this way). Never silently truncates: the
  ## caller (`cmdBackfill`) logs the skipped count so a re-run is visibly
  ## needed, not just inferred from a shorter-than-expected candidates file.
  if cap <= 0 or candidates.len <= cap:
    (kept: candidates, skipped: 0)
  else:
    (kept: candidates[0 ..< cap], skipped: candidates.len - cap)
