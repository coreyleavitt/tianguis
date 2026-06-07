## Pure index migration — P1.3.
##
## `migrateIndex` lifts a pre-migration Index (packages with bare org-only
## namespaces, or the legacy `nimkdl` conflated entry) into the canonical
## `host/org` namespace form defined by `deriveVersionNamespace`.
##
## Rules:
##   - Per-version: the derived namespace is computed via deriveVersionNamespace.
##     Any failure → MigrationHalt(mhkDerivationFailed).
##   - Regrouping: each version's new package key is (derivedNamespace, package.name).
##     Versions previously sharing a bare-name package that now derive distinct
##     namespaces are split into separate Package entries.  This is correct and
##     expected (the known case is `nimkdl`: greenm01 git vs coreyleavitt OCI).
##   - Output is canonicalized (packages sorted by (namespace, name); versions
##     descending semver; requires-keys alphabetical) before ok(...).
##
## `mhkUnexpectedSplit` is defined for type completeness (see module docstring
## for reachability reasoning) but has no reachable trigger given clean
## per-version derivation — every clean derivation produces a valid regrouping.

import std/[tables, sequtils]
import nkdl
import ./model
import ./namespace

export nkdl

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  MigrationHaltKind* = enum
    mhkDerivationFailed   ## deriveVersionNamespace returned err for a version
    mhkUnexpectedSplit    ## structural impossibility (no reachable trigger in
                          ## current model — kept for type completeness)

  MigrationHalt* = object
    case kind*: MigrationHaltKind
    of mhkDerivationFailed:
      packageName*:   string
      version*:       string
      provenanceUrl*: string
      error*:         DerivationError
    of mhkUnexpectedSplit:
      splits*: seq[tuple[name: string,
                         namespaces: seq[string],
                         sources: seq[tuple[version: string, provenanceUrl: string]]]]

# ---------------------------------------------------------------------------
# Implementation
# ---------------------------------------------------------------------------

proc firstGitUrl(v: Version): string =
  ## Extract the first pkGit provenance URL for diagnostic messages, or "".
  for p in v.provenances:
    if p.kind == pkGit:
      return p.url
  ""

proc migrateIndex*(idx: Index): Result[Index, MigrationHalt] =
  ## Derive a canonical `host/org` namespace for every version in `idx`,
  ## regroup packages by `(derivedNamespace, package.name)`, and return
  ## `canonicalize(result)`.  On any derivation failure → `err(MigrationHalt)`.
  ##
  ## Pure function — no I/O, no subprocess.

  # Key: (namespace, name) → (Package metadata from first version seen, collected versions)
  # We use ordered tables to keep deterministic iteration order before canonicalize.
  var pkgMeta = initOrderedTable[(string, string), Package]()
  var pkgVersions = initOrderedTable[(string, string), seq[Version]]()

  for pkg in idx.packages:
    for v in pkg.versions:
      let nsResult = deriveVersionNamespace(v)
      if nsResult.isErr:
        return err[Index, MigrationHalt](MigrationHalt(
          kind:         mhkDerivationFailed,
          packageName:  pkg.name,
          version:      v.version,
          provenanceUrl: firstGitUrl(v),
          error:        nsResult.getErr,
        ))

      let ns = nsResult.get
      let key = (ns, pkg.name)

      if key notin pkgMeta:
        # First time we see this (namespace, name) pair — seed the package record.
        # `upstream` from the source package; namespace from derivation.
        pkgMeta[key] = Package(
          name:      pkg.name,
          namespace: ns,
          upstream:  pkg.upstream,
          versions:  @[],
        )
        pkgVersions[key] = @[]

      pkgVersions[key].add(v)

  # Assemble final packages.
  var packages: seq[Package] = @[]
  for key, meta in pkgMeta.pairs:
    var p = meta
    p.versions = pkgVersions[key]
    packages.add(p)

  ok[Index, MigrationHalt](canonicalize(Index(
    schemaVersion: idx.schemaVersion,
    packages:      packages,
  )))
