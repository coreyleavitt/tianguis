## Typed data model for the tianguis package index.
##
## KDL (`index.kdl`) and JSON (`index.json`) are projections of this model;
## the model is the canonical artifact, both serializations are derivable.

import std/[algorithm, options, strutils, tables]

type
  ProvenanceKind* = enum
    pkGit = "git"
    pkOci = "oci"

  RekorRef* = object
    ## Durable, publish-time-captured pointer to the Rekor transparency-log
    ## entry for an author-signed artifact's `cosign sign` signature.
    ##
    ## Recorded once, at ingest, from the same `cosign verify --output json`
    ## the commit-entry workflow already runs (Gate B). The site reads these
    ## fields directly and renders a stable "view in Rekor" link — it no
    ## longer re-derives the entry via a live `cosign verify` at every build,
    ## which was the root cause of the recurring vanishing-link bug.
    ##
    ## Author-signed versions only; absent (`Version.rekor == none`) on
    ## milpa-vendored entries, which carry no author cosign signature.
    ##
    ## `uuid` is the most durable identifier: the Rekor entry UUID is
    ## content-addressed and shard-independent. `logIndex` is shard-relative
    ## (an int) and `integratedTime` is convenience metadata; both are kept
    ## because search.sigstore.dev accepts `?logIndex=` and they aid audit.
    ## All three are stored as strings (the scalar-child KDL shape; avoids
    ## the float-parse hazard of bare KDL numbers on the read side).
    uuid*:           string  ## Rekor entry UUID (content-addressed) — primary link key
    logIndex*:       string  ## Rekor logIndex (shard-relative int, as string)
    integratedTime*: string  ## inclusion timestamp (epoch seconds, as string)

  Provenance* = object
    ## Discriminated union over transport kinds (per
    ## rfc-pluggable-fetchers.md). More kinds (tarball, hg, fossil,
    ## local, ipfs) added as their fetchers land.
    case kind*: ProvenanceKind
    of pkGit:
      url*:       string
      gitRef*:    string         ## `ref` is reserved in Nim; serialized as "ref"
      commitSha*: string
    of pkOci:
      registry*:   string
      repository*: string
      digest*:     string

  Version* = object
    version*:          string         ## semver-shaped version identifier
    contentHash*:      string         ## multihash: "sha256:<hex>"
    requires*:         OrderedTable[string, string]   ## dep name → version constraint
    attestation*:      string         ## "milpa-vendored" | "author-signed"
    signedBy*:         string         ## URI identifying the signer
    publishedAt*:      string         ## ISO 8601 UTC timestamp
    provenances*:      seq[Provenance]
    rekor*:            Option[RekorRef] ## author-signed: durable Rekor entry pointer
                                        ## captured at publish (see RekorRef). `none`
                                        ## on milpa-vendored versions.
    bundlePin*:        Option[string]  ## sha256 hex (64 lowercase hex chars) of the
                                        ## per-entry attestation bundle's BYTES — the
                                        ## delivery-integrity pin milpa parses as the
                                        ## 4th attestation sibling (registry-protocol
                                        ## §3.2). `none` until the bundle is minted and
                                        ## persisted (rfc-attestation-delivery S1).
    partiallyResolved*: bool           ## true when ≥1 bare `requires` entry could not
                                       ## be mapped to a qualified (namespace, name) pair;
                                       ## gates resolver correctness independently of edge
                                       ## persistence (rfc-package-identity.md S5)

  Package* = object
    name*:      string
    namespace*: string           ## OCI/GH namespace owning this name
    upstream*:  string           ## Upstream source URL (for human reference + link)
    versions*:  seq[Version]

  Index* = object
    ## Top-level index document.
    schemaVersion*:     int
    attestationEpoch*:  Option[string]  ## document-root ratchet timestamp
        ## (opaque ISO-8601-ish string, matching `published_at`'s shape):
        ## every version with `published_at >= attestationEpoch` MUST carry
        ## an attestation + bundle pin (enforcement is a later slice; this
        ## field is schema-only — rfc-attestation-delivery S2). `none` until
        ## the ratchet is first set. Wire name is `attestation-epoch` at the
        ## KDL document root — milpa's `index_ratchet_seam._raw_attestation_epoch`
        ## parses this exact name; do not rename.
    packages*:          seq[Package]

# ---------------------------------------------------------------------------
# Equality for object variants — Nim's auto-derived `==` can't traverse
# case-object fields safely (parallel-fields iterator chokes on differing
# discriminators). Explicit per-variant comparison.
# ---------------------------------------------------------------------------

proc `==`*(a, b: Provenance): bool =
  if a.kind != b.kind: return false
  case a.kind
  of pkGit:
    a.url == b.url and a.gitRef == b.gitRef and a.commitSha == b.commitSha
  of pkOci:
    a.registry == b.registry and a.repository == b.repository and a.digest == b.digest

proc `==`*(a, b: Version): bool =
  a.version == b.version and
    a.contentHash == b.contentHash and
    a.attestation == b.attestation and
    a.signedBy == b.signedBy and
    a.publishedAt == b.publishedAt and
    a.provenances == b.provenances and
    a.rekor == b.rekor and
    a.bundlePin == b.bundlePin and
    a.requires == b.requires and
    a.partiallyResolved == b.partiallyResolved

proc `==`*(a, b: Package): bool =
  a.name == b.name and a.namespace == b.namespace and
    a.upstream == b.upstream and a.versions == b.versions

proc `==`*(a, b: Index): bool =
  a.schemaVersion == b.schemaVersion and
    a.attestationEpoch == b.attestationEpoch and
    a.packages == b.packages

# ---------------------------------------------------------------------------
# Canonical ordering
# ---------------------------------------------------------------------------

proc parseSemverTriple(s: string): (int, int, int) =
  ## Best-effort parse of a semver-shaped version into a comparison
  ## triple. Non-numeric or malformed parts yield 0; pre-release and
  ## build-metadata suffixes are stripped (future cycle: prerelease
  ## ordering per semver 2.0.0).
  let core = s.split({'-', '+'})[0]   # strip "-rc.1" / "+build.123"
  let parts = core.split('.')
  proc toInt(p: string): int =
    try: parseInt(p) except ValueError: 0
  case parts.len
  of 0: (0, 0, 0)
  of 1: (toInt(parts[0]), 0, 0)
  of 2: (toInt(parts[0]), toInt(parts[1]), 0)
  else: (toInt(parts[0]), toInt(parts[1]), toInt(parts[2]))

proc compareVersionsDescending(a, b: Version): int =
  ## Newest first by parsed semver triple. Falls back to lexicographic
  ## descending for ties or unparseable versions.
  let ap = parseSemverTriple(a.version)
  let bp = parseSemverTriple(b.version)
  if ap > bp: -1
  elif ap < bp: 1
  else: cmp(b.version, a.version)

proc canonicalRequires(r: OrderedTable[string, string]): OrderedTable[string, string] =
  var keys: seq[string] = @[]
  for k in r.keys: keys.add(k)
  keys.sort()
  result = initOrderedTable[string, string]()
  for k in keys:
    result[k] = r[k]

proc canonicalize*(idx: Index): Index =
  ## Return an Index whose packages are alphabetically sorted by name,
  ## whose versions per-package are sorted descending semver, and whose
  ## requires-maps within versions are alphabetically keyed.
  ## Provenances within a version preserve declaration order (publisher
  ## intent — first-listed is preferred fetch).
  ## Idempotent.
  var packages = idx.packages
  for i in 0 ..< packages.len:
    var sortedVersions = packages[i].versions
    sortedVersions.sort(compareVersionsDescending)
    for j in 0 ..< sortedVersions.len:
      sortedVersions[j].requires = canonicalRequires(sortedVersions[j].requires)
    packages[i].versions = sortedVersions
  packages.sort(proc(a, b: Package): int = cmp((a.namespace, a.name), (b.namespace, b.name)))
  Index(schemaVersion: idx.schemaVersion, attestationEpoch: idx.attestationEpoch,
        packages: packages)
