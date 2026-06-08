## Build VendoredEntry records from upstream data + merge them into
## an existing Index. Drift detection is the load-bearing safety: if
## a previously-vendored (package, version) reappears with a different
## content_hash, we DO NOT mutate the index (existing lockfiles depend
## on those bytes); we report the drift so a human can review.

import ../model
import ../namespace
import ./upstream
import ./tagselect

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

  MergeOutcomeKind* = enum
    mokAdded          ## new package or new version inserted
    mokIdempotent     ## identical re-ingest; index unchanged
    mokIdentityDrift  ## stored host/org namespace != re-derived (immutability violation; reject)
    mokCollision      ## intra-org leaf-name collision, different repo (reject-new/preserve-existing)
    mokContentDrift   ## same (namespace,name,version), different content_hash (reject incoming, warn)

  MergeOutcome* = object
    case kind*: MergeOutcomeKind
    of mokAdded, mokIdempotent: discard
    of mokIdentityDrift: identity*:  IdentityDrift      ## defined in namespace.nim
    of mokCollision:     collision*: IntraOrgCollision  ## defined in vendor/merge.nim
    of mokContentDrift:  content*:   DriftAlert         ## defined in vendor/merge.nim

const
  AttestationMilpaVendored = "milpa-vendored"
  MilpaBotIdentity = "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)"

proc buildVendoredEntry*(
    pkg: UpstreamPackage,
    selection: TagSelection,
    contentHash: string,
    commitSha: string,
    publishedAt: string,
    precomputedNs: string = "",
): Result[VendoredEntry, DerivationError] =
  ## Build a VendoredEntry from upstream package data.
  ## Hard-rejects (returns Err) if namespace cannot be derived from pkg.url —
  ## a package with no derivable namespace MUST NOT enter the index.
  ##
  ## `precomputedNs` (SSOT / M6): when the caller has already called
  ## deriveNamespace (e.g. for the denylist check), pass the result here to
  ## avoid a second derivation. When "" the function derives internally, so
  ## existing call sites need no change.
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
    ),
  ))

proc gitProvenanceRepo(pkg: Package): string =
  ## Return the repo segment from the first git provenance URL recorded
  ## on any version of this package. Returns "" if none.
  for v in pkg.versions:
    for prov in v.provenances:
      if prov.kind == pkGit:
        let r = deriveRepo(prov.url)
        if r.isOk: return r.get.repo
  ""

proc mergeVendored*(idx: Index, entry: VendoredEntry): tuple[index: Index, outcome: MergeOutcome] =
  ## Merge `entry` into `idx`. Returns the (possibly-mutated) index alongside
  ## a closed-sum outcome. Priority ordering on existing-package path:
  ##   mokIdentityDrift ▸ mokCollision ▸ mokContentDrift ▸ mokAdded/mokIdempotent
  ## On any reject kind, the returned index == idx (unchanged).
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
      index:   Index(schemaVersion: idx.schemaVersion, packages: packages),
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

  # --- Priority 3: content drift (same version, different hash) ---
  var existingVersions = packages[foundPkgIdx].versions
  for i, v in existingVersions:
    if v.version == entry.version.version:
      if v.contentHash == entry.version.contentHash:
        # Idempotent — same version + same hash, no change.
        return (index: idx, outcome: MergeOutcome(kind: mokIdempotent))
      # Drift — refuse to mutate; surface for human review.
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
    index:   Index(schemaVersion: idx.schemaVersion, packages: packages),
    outcome: MergeOutcome(kind: mokAdded),
  )
