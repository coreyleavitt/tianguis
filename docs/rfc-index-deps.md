# RFC: Per-version dependency metadata in the tianguis index (DRAFT)

Status: **draft — to be fleshed out.** Seeded 2026-06-06.
Depends on: **#32** (identity = `(namespace, name)`) — dependency edges reference
packages by identity, so the identity model must be settled first.
Consumer impact: milpa (resolver). Milestone: registry — tianguis.

## Summary

Record each package version's **dependency edges** directly in the index, the way
the crates.io index and PyPI metadata do. Today the tianguis index carries
identity + provenance + version-set but **no graph edges** — a deliberate early
decision (milpa RFC: "index supplies identity/provenance/version-set, NOT graph
edges; transitives come from parsing each fetched dep's manifest"). That decision
forces the *consumer* to fetch and unpack a package's full source tree just to
learn what it depends on, which is the root cause of a class of resolver problems.
Moving dep metadata into the index lets a resolver answer "what does version X
need?" cheaply, without a fetch — which is how every best-in-class resolver works.

## Motivation

### The consumer is starving its own solver (milpa#100)

milpa already runs PubGrub, which natively accumulates constraints (the running
intersection of every term touching a package) and backtracks. But because the
index has no edges, milpa must **fetch a version to discover its requires**, so it
collapses each named dep to a single eagerly-chosen version *before* the solver
runs — and in doing so silently drops competing constraints (milpa#100: a diamond
where two dependents require the same package under different constraints resolves
to whichever constraint arrived first; the conflict later surfaces as an opaque
"no version satisfies"). The bug is not in PubGrub; it's in the eager
pre-resolution layer that exists *only because deps aren't in the index*.

### How the best-in-class resolvers avoid this

- **Cargo**: the crates.io index is a per-version list of
  `{name, version, dependencies[]}`. Cargo resolves the *entire* graph without
  fetching a single crate — all edges live in the index.
- **uv / pip (PEP 658)**: `get_dependencies(package, version)` is answered by a
  cheap per-version metadata fetch (the `.metadata` endpoint / a range request for
  the wheel `METADATA`), never the artifact; PubGrub owns version selection.

In both, dependency metadata is **cheap and lazy**, so the solver — not an eager
front layer — drives selection. Putting edges in the tianguis index gives milpa
the same property: the provider answers `get_dependencies` from the index, the
eager layer is retired, and milpa#100 dissolves (with proper backtracking + good
conflict diagnostics for free).

## Current schema (for reference)

A version block today (`docs/spec/index-format.md`):

```kdl
package "AccurateSums" {
    namespace ""
    upstream (url)"https://gitlab.com/lbartoletti/accuratesums"
    version "0.0.0+commit-warning" {
        content_hash "sha256:…"
        provenance { kind "git"; url (url)"…"; ref "HEAD"; commit_sha "…" }
        attestation "milpa-vendored"
        signed_by "…"
        published_at "2026-05-26T08:11:36Z"
    }
}
```

Note: `published_at` already exists per version (this is what milpa#86
`exclude-newer` needs), and `namespace` already exists as a field (#32 promotes it
into identity). The only missing piece is the dependency list.

## Proposed schema (sketch — to be settled)

Add a `requires` block per version, each edge referencing a package by its
**#32 identity** plus a version constraint:

```kdl
version "0.28.0" {
    content_hash "sha256:…"
    provenance { … }
    requires {
        dep namespace="status-im" name="results"  constraint=">= 0.5.0"
        dep namespace="status-im" name="stew"      constraint=">= 0.1.0"
        // url/local/tarball deps that aren't index packages: TBD (see open qs)
    }
    published_at "…"
}
```

Shape is illustrative. The binding commitments are: (1) one edge per dependency,
(2) each edge cites a package by the settled `(namespace, name)` identity, (3) a
version constraint string in milpa's constraint grammar.

## Consumer change (milpa)

- `_MaterializedProvider` / the PubGrub `DependencyProvider` answers
  `get_dependencies(name, version)` from the index `requires` block — no fetch.
- The eager named-dep pre-resolution layer in `resolver.py` (the `seen_named`
  single-version collapse) is **retired**; PubGrub selects versions natively.
- Source is fetched only for the *resolved* set, at materialization time (for the
  content-hash identity gate + nim.cfg paths) — not to discover edges.
- milpa#100 is resolved by construction; milpa α RFC (`rfc-index-version-selection`)
  covers the resolver-side design (strategy #98, exclude-newer #86 ride the same
  provider).

## Open questions (flesh out)

- **Constraint grammar**: what exactly does `constraint=` accept? (milpa's
  `VersionSet`/`parse_version` grammar; align with #27 richer constraints.)
- **Where do edges come from on the vendor-en-absentia path?** The vendor bot must
  extract `requires` from each upstream tag's `.nimble` (line-form, no nimscript
  eval) — and `.nimble` `when` blocks are conditional (milpa includes them
  unconditionally today). How are conditional/optional deps represented?
- **Non-index deps**: a package can depend on a raw git URL / tarball / local
  path, not an index package. Does the index record those edges too (with
  provenance inline), or only index-package edges?
- **Transitive completeness / trust**: edges are attacker-influenceable metadata
  like everything else in the index — they ride the same attestation
  (rfc-registry / milpa#103). Does milpa re-verify edges against the fetched
  `.nimble` of the resolved set (defense-in-depth), or trust the index?
- **Identity drift**: if a `.nimble` names a dep by bare name, how does the vendor
  bot resolve it to a `(namespace, name)` identity? (collision risk — the #32
  problem recursively.)
- **Schema versioning**: ship with #32 as one `schema_version` bump (one index
  re-emit, one milpa consumer update), or a separate bump?

## Non-goals

- milpa's resolver-side version-selection *policy* (strategy, exclude-newer,
  backtracking ergonomics) — that's milpa's α RFC; this RFC only supplies the data.
- Changing the identity model — that's #32, a hard dependency of this RFC.
