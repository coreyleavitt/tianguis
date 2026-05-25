## Build VendoredEntry records from upstream data + merge them into
## an existing Index. Drift detection is the load-bearing safety: if
## a previously-vendored (package, version) reappears with a different
## content_hash, we DO NOT mutate the index (existing lockfiles depend
## on those bytes); we report the drift so a human can review.

import std/[options, tables]
import ../model
import ./upstream
import ./tagselect

type
  VendoredEntry* = object
    package*: Package    ## package skeleton (name, namespace, upstream — no versions)
    version*: Version    ## the version being vendored

  DriftAlert* = object
    packageName*:  string
    version*:      string
    existingHash*: string
    newHash*:      string

  MergeOutcome* = object
    index*: Index
    drift*: Option[DriftAlert]

const
  AttestationMilpaVendored = "milpa-vendored"
  MilpaBotIdentity = "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)"

proc namespaceOf(url: string): string =
  ## Derive a GitHub-style namespace from a URL like
  ## "https://github.com/<ns>/<repo>". Best-effort; empty for
  ## non-github / unparseable inputs (future cycle: extend for
  ## gitlab/codeberg/etc. when those upstreams matter).
  const githubPrefix = "https://github.com/"
  if url.len <= githubPrefix.len or url[0 ..< githubPrefix.len] != githubPrefix:
    return ""
  let tail = url[githubPrefix.len .. ^1]
  let slash = tail.find('/')
  if slash <= 0:
    return ""
  tail[0 ..< slash]

proc buildVendoredEntry*(
    pkg: UpstreamPackage,
    selection: TagSelection,
    contentHash: string,
    commitSha: string,
    publishedAt: string,
): VendoredEntry =
  let gitRef = if selection.tag.len > 0: selection.tag else: "HEAD"
  VendoredEntry(
    package: Package(
      name: pkg.name,
      namespace: namespaceOf(pkg.url),
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
  )

proc mergeVendored*(idx: Index, entry: VendoredEntry): MergeOutcome =
  ## Merge `entry` into `idx`. Returns the new index plus an optional
  ## drift alert if a same-named version with a different content_hash
  ## already exists (in which case the index is returned UNCHANGED).
  ## Idempotent when entry's content_hash matches an existing entry.
  var packages = idx.packages
  var foundPkgIdx = -1
  for i, p in packages:
    if p.name == entry.package.name:
      foundPkgIdx = i
      break

  if foundPkgIdx < 0:
    var newPkg = entry.package
    newPkg.versions = @[entry.version]
    packages.add(newPkg)
    return MergeOutcome(
      index: Index(schemaVersion: idx.schemaVersion, packages: packages),
      drift: none(DriftAlert),
    )

  # Package exists. Check for an existing version.
  var existingVersions = packages[foundPkgIdx].versions
  for i, v in existingVersions:
    if v.version == entry.version.version:
      if v.contentHash == entry.version.contentHash:
        # Idempotent — same version + same hash, no change.
        return MergeOutcome(index: idx, drift: none(DriftAlert))
      # Drift — refuse to mutate; surface for human review.
      return MergeOutcome(
        index: idx,
        drift: some(DriftAlert(
          packageName:  entry.package.name,
          version:      entry.version.version,
          existingHash: v.contentHash,
          newHash:      entry.version.contentHash,
        )),
      )

  # New version on an existing package.
  existingVersions.add(entry.version)
  packages[foundPkgIdx].versions = existingVersions
  MergeOutcome(
    index: Index(schemaVersion: idx.schemaVersion, packages: packages),
    drift: none(DriftAlert),
  )
