## Build VendoredEntry records from upstream data + merge them into
## an existing Index. Drift detection is the load-bearing safety: if
## a previously-vendored (package, version) reappears with a different
## content_hash, we DO NOT mutate the index (existing lockfiles depend
## on those bytes); we report the drift so a human can review.

import std/options
import ../model
import ../namespace
import ./upstream
import ./tagselect
import ./candidates

type
  VendoredEntry* = object
    package*: Package    ## package skeleton (name, namespace, upstream — no versions)
    version*: Version    ## the version being vendored

  DriftAlert* = object
    ## Content-hash drift for a (namespace, name, version) triple.
    ## Both namespace and packageName are carried so same-leaf packages
    ## from different publishers are unambiguous in drift logs.
    packageName*:  string
    namespace*:    string   ## host/org identity — qualifies packageName
    version*:      string
    existingHash*: string
    newHash*:      string

  IntraOrgCollision* = object
    ## Two repos under the same (namespace, name) — second entry rejected.
    namespace*:    string   ## e.g. "github.com/acme"
    name*:         string   ## the leaf name (e.g. "utils")
    existingRepo*: string   ## repo segment from the already-stored entry's git URL
    newRepo*:      string   ## repo segment from the incoming entry's git URL

  MissingAttestationAlert* = object
    ## Publish-time epoch-gate rejection (rfc-attestation-delivery S5 /
    ## tianguis#42 deliverable 5): the entry's published_at is on/after the
    ## root attestation-epoch but it lacks a recognized attestation kind
    ## and/or a bundle pin.
    packageName*: string
    namespace*:   string
    version*:     string
    publishedAt*: string
    epoch*:       string

  SignerMismatchAlert* = object
    ## Signer-continuity ratchet rejection (rfc-attestation-delivery S8
    ## Layer 3 / tianguis#42 — the per-package anti-takeover guard): an
    ## incoming AUTHOR-SIGNED version's `signed_by` does not match the
    ## package's already-pinned `authorizedSigner`. Vendored (bot-signed)
    ## versions never trigger this — they are Layer-1-trusted and do not
    ## consult or mutate the pin.
    packageName*:    string
    namespace*:      string
    version*:        string
    pinnedSigner*:   string  ## Package.authorizedSigner at the time of rejection
    incomingSigner*: string  ## the rejected version's signed_by

  MergeOutcomeKind* = enum
    mokAdded               ## new package or new version inserted
    mokIdempotent          ## identical re-ingest; index unchanged
    mokIdentityDrift       ## stored host/org namespace != re-derived (immutability violation; reject)
    mokCollision           ## intra-org leaf-name collision, different repo (reject-new/preserve-existing)
    mokContentDrift        ## same (namespace,name,version), different content_hash (reject incoming, warn)
    mokRebaselined         ## epoch-migration: content_hash updated from old scheme to new (audit only)
    mokMissingAttestation  ## published_at >= attestation-epoch but no attestation/bundle pin (reject)
    mokSignerMismatch      ## author-signed version whose signed_by != the package's pinned
                           ## authorizedSigner (reject; anti-takeover guard)

  MergeOutcome* = object
    case kind*: MergeOutcomeKind
    of mokAdded, mokIdempotent: discard
    of mokIdentityDrift:       identity*:           IdentityDrift           ## defined in namespace.nim
    of mokCollision:           collision*:          IntraOrgCollision       ## defined in vendor/merge.nim
    of mokContentDrift:        content*:            DriftAlert              ## defined in vendor/merge.nim
    of mokRebaselined:         rebaseline*:         DriftAlert              ## old→new hash; audit trail
    of mokMissingAttestation:  missingAttestation*: MissingAttestationAlert ## defined in vendor/merge.nim
    of mokSignerMismatch:      signerMismatch*:     SignerMismatchAlert     ## defined in vendor/merge.nim

const
  AttestationMilpaVendored* = "milpa-vendored"
      ## Exported: rfc-attestation-delivery S9 backfill enumeration
      ## (orchestrate.nim's `enumerateBackfillCandidates`) is the single
      ## other reader — SSOT for the "milpa-vendored" literal stays here.
  AttestationAuthorSigned = "author-signed"
  RecognizedAttestationKinds = [AttestationMilpaVendored, AttestationAuthorSigned]
  MilpaBotIdentity = "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)"

proc buildVendoredEntry*(
    pkg: UpstreamPackage,
    selection: TagSelection,
    contentHash: string,
    commitSha: string,
    publishedAt: string,
    precomputedNs: string = "",
    bundlePin: string = "",
): Result[VendoredEntry, DerivationError] =
  ## Build a VendoredEntry from upstream package data.
  ## Hard-rejects (returns Err) if namespace cannot be derived from pkg.url —
  ## a package with no derivable namespace MUST NOT enter the index.
  ##
  ## `precomputedNs` (SSOT / M6): when the caller has already called
  ## deriveNamespace (e.g. for the denylist check), pass the result here to
  ## avoid a second derivation. When "" the function derives internally, so
  ## existing call sites need no change.
  ##
  ## `bundlePin` (rfc-attestation-delivery S7a): sha256 hex of the minted
  ## attestation bundle's bytes, threaded through by the vendor orchestration
  ## (S7b — cosign attest-blob over the S3 statement → S4 content-addressed
  ## store → pin). Default "" preserves existing callers' behavior exactly:
  ## `Version.bundlePin` builds as `none(string)`.
  let ns =
    if precomputedNs.len > 0:
      precomputedNs
    else:
      let nsResult = deriveNamespace(pkg.url)
      if nsResult.isErr:
        return err[VendoredEntry, DerivationError](nsResult.error)
      namespaceString(nsResult.get)
  let gitRef = if selection.tag.len > 0: selection.tag else: "HEAD"
  ok[VendoredEntry, DerivationError](VendoredEntry(
    package: Package(
      name: pkg.name,
      namespace: ns,
      upstream: pkg.url,
    ),
    version: Version(
      version:     selection.version,
      contentHash: contentHash,
      attestation: AttestationMilpaVendored,
      signedBy:    MilpaBotIdentity,
      publishedAt: publishedAt,
      provenances: @[Provenance(
        kind:      pkGit,
        url:       pkg.url,
        gitRef:    gitRef,
        commitSha: commitSha,
      )],
      bundlePin:
        if bundlePin.len > 0: some(bundlePin)
        else: none(string),
    ),
  ))

proc buildVendoredEntryFromCandidate*(candidate: BundleCandidate, bundlePin: string): VendoredEntry =
  ## Reconstruct the VendoredEntry `buildVendoredEntry` would have produced
  ## for this (namespace, name, version) — but from PERSISTED candidate data
  ## (rfc-attestation-delivery S7b candidate→mint→apply flow), with NO
  ## second upstream fetch. Used by `tianguis vendor --bundle-pins=<path>`
  ## (orchestrate.applyBundlePins) to admit entries whose bundle was minted
  ## out-of-process (CI-only cosign/sigstore signing) between the
  ## candidate-emit pass and this one.
  ##
  ## `bundlePin` is threaded in raw (not validated here) — callers
  ## (`applyBundlePins`) are responsible for supplying an already-validated
  ## pin; `parsePinsJson` is the validation boundary for pins read from disk.
  VendoredEntry(
    package: Package(
      name:      candidate.name,
      namespace: candidate.namespace,
      upstream:  candidate.upstream,
    ),
    version: Version(
      version:     candidate.version,
      contentHash: candidate.contentHash,
      attestation: AttestationMilpaVendored,
      signedBy:    MilpaBotIdentity,
      publishedAt: candidate.publishedAt,
      provenances: @[Provenance(
        kind:      pkGit,
        url:       candidate.upstream,
        gitRef:    candidate.gitRef,
        commitSha: candidate.commitSha,
      )],
      bundlePin:
        if bundlePin.len > 0: some(bundlePin)
        else: none(string),
    ),
  )

proc gitProvenanceRepo(pkg: Package): string =
  ## Return the repo segment from the first git provenance URL recorded
  ## on any version of this package. Returns "" if none.
  for v in pkg.versions:
    for prov in v.provenances:
      if prov.kind == pkGit:
        let r = deriveRepo(prov.url)
        if r.isOk: return r.get.repo
  ""

proc attestationGateRejects(idx: Index, entry: VendoredEntry): bool =
  ## Publish-time epoch gate (rfc-attestation-delivery S5 / tianguis#42
  ## deliverable 5): once the index has a root `attestation-epoch` E set,
  ## every entry whose `published_at >= E` MUST carry BOTH a recognized
  ## attestation kind (the closed set `author-signed` | `milpa-vendored` —
  ## milpa RFC §2) AND a bundle pin. This is what lets milpa's
  ## `entry-trust "strict"` be epoch-based rather than coverage-based: a
  ## `milpa-vendored` entry with no pin still rejects post-epoch (the
  ## vendor bot mints pin + bundle before calling this, S7) — attestation
  ## kind alone is not sufficient once the epoch is live.
  ##
  ## Timestamps are compared lexicographically. This is safe (and matches
  ## milpa's own ratchet comparison) ONLY because both sides are always the
  ## single canonical UTC ISO-8601 form tianguis emits at publish time —
  ## `yyyy-MM-dd'T'HH:mm:ss'Z'` (see `nowStr` in addentry.nim/orchestrate.nim
  ## and the ratchet in index_ratchet_seam.py on the milpa side) — fixed
  ## width, zero-padded, always UTC ('Z'), so byte-lexicographic order equals
  ## chronological order. Entries with no epoch set, or published before it,
  ## are entirely unaffected (epoch-forward-only; legacy entries pass as-is).
  if idx.attestationEpoch.isNone: return false
  if entry.version.publishedAt < idx.attestationEpoch.get: return false
  entry.version.attestation notin RecognizedAttestationKinds or
    entry.version.bundlePin.isNone

proc isAuthorSigned(v: Version): bool =
  ## True iff `v` carries the `author-signed` attestation kind — the only
  ## kind gated by the signer-continuity ratchet (S8 Layer 3). Vendored
  ## (`milpa-vendored`, bot-signed) versions are Layer-1-trusted already and
  ## never consult or mutate `Package.authorizedSigner`.
  v.attestation == AttestationAuthorSigned

proc missingAttestationOutcome(idx: Index, entry: VendoredEntry): MergeOutcome =
  MergeOutcome(kind: mokMissingAttestation, missingAttestation: MissingAttestationAlert(
    packageName: entry.package.name,
    namespace:   entry.package.namespace,
    version:     entry.version.version,
    publishedAt: entry.version.publishedAt,
    epoch:       idx.attestationEpoch.get,
  ))

proc mergeVendored*(idx: Index, entry: VendoredEntry): tuple[index: Index, outcome: MergeOutcome] =
  ## Merge `entry` into `idx`. Returns the (possibly-mutated) index alongside
  ## a closed-sum outcome. Priority ordering:
  ##   mokMissingAttestation ▸ mokIdentityDrift ▸ mokCollision ▸ mokSignerMismatch
  ##   ▸ mokContentDrift ▸ mokAdded/mokIdempotent
  ## On any reject kind, the returned index == idx (unchanged).
  ##
  ## Signer-continuity ratchet (S8 Layer 3, mokSignerMismatch) sits AFTER the
  ## identity/collision guards (those settle "is this even the same package"
  ## before we ask "is this author allowed to publish to it") and BEFORE
  ## content-drift (so a takeover attempt disguised as a same-version content
  ## update is reported as the security-relevant signer mismatch, not buried
  ## under a generic drift warning). It stays AFTER mokMissingAttestation,
  ## which is a structural delivery-completeness gate that needs no package
  ## lookup at all and rejects before we ever read `Package.authorizedSigner`.
  if attestationGateRejects(idx, entry):
    return (index: idx, outcome: missingAttestationOutcome(idx, entry))

  var packages = idx.packages
  var foundPkgIdx = -1
  for i, p in packages:
    if (p.namespace, p.name) == (entry.package.namespace, entry.package.name):
      foundPkgIdx = i
      break

  if foundPkgIdx < 0:
    var newPkg = entry.package
    newPkg.versions = @[entry.version]
    # First-ever version of a brand-new package: an author-signed entry pins
    # the ratchet immediately (TOFU). Vendored entries never pin.
    if isAuthorSigned(entry.version):
      newPkg.authorizedSigner = some(entry.version.signedBy)
    packages.add(newPkg)
    return (
      index:   Index(schemaVersion: idx.schemaVersion, attestationEpoch: idx.attestationEpoch, packages: packages),
      outcome: MergeOutcome(kind: mokAdded),
    )

  # --- Priority 1: identity drift (immutability guard) ---
  # Fire ONLY when the stored namespace is already host/org (contains '/').
  # Pre-migration org-only stored values are skipped to avoid false positives.
  let storedNs = packages[foundPkgIdx].namespace
  if '/' in storedNs:
    # Re-derive the namespace from the first version's git provenance.
    let rederivedResult = deriveVersionNamespace(entry.version)
    if rederivedResult.isOk:
      let rederived = rederivedResult.get
      let driftOpt = checkIdentityStable(entry.package.name, storedNs, rederived)
      if driftOpt.isSome:
        return (
          index:   idx,
          outcome: MergeOutcome(kind: mokIdentityDrift, identity: driftOpt.get),
        )
    else:
      # Derivation failed on the incoming entry while stored ns is host/org.
      # A version with no derivable provenance anchor MUST NOT enter the index
      # under an established host/org namespace — treat it as identity drift
      # (the "rederived" namespace is unknown, which is worse than wrong).
      return (
        index:   idx,
        outcome: MergeOutcome(kind: mokIdentityDrift, identity: IdentityDrift(
          name:               entry.package.name,
          storedNamespace:    storedNs,
          rederivedNamespace: "",  # empty = underivable; signals provenance gap
        )),
      )

  # --- Priority 2: intra-org leaf collision (same namespace+name, different repo) ---
  let existingRepoSeg = gitProvenanceRepo(packages[foundPkgIdx])
  let incomingRepoSeg =
    block:
      let r = deriveRepo(entry.package.upstream)
      if r.isOk: r.get.repo else: ""
  if existingRepoSeg.len > 0 and incomingRepoSeg.len > 0 and
      existingRepoSeg != incomingRepoSeg:
    return (
      index:   idx,
      outcome: MergeOutcome(kind: mokCollision, collision: IntraOrgCollision(
        namespace:    entry.package.namespace,
        name:         entry.package.name,
        existingRepo: existingRepoSeg,
        newRepo:      incomingRepoSeg,
      )),
    )

  # --- Priority 3: signer-continuity ratchet (S8 Layer 3 anti-takeover guard) ---
  # Only author-signed incoming versions are gated. Vendored (bot-signed)
  # versions are Layer-1-trusted already and skip this tier entirely — they
  # neither pin nor overwrite `authorizedSigner`.
  if isAuthorSigned(entry.version):
    let pinned = packages[foundPkgIdx].authorizedSigner
    if pinned.isNone:
      # TOFU: first author-signed version ever ingested for this package
      # (whether brand-new or previously seeded only by vendored versions)
      # pins the ratchet. Persisted only if the merge ultimately admits the
      # version (see below) — a rejected ingest must not leave a partial pin.
      packages[foundPkgIdx].authorizedSigner = some(entry.version.signedBy)
    elif pinned.get != entry.version.signedBy:
      return (
        index:   idx,
        outcome: MergeOutcome(kind: mokSignerMismatch, signerMismatch: SignerMismatchAlert(
          packageName:    entry.package.name,
          namespace:      entry.package.namespace,
          version:        entry.version.version,
          pinnedSigner:   pinned.get,
          incomingSigner: entry.version.signedBy,
        )),
      )

  # --- Priority 4: content drift (same version, different hash) ---
  var existingVersions = packages[foundPkgIdx].versions
  for i, v in existingVersions:
    if v.version == entry.version.version:
      if v.contentHash == entry.version.contentHash:
        # Idempotent — same version + same hash, no change. Returns the
        # ORIGINAL idx: any signer-pin write staged above is discarded along
        # with the rest of this no-op ingest (it was already pinned, or this
        # is a pre-ratchet legacy entry that idempotent re-ingest does not
        # retroactively backfill — only forward admissions establish the pin).
        return (index: idx, outcome: MergeOutcome(kind: mokIdempotent))
      # Drift — refuse to mutate; surface for human review. Returns the
      # ORIGINAL idx, discarding any staged signer-pin write above: a
      # rejected ingest must not leave a partial mutation.
      return (
        index:   idx,
        outcome: MergeOutcome(kind: mokContentDrift, content: DriftAlert(
          packageName:  entry.package.name,
          namespace:    entry.package.namespace,
          version:      entry.version.version,
          existingHash: v.contentHash,
          newHash:      entry.version.contentHash,
        )),
      )

  # --- New version on an existing package ---
  existingVersions.add(entry.version)
  packages[foundPkgIdx].versions = existingVersions
  (
    index:   Index(schemaVersion: idx.schemaVersion, attestationEpoch: idx.attestationEpoch, packages: packages),
    outcome: MergeOutcome(kind: mokAdded),
  )

proc mergeRebaseline*(idx: Index, entry: VendoredEntry): tuple[index: Index, outcome: MergeOutcome] =
  ## Epoch-migration variant of mergeVendored: identical in every check EXCEPT
  ## the content-drift branch. When an existing (namespace, name, version) is
  ## found with a DIFFERENT content_hash, instead of rejecting (mokContentDrift),
  ## this proc UPDATES the stored hash to the incoming epoch-2 value and returns
  ## mokRebaselined so the caller persists the mutated index.
  ##
  ## ALL other protections remain enforced:
  ##   mokIdentityDrift — namespace identity immutability guard (still rejects)
  ##   mokCollision     — intra-org leaf-name collision (still rejects)
  ##   mokIdempotent    — incoming hash already matches stored (still a no-op)
  ##
  ## This is the ONLY merge proc that may mutate an existing version's
  ## content_hash. Normal vendoring NEVER does this (see mergeVendored).
  ##
  ## The publish-time attestation-epoch gate (S5) applies here too — a
  ## rebaseline is still an admission of an entry's current state into the
  ## index, so it is bound by the same post-epoch requirement.
  if attestationGateRejects(idx, entry):
    return (index: idx, outcome: missingAttestationOutcome(idx, entry))

  var packages = idx.packages
  var foundPkgIdx = -1
  for i, p in packages:
    if (p.namespace, p.name) == (entry.package.namespace, entry.package.name):
      foundPkgIdx = i
      break

  if foundPkgIdx < 0:
    var newPkg = entry.package
    newPkg.versions = @[entry.version]
    packages.add(newPkg)
    return (
      index:   Index(schemaVersion: idx.schemaVersion, attestationEpoch: idx.attestationEpoch, packages: packages),
      outcome: MergeOutcome(kind: mokAdded),
    )

  # --- Priority 1: identity drift (immutability guard — unchanged from mergeVendored) ---
  let storedNs = packages[foundPkgIdx].namespace
  if '/' in storedNs:
    let rederivedResult = deriveVersionNamespace(entry.version)
    if rederivedResult.isOk:
      let rederived = rederivedResult.get
      let driftOpt = checkIdentityStable(entry.package.name, storedNs, rederived)
      if driftOpt.isSome:
        return (
          index:   idx,
          outcome: MergeOutcome(kind: mokIdentityDrift, identity: driftOpt.get),
        )
    else:
      return (
        index:   idx,
        outcome: MergeOutcome(kind: mokIdentityDrift, identity: IdentityDrift(
          name:               entry.package.name,
          storedNamespace:    storedNs,
          rederivedNamespace: "",
        )),
      )

  # --- Priority 2: intra-org leaf collision (unchanged from mergeVendored) ---
  let existingRepoSeg = gitProvenanceRepo(packages[foundPkgIdx])
  let incomingRepoSeg =
    block:
      let r = deriveRepo(entry.package.upstream)
      if r.isOk: r.get.repo else: ""
  if existingRepoSeg.len > 0 and incomingRepoSeg.len > 0 and
      existingRepoSeg != incomingRepoSeg:
    return (
      index:   idx,
      outcome: MergeOutcome(kind: mokCollision, collision: IntraOrgCollision(
        namespace:    entry.package.namespace,
        name:         entry.package.name,
        existingRepo: existingRepoSeg,
        newRepo:      incomingRepoSeg,
      )),
    )

  # --- Priority 3 (REBASELINE): same version, different hash — UPDATE, do not reject ---
  var existingVersions = packages[foundPkgIdx].versions
  for i, v in existingVersions:
    if v.version == entry.version.version:
      if v.contentHash == entry.version.contentHash:
        # Idempotent — hash already matches epoch-2 form; nothing to do.
        return (index: idx, outcome: MergeOutcome(kind: mokIdempotent))
      # Re-baseline: overwrite stored hash with incoming epoch-2 value.
      let alert = DriftAlert(
        packageName:  entry.package.name,
        namespace:    entry.package.namespace,
        version:      entry.version.version,
        existingHash: v.contentHash,
        newHash:      entry.version.contentHash,
      )
      existingVersions[i].contentHash = entry.version.contentHash
      packages[foundPkgIdx].versions = existingVersions
      return (
        index:   Index(schemaVersion: idx.schemaVersion, attestationEpoch: idx.attestationEpoch, packages: packages),
        outcome: MergeOutcome(kind: mokRebaselined, rebaseline: alert),
      )

  # --- New version on existing package (no drift; append as normal) ---
  existingVersions.add(entry.version)
  packages[foundPkgIdx].versions = existingVersions
  (
    index:   Index(schemaVersion: idx.schemaVersion, attestationEpoch: idx.attestationEpoch, packages: packages),
    outcome: MergeOutcome(kind: mokAdded),
  )
