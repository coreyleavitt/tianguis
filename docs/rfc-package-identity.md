# RFC: Package identity = `(namespace, name)` (DRAFT)

Status: **draft** — design resolved in the 2026-06-06 grill session; hardened by
architecture review rounds 1 **and 2** (2026-06-06). Slices below.
Issue: **#32** (P0). Prerequisite for: `docs/rfc-index-deps.md` (dep edges reference
package identity, so identity must be settled first). Consumer: milpa.
Milestone: registry — tianguis.

## Problem

Identity is currently the bare leaf `name`. The first real vendor-en-absentia pass
collided: the bot ingested `nimkdl` (greenm01's, `github.com/greenm01/nimkdl`) while
an author-signed `coreyleavitt/nimkdl` (OCI-published) already existed. With
name-only identity the two **silently merged** into one incoherent entry. For a
supply-chain tool that means *serving one project's code under the name that
resolves to another's* — not a quirk, a vulnerability.

## Why namespacing (and why flat is wrong *for tianguis*)

Package ecosystems split into two camps:

- **Flat global namespace** (crates.io, PyPI, RubyGems, npm-unscoped): the leaf name
  is globally unique, first-come-first-served — which **requires a central authority**
  to enforce uniqueness and adjudicate disputes.
- **Namespaced / path-as-identity** (Go modules, Maven `groupId:artifactId`, OCI
  `ns/name`, npm scopes): no global leaf uniqueness; identity carries an owner.

tianguis is in the second camp **by construction**: its thesis (`rfc-registry.md`,
#85) is *no human merges — vendor-en-absentia + author-signed, attestation is the
only gatekeeper*. A flat namespace is **incompatible** with that: two independent
sources (the `packages.json` bot and author publishes) *will* collide on a leaf with
no curator to adjudicate. The #32 collision is the proof. So for tianguis,
namespaced identity isn't the deviation — **flat is**.

## Decision

**Identity = `(namespace, name)` where `namespace` includes the forge host:
`(host/org, name)`.** Go-style. Examples: `(github.com/greenm01, nimkdl)`,
`(github.com/coreyleavitt, nimkdl)` — distinct packages that share a leaf.

`namespace` is a **single canonical string** of the form `<host>/<org>` (see the
normative canonicalization section below). `name` is the leaf name the `.nimble`
declares (the module name a consumer imports).

### Resolved commitments (grill 2026-06-06)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Namespaced identity, not flat | No central curator (vendor-en-absentia); flat silently merges (#32) |
| 2 | `namespace` includes forge **host** — `(host/org, name)` | `github.com/x` ≠ `gitlab.com/x`; host-less reintroduces a cross-forge collision class |
| 3 | `namespace` = the **attested publisher identity**, *derived from provenance* | Author-signed → OIDC org; vendored → forge org from the version's git provenance. No separate claiming authority (consistent with no-curation) |
| 4 | **No bare-name ownership** — fully qualified always, in index + manifests | Go model. Kills the alias table, the "who owns `chronos`" authority, and TOFU claiming entirely |
| 5 | bare→qualified is a **one-way vendor-bot ingest mechanic** over `packages.json` | The legacy ecosystem speaks bare; the bot resolves `name→URL→(host/org,name)` once at ingest and persists only qualified edges. `packages.json` becomes a bare→URL *lookup*, not a namespace authority |
| 6 | Interop is **one-way**: milpa consumes legacy; **no reverse shim** | nimble can't name tianguis-native packages; we don't build that. Want nimble reach → register in `packages.json` (join the legacy world) |
| 7 | The bare-name world is **resolved over `packages.json` on a best-effort basis** | Legacy `.nimble`s emit bare requires; the bot *attempts* to resolve each against `packages.json` (or self-qualify a URL-require) at ingest. Resolution is best-effort, not a closure guarantee — see commitment #8 |
| 8 | **Identity is immutable once recorded** | `(namespace, name)` is the dep-edge reference key (`rfc-index-deps`); a moving key breaks every recorded edge. Provenance (the git URL / OCI digest) is mutable; the derived identity is pinned at first-ingest and never rewritten — see "Identity stability" |

## Identity model

- **Key:** `(namespace, name)`, `namespace = "<host>/<org>"` (e.g. `github.com/coreyleavitt`).
- **Derivation anchor = the version's own provenance** (not the informational
  top-level `upstream` field — see below):
  - *vendor-en-absentia (git):* canonicalize the version's **git `provenance.url`** →
    `host/org`.
  - *author-signed (OCI/dispatch):* the Sigstore/OIDC identity (GH org) → `host/org`
    = `github.com/<org>`, **independent of where the OCI bytes live** (the OCI
    registry/digest is *provenance*, not identity — preserves identity-vs-provenance).
- **`upstream` is informational, not identity-bearing.** The top-level `upstream`
  field is a human-reference/source link; it *should* agree with the derived
  namespace but the derivation **never reads it**. (Using `upstream` as the anchor was
  a category error: a fork that points `upstream` at its canonical source while
  publishing under the forker's own org would mis-derive — see OIDC section.)
- **No bare names anywhere a consumer or resolver can see them.** `milpa.kdl` and the
  index are 100% qualified. Bare names exist only inside legacy `.nimble` source the
  bot reads, resolved at the ingest membrane and never persisted.

### Namespace canonicalization (NORMATIVE)

Canonicalization is the **identity equality function**, not an implementation detail:
two spellings of the same repo MUST canonicalize to the same `host/org`, and two
different repos MUST NOT collapse to one. Because this algorithm runs in **three
places** — the tianguis vendor bot (Nim), the tianguis author-signed path (Nim), and
milpa's consumer (Python) — it is specified as a **structured parse → normalize →
serialize** over a typed value, not as a sequence of string edits. A procedural
string-mangling spec replicated across three languages diverges on the first input
nobody wrote a test for; a structured function plus a shared conformance corpus (S2)
makes the three correct *by construction*. The canonical statement lives in
`docs/spec/index-format.md` (S2); this section is its normative definition and
rationale (single-source-of-truth obligation, milpa CLAUDE.md).

```
ForgeRef = (host: string, org: string)        # repo segment is parsed then discarded
deriveNamespace(raw) -> Result[ForgeRef, DerivationError]
```

**1. Parse** `raw` into `(scheme?, userinfo?, host, port?, pathSegments[])`:

- Accept `https://`, `http://`, `git://`, `ssh://`, and the scheme-less SSH short
  form `git@host:org/repo`.
- After stripping any scheme, **if the remainder begins with `userinfo@` (e.g.
  `git@`), drop the userinfo.** This is the fix for `ssh://git@host/org/repo`, whose
  `git@` survives scheme-stripping and would otherwise contaminate the host.
- The SSH short form `git@host:org/repo` parses `host` from before the colon and the
  path from after it.
- Drop any `:port`, `?query`, and `#fragment`.
- **Percent-decode** each path segment (not the host).

**2. Normalize** the parsed fields:

- **Host:** strip a leading `www.`; lowercase; strip a trailing `.`. **IDN/punycode
  hosts are used as-is** (transcoding is out of scope — documented).
- **Path:** drop empty segments (this collapses repeated slashes); strip a trailing
  `.git` from the final segment.
- **Org / repo split** per the forge-topology table below.
- **Case-folding of the `org` segment is per-forge** (table): forges documented as
  case-*insensitive* on owner names fold the org to lowercase; case-*preserving*
  forges keep the org verbatim. Lowercasing the *host* is always safe.

**3. Forge topology** — host → how many leading path segments form `org`, and the
owner-case policy:

| Host | Org segments | Owner case |
|---|---|---|
| `github.com` | 1 | fold (case-insensitive owners) |
| `gitlab.com` | 1 (see nested-group rule) | fold |
| `bitbucket.org` | 1 | fold |
| `codeberg.org` | 1 | **preserve** (Gitea — case-sensitive owners) |
| `git.sr.ht` | 1 (`~user`) | **preserve** (case-sensitive) |
| *any other host* (fallback) | 1 | **preserve** (unknown semantics → safest) |

- **GitLab nested groups** (`gitlab.com/group/subgroup/project`) would make the
  publisher a multi-segment path, breaking the two-segment `host/org` model and
  causing a false-merge if the subgroup were dropped. For now a GitLab URL with path
  depth > 2 is a **`DerivationError` (rejected at ingest, fail-loud)**, never a silent
  mis-derivation. First-class nested-group namespaces are filed as **#37** (purely
  additive — currently-rejected URLs later become accepted, so it does not break
  pinned identities). Depth-2 GitLab URLs derive normally.

**4. Serialize:** `namespace = host & "/" & org`. A parse that yields **no `org`
segment** (bare host, or a path that cannot be split into `host/org`) is a
`DerivationError` → the entry is rejected at ingest with a stable error code; it is
**never** stored as `namespace ""`.

**Forge-list evolution is constrained.** A host may be added to the topology table
**only if** it produces byte-identical output to the fallback for every URL of its
form. A forge needing a *different* rule (different org-segment count or case policy)
is a **breaking change to the identity function** — it requires a spec-version bump
and a migration (same class as S6), because entries already ingested from that host
were derived under the old rule and immutability (commitment #8) forbids silently
re-deriving them.

> Live-index note: the current `namespaceOf()` in `vendor/merge.nim` only handles
> `github.com` and emits `""` for 101 real non-GitHub entries (gitlab 32, sr.ht 30,
> codeberg 28, bitbucket 3) plus 3 malformed GitHub URLs (`www.`, double-slash).
> S1 replaces it with the function above; S6 must drive every entry to a non-empty
> `host/org` (after the URL audit — see S6).

### Granularity: why `host/org`, not `host/org/repo`

`namespace` is the **publisher identity** (commitment #3), so it stops at `host/org`;
the repo segment is discarded. This matches the attested-publisher model: a GH org's
OIDC identity, or the org that owns a vendored repo, is the trust boundary. It does
**not** go to `host/org/repo` (which would make identity the full repo path and make
`name` redundant with `repo`).

Consequence — **intra-org leaf collision is possible**: two repos under one org whose
`.nimble`s both declare `name = "utils"` derive to the *same* `(host/org, "utils")`.
This is rare (and on the vendor path `packages.json` already enforces global leaf
uniqueness, so it can only arise among author-signed packages an org publishes
itself). It is handled by **detect-and-reject at ingest** (see Vendor bot), never a
silent merge. We accept this bounded, detectable case rather than inflate identity to
the full repo path.

### Identity stability (immutability)

`(namespace, name)` is **immutable once recorded** (commitment #8):

- The `namespace` is derived **at first ingest** from that version's provenance anchor
  and persisted. A later change to the provenance (repo rename, org migration, forge
  move) is a **provenance** change; it does **not** rewrite the recorded identity.
- **Re-derivation is forbidden as an identity source after migration.** Once the S6
  migration has stored a `host/org` identity for an entry, any consumer or tool MUST
  treat the *stored* `(namespace, name)` as authoritative. Re-deriving identity from
  the *current* provenance after that point is incorrect — a moved repo would silently
  re-identify the package. (During S6 itself, re-derivation via `deriveVersionNamespace`
  is exactly the correct operation: the pre-#32 org-only and empty stored values are not
  valid `host/org` identities and are replaced, not preserved. Immutability binds to the
  post-migration `host/org` values, not to the pre-#32 forms.)
- **Code-level enforcement (the immutability guard).** On re-ingest of an
  already-present package, the vendor bot MUST assert that the freshly-derived
  namespace **equals** the stored namespace and raise a **distinct drift error**
  (separate from the content-hash `DriftAlert`) on disagreement — it must never
  silently overwrite the stored identity. Without this guard, immutability is prose,
  not an invariant (S1/S4 scope; see Slices).
- A repo rename (e.g. `nimkdl` → `nkdl`) or org migration therefore produces a *new*
  identity for new ingests while the old identity keeps all its historical versions
  and existing lockfile/dep-edge references remain valid. The two are distinct entries
  for what is socially "the same" software; **no automatic unification** is performed.
- Cross-identity unification after a rename (an alias/supersede mechanism) is **out of
  scope** here and is filed as a follow-up curation issue (tianguis **#36**). Until
  then, renames are an accepted, documented consequence — not silent corruption.

### Author-signed derivation precision (OIDC)

The author-signed path derives `host/org` from the **GitHub Actions OIDC claim**.
Normative points:

- Use the OIDC `repository_owner` claim (the org/user that owns the workflow repo) to
  form `github.com/<owner>`. The `sub`/`repository` claims bind to a *specific repo*;
  we deliberately take only the owner because `namespace` is org-granular.
- **Trust-boundary note:** because we take the owner, *any* principal with workflow
  write access to *any* repo under that org can produce a token that derives that
  org's namespace. This is the deliberate org-as-trust-boundary choice (commitment
  #3); the org admin controls who has that access. Finer (per-repo) attestation is
  not in scope.
- **Per-package pinning + narrow cross-path check.** Namespace is pinned per
  *package* at first ingest from that version's anchor. The cross-path agreement rule
  fires **only when a single version carries both a git `provenance.url` and an OIDC
  attestation** (one artifact, two attestations): the URL-derived `host/org` and the
  OIDC-derived `host/org` MUST then match, or it is an ingest validation failure. This
  guards a single artifact against path-dependent identity.
  > **Deferred — tianguis #39.** The cross-path git↔OIDC agreement check is not wired
  > in the current add-entry path: that path uses OCI provenance only, so no version
  > today carries both a git `provenance.url` and an OIDC attestation simultaneously.
  > Wiring the check before that combination is possible re-creates dead code. The
  > `checkOidcGitAgreement` implementation was removed from `namespace.nim` (2026-06-07)
  > and will be rebuilt when the both-provenance path exists (follow-on: #39).
- **Different publishers legitimately differ — that is the design, not an error.** A
  maintainer who forks `github.com/status-im/nim-chronos` and publishes author-signed
  builds under their own org derives `github.com/<their-org>`; that is a *distinct
  identity* (a separate package entry), exactly the namespaced-identity outcome. A new
  version whose anchor derives a namespace ≠ the package's pinned namespace is the
  signal it is a different publisher, never a trigger to merge. The earlier round-1
  rule (compare against the top-level `upstream`) was over-broad and is corrected
  here: `upstream` is informational, not the anchor.

### Identity vs content hash (orthogonality)

`(namespace, name)` is **identity**; `content_hash` is a separate, orthogonal field
(milpa non-negotiable). A `content_hash` **collision across two namespaces is a valid
state** — e.g. `(github.com/greenm01, nimkdl)` and `(github.com/coreyleavitt, nimkdl)`
with byte-identical source (a clean fork) legitimately share a hash. Identity is
*never* derived from or deduped by `content_hash`; milpa's content-addressed Phase-B
dedup keys on the hash for storage, but two distinct identities pointing at one hashed
blob is expected, not an error.

## Index schema change

Current (`docs/spec/index-format.md`) is still pre-#32 and MUST be migrated by S2:

```kdl
package "chronos" {
    namespace "coreyleavitt"          // org-only — STALE, pre-#32
    upstream (url)"https://github.com/coreyleavitt/chronos"
    version "0.5.0" {
        content_hash "…"
        requires { "results" "^0.5.0" }   // bare-name keys — STALE, pre-#32
        provenance { … }
    }
}
```

This RFC promotes `(namespace, name)` to *the* key and brings the spec into line:

- `namespace` is **populated as `host/org`** (e.g. `github.com/coreyleavitt`), derived
  per the canonicalization rules, never `""` and never org-only for a real entry.
- The data-model gloss changes from "OCI / GitHub namespace that owns the name" to
  "attested publisher identity (`host/org`), derived from provenance; part of the
  identity key."
- Lookups, dedup, and dep-edge references (`rfc-index-deps.md`) key on the **tuple**.
- **Canonical ordering** is by `(namespace, name)` — namespace first, then name within
  a namespace (so a same-leaf collision pair has a deterministic, stable order). This
  is normative; S1 implements it in `canonicalize`.
- No schema-version bump pre-v1 — the index format is still unstable; entries are
  re-emitted in place by the migration (S6) without a version negotiation.

**Transitional mixed-key state (post-S6, pre-`rfc-index-deps`).** This RFC migrates
package-node `namespace` to `host/org` but the **`requires` keys remain bare** until
`rfc-index-deps` re-encodes them (qualified-edge encoding is that RFC's scope, not
this one). So between S6 and `rfc-index-deps` the index is intentionally mixed:
qualified identities, bare `requires` keys. A consumer (milpa) reading this state MUST
**treat `requires` keys as bare** (resolve them via the legacy path) and MUST NOT
misinterpret them as qualified. `rfc-index-deps` carries the invariant that bare
`requires` keys reach zero.

## Vendor bot

- Derive `(host/org, name)` for every entry by canonicalizing its **version git
  `provenance.url`** (the `upstream` field is informational, not the anchor).
- **Immutability guard:** on re-ingest of an existing package, assert the re-derived
  namespace equals the stored one; raise a distinct drift error on disagreement; never
  overwrite the stored identity (see "Identity stability").
- **Collision handling at ingest:**
  - Different `(host/org)` for the same leaf → **two distinct entries** (the #32 fix):
    `github.com/greenm01/nimkdl` and `github.com/coreyleavitt/nimkdl` no longer merge.
  - Same `(host/org, name)` from two different repos (intra-org leaf collision) →
    **detect-and-reject the *new* entry; the existing (first-ingested) entry is
    preserved**, never removed (it may already be referenced by lockfiles — consistent
    with immutability). Record a stable `IDX-INTRAORG-COLLISION` code in the ingest
    log; never a silent merge.
- **Missing provenance is a hard reject at ingest.** An entry whose version has no
  resolvable provenance anchor (neither git `provenance.url` nor an OIDC attestation)
  cannot derive an identity and is rejected — so a conformant index never contains a
  provenance-less entry (this closes the trust-table gap below).
- **Denylist keys on the qualified `(namespace, name)`**, not the bare leaf, so a
  denylist entry blocks one publisher's package rather than every same-leaf package.
  (`vendor/denylist.nim` + `orchestrate.nim` are S4 scope.)
- At ingest, resolve each upstream `.nimble`'s bare/`URL` requires to qualified edges:
  bare → `packages.json` name→URL→`(host/org,name)`; URL-require → self-qualify from
  the URL. Edge *persistence* is `rfc-index-deps.md`; the *resolution mapping* is S5.
- **Unresolvable bare require** (absent from `packages.json`) → set an explicit
  `partially_resolved` flag on the version (a real field — see below); do **not**
  silently drop the edge. An upstream that depends on a non-`packages.json` bare name
  wouldn't install under nimble either. A resolver consuming a `partially_resolved`
  version it actually needs MUST **error** with a specific code, not treat the missing
  edge as "no dependency."

### Operability

Identity derivation must be inspectable, or an author whose submission is rejected has
no recourse:

- `tianguis show <upstream-url>` (or equivalent) MUST print the derived
  `(namespace, name)` for a URL, and the specific `DerivationError` code when
  derivation fails. (Gate on S4.)
- Every ingest rejection (derivation failure, intra-org collision, OIDC↔git
  disagreement, missing provenance) is logged with its stable error code and the
  offending URL so an author can self-diagnose.

## Consumer contract (milpa) — determined here, implemented under a milpa RFC

These follow from the identity decision and are **fixed**, but their *implementation*
is milpa-side (separate milpa RFC; sequenced after this lands). **Floor requirement
for that RFC:** a `milpa.kdl` `dep` node identifies a package by its `(namespace,
name)` identity (qualified, Go-style — e.g. a reference of the form
`github.com/status-im/results` plus a constraint); bare names MUST NOT reappear in the
manifest surface. The exact KDL spelling is the milpa RFC's to choose, but it may not
reintroduce bare-name identity.

- **Namespace is invisible to the Nim compiler and to package source.** Imports stay
  bare (`import nimkdl`); the namespace lives only in `milpa.kdl` / index / `nim.cfg`
  emission. This is permanent — interop with nimble/atlas forbids touching source.
- **Two packages exposing the same Nim *module* name cannot coexist in one build —
  detect-and-error, permanently.** A Nim-language flat-import limit, not a milpa one;
  "solving" it needs owning the whole build, which interop forbids. milpa's win is a
  precise diagnostic vs nimble's silent wrong pick.
- **Dep-kind taxonomy collapses to one trust axis — "what's your integrity anchor?"**

  | Dep concept | Anchor | Trust |
  |---|---|---|
  | Qualified reference (merged named+url), default | registry attestation + `content_hash` | strongest, automatic\* |
  | …pinned to an index-known target | the matched index entry | strong |
  | …pinned to an unattested ref | none → opt-in **+** lockfile `unverified` mark | weak, deliberate |
  | Tarball | user `sha256` | strong, self-declared |
  | …tarball with no sha (pure TOFU) | none → same opt-in + mark | weak, deliberate |
  | Local | possession | first-party, gate-exempt |

  > \* **Caveat:** the "registry attestation + `content_hash`" anchor is only as strong
  > as the **integrity of the index distribution channel**. If an attacker can mutate
  > the index in transit, they can rewrite the `content_hash` the attestation covers.
  > End-to-end index integrity (pinning / Sigstore transparency log for the index
  > itself) is deferred to **milpa#103** and is a prerequisite for the "strongest,
  > automatic" claim to hold. Until #103, this tier is "strong assuming a trusted
  > index channel."

  - **Row-selection is an algorithm the milpa RFC MUST specify**, not just a table:
    given a resolved target `T`, which row applies? (Sketch: `T` has an
    `attestation` + non-empty `content_hash` → row 1; `T` is an index entry → row 2;
    otherwise → row 3; tarball/local discriminated by dep-kind, not resolution
    outcome.) "Trust is a computed property of each resolution" is only well-defined
    once that procedure is pinned. (There is no "provenance-missing" row: the vendor
    bot hard-rejects provenance-less entries at ingest, so a conformant index cannot
    surface one to a consumer.)
  - **Namespace ≠ attestation on the vendor path.** For a vendored package the
    namespace names the forge org that owns the upstream repo — it does **not** mean
    that org attested the vendored bytes. Attestation is per-version (the `attestation`
    field); namespace is identity. (On the author-signed path the org *is* the
    attester; the distinction is real and worth stating so users don't read "same
    namespace" as "same attested origin" for vendored content.)
  - **Merge `NamedDep` + `UrlDep`** into one qualified-reference kind (identity = index
    key = locator, Go-style). Trust is a *computed property of each resolution* (per
    the row-selection algorithm above), not a manifest kind. This also fixes a latent
    **under**-trust in the old two-kinds model (a `UrlDep` at an attested release was
    fetched raw, unverified).
  - **Anchorless fetch handler (the generic "left the trusted path" case):** require
    explicit opt-in **and** record `unverified` in the lockfile — reused for both an
    unattested git pin and an anchorless tarball. (Consistent with the #97 H1
    empty-`content_hash` hard-error + #103.)
  - **`local` stays distinct** (possession-trust: editable / self-vendored;
    `cas_admissible=False` — content-hash verification is *not* applied, a local dep
    is explicitly outside the CAS model; gate-exempt). **`tarball` stays distinct**
    (different transport; `sha256` anchor, not registry attestation).

- **Lockfile / consumer migration — transition contract.** Existing `milpa.lock`
  files key deps by bare name and will not match the migrated `(namespace, name)`
  index. The milpa RFC MUST specify a **soft cutover** as the floor: a bare-name
  lockfile entry triggers a **WARN, not an error**, on `milpa verify` (clear
  diagnostic, never a silent miss), and `milpa lock` re-locks bare entries to their
  qualified identity in a single pass (idempotent thereafter — a second run is a
  no-op). A hard-error-on-stale-lock policy may be adopted at a later milestone but
  MUST be stated explicitly if so; it is not the default transition. This is
  consumer-migration scope, distinct from the index migration (S6).

## Non-goals

- Making two same-module packages co-importable in one build (impossible under flat
  Nim imports + interop; permanent detect-and-error).
- A name-claiming / uniqueness authority (deliberately none).
- Cross-identity unification after a repo/org rename (filed as #36; identity is
  immutable here).
- First-class GitLab nested-group (multi-segment) namespaces (filed as #37; depth > 2
  is a derivation failure for now).
- The dep-edge *schema* — that's `rfc-index-deps.md` (this RFC only settles the
  identity that edges reference).
- milpa's manifest/dep-kind *implementation* — separate milpa RFC (this RFC sets the
  no-bare-names floor it must honor).

## Open questions

- (Resolved 2026-06-06: **no schema versioning pre-v1** — the format is unstable;
  S6 re-emits entries in place. Revisit at v1 stabilization.)
- Cross-identity unification after a rename/org-move (alias / supersede mechanism):
  needs its own curation RFC — filed as tianguis **#36**.
- GitLab nested-group namespaces (multi-segment publishers) — filed as tianguis
  **#37** (rejected at ingest until then).
- Fork divergence: a fork (`github.com/coreyleavitt/chronos`) and its upstream
  (`github.com/status-im/nim-chronos`) are correctly *distinct* identities; confirm no
  cross-check is wanted (current design: none — they're different publishers).
- Monorepo / sub-path packages: a repo with multiple packages or a `.nimble` not at
  repo root — `(host/org, name)` still works (name disambiguates), but the derivation
  uses only the URL host/org and loses sub-path info. Confirm this is sufficient.
- `packages.json` as a de-facto namespace authority on the vendor path: an attacker
  who lands a malicious `packages.json` PR (mapping a popular bare name to a spoofed
  URL) controls the derived namespace for that name at ingest. This is a distinct,
  more accessible vector than OIDC impersonation and rides the same
  attestation/trust posture (rfc-registry, milpa#103); bound it explicitly there.
  **Minimal mitigation now (SHOULD):** the vendor bot records the `packages.json`
  commit SHA used for each ingest run (commit message or side-channel log), so a
  poisoning event is auditable even before #103 — zero-cost and non-breaking.
- Does the index record the exposed Nim module name(s) per package so milpa can detect
  module collisions *pre-fetch*? (milpa-side optimization; cross-cuts index-deps.)

## Slices (tianguis-scoped; gate = green each)

- **S1 — identity key + derivation (model-level, not just a pure fn).**
  - Pure `deriveNamespace(url) -> Result[ForgeRef, DerivationError]` implementing the
    **structured parse → normalize → serialize** above (all named forges + fallback +
    per-forge case policy + SSH-`git@`-residue + percent-decode + gitlab depth>2
    failure + no-org failure). Unit tests incl. the greenm01-vs-coreyleavitt nimkdl
    pair as distinct, plus the live-index edge cases (gitlab/sr.ht/codeberg/bitbucket,
    `www.`, double-slash, SSH short form **and** `ssh://git@…`, `~User` case-preserve,
    gitlab subgroup → failure).
  - **Promote `(namespace, name)` to the model identity — explicit call-outs (audited
    against the real code):**
    - `merge.nim` `mergeVendored` lookup (≈ line 82) keyed on the **tuple**
      `(p.namespace, p.name)`, not bare `p.name` — else the collision pair re-merges
      and S4 can't go green.
    - `model.nim` `canonicalize` sort key (≈ line 127) → `(namespace, name)` compound,
      not bare `name` — else S3 round-trip output is non-deterministic for the pair.
    - `DriftAlert` (≈ `merge.nim` line 18) carries the **qualified** identity, not bare
      name, so drift logs are unambiguous for same-leaf packages.
    - the **immutability guard** (re-derived == stored, distinct drift error).
- **S2 — `docs/spec/index-format.md`** updated: `namespace` populated as `host/org` +
  part of the key; the **structured canonicalization** transcribed (ForgeRef + the
  topology table + per-forge case policy, so the Python consumer is correct-by-spec);
  data-model gloss corrected; canonical `(namespace, name)` ordering stated; `requires`
  keys qualified-vs-bare transitional note; same-name-two-entries KDL shape.
  - **Conformance corpus (S2, load-bearing for the single-source-of-truth claim):**
    produce `spec/fixtures/derive-namespace.json` — `{input_url, expected_namespace |
    expected_error}` pairs covering every named forge, fallback, all failure modes,
    SSH (both forms), `www.`, double-slash, `~User` case, percent-encoding, gitlab
    subgroup, and the nimkdl pair. **Both** the Nim and Python test suites MUST import
    and run this fixture set (prose alone does not make three impls agree).
- **S3 — kdl_io** parse/encode of the populated `host/org` namespace + tuple-keyed
  lookup; round-trip + strict-membership tests **including two same-`name` packages**
  (different namespace) surviving parse/emit without collapse. *Depends on S1 (model
  tuple) and S2 (namespace format) — do not start before both.*
- **S4 — vendor bot derivation:** stamp `(host/org, name)` from the version git
  provenance URL; cross-forge collision → two entries (regression for #32);
  **intra-org leaf collision → detect-and-reject the new entry, preserve the existing**
  (regression test); **missing provenance → hard reject**; OIDC↔git agreement check
  when one version carries both; denylist keyed on the tuple; `tianguis show <url>`
  derivation-inspection surface (Operability).
- **S5 — vendor bot bare→qualified require *resolution*** at ingest over
  `packages.json` (bare → map; URL-require → self-qualify; absent → `partially_resolved`
  flag). **Scope: the pure resolution mapping + unit tests only — no model
  persistence.** The `requires`-edge encoding/persistence (and any `Version` field for
  it) is the **first slice of `rfc-index-deps`**, not this RFC; S5 must not leave a
  half-built persistence path. The `partially_resolved` flag *is* added to the model
  here (it gates resolver correctness independent of edge persistence).
- **milpa parse update (cross-repo sequencing gate, manual):** milpa's
  `tianguis_client.parse_index` (≈ line 376) keys `packages[name]` by bare name and
  would silently drop one of a collision pair. The milpa-side tuple-keyed parse update
  **MUST land before S6**, with a milpa regression test for the two-`nimkdl`-blocks
  fixture (returns 2 packages, not 1 — fixture string, no live index needed).
  Implemented under the milpa consumer RFC; called out here as a sequencing
  dependency. *Verification is manual and cross-repo* (run `uv run pytest` in the milpa
  repo against the migrated index) — it is **not** a tianguis-repo test command.
- **S6 — migration:** re-emit the live ~2613-pkg index with freshly derived `host/org`
  namespaces for **every entry** (derive-all-per-version + regroup).

  **Why derive-all, not preserve-non-empty.** The live audit established: all 2509
  non-empty namespaces are stale **org-only** forms (e.g. `nim-lang`, not
  `github.com/nim-lang`); 104 are empty. Not a single stored namespace is already a
  valid `host/org` #32 identity. There is therefore **nothing correct to preserve** — the
  org-only and empty forms are both pre-#32 states that S6 must derive fresh. Applying
  `deriveVersionNamespace` (the SSOT proc in `namespace.nim`) uniformly across all
  entries is the only way to satisfy gate-3 below; selectively preserving the org-only
  strings would leave 2509 invalid entries in place.

  **Immutability binds AFTER the migration, not before it.** Commitment #8
  ("immutable once recorded") applies to `host/org` identities produced by
  `deriveVersionNamespace` and stored in the migrated index. It does **not** bind to
  the pre-#32 org-only or empty strings — those are not valid #32 identities and were
  never pinned under the new rule. Post-migration, any tool that re-derives a namespace
  and finds it differs from the stored `host/org` is detecting a real drift violation
  and MUST raise the distinct drift error (see "Identity stability"). That invariant is
  meaningless before the migration stores the first correct values.

  **The nimkdl conflict is a deterministic per-version split, not a re-ingest.**
  The original merge conflated greenm01's git versions with coreyleavitt's OCI version
  under namespace `coreyleavitt`. The per-version derivation resolves this without
  re-ingest: each version's provenance anchor (`provenance.url` for git, `signed_by`
  OIDC SAN for author-signed OCI) derives the correct namespace independently:
    - greenm01 git versions → `github.com/greenm01` (from their `provenance.url`)
    - coreyleavitt OCI version → `github.com/coreyleavitt` (from its `signed_by` SAN)
  The result is two distinct `(namespace, name)` entries with no version data lost.
  No re-ingest. No manual repair.

  **Pre-flight audit (gates S6):** confirm every entry (all 2613) has a per-version
  provenance anchor sufficient to derive `host/org` via `deriveVersionNamespace`.
  Entries with no resolvable anchor (no git `provenance.url` and no author-signed
  `signed_by`) must be classified as drop / manual-patch before S6 proceeds; gate-2
  below cannot be met for such entries.

  Gate on **meaningful invariants** (a raw byte-diff is ~2613 lines and proves nothing):
    1. `tianguis project --check` passes (KDL↔JSON parity preserved).
    2. Zero `namespace ""` entries remain.
    3. Every namespace matches `^[a-z0-9.-]+/[a-zA-Z0-9_.~-]+$` (host/org form;
       `~`/`.`/uppercase admitted in the org for sr.ht/codeberg case-preserve and
       gitlab group names — case correctness is checked by the S2 conformance corpus,
       not this structural gate). **Zero org-only strings** (no entry of the form
       `nim-lang` without a host prefix).
    4. The nimkdl split appears as **two** distinct `package` blocks with different
       `namespace` (`github.com/greenm01` and `github.com/coreyleavitt`), achieved
       by per-version derivation without re-ingest.
    5. Count of distinct `(namespace, name)` tuples == count of `package` nodes (no
       silent merges).
    6. milpa `parse_index` on the new index drops **no** entry — *verified manually in
       the milpa repo* (requires the milpa parse update above to have landed); this is
       a blocker note, not a tianguis-repo gate command.

Milpa-side slices (consume qualified identity, merged dep kind, detect-and-error,
trust-anchor + row-selection + b/c surfacing, **lockfile migration soft-cutover
diagnostic**) are a **separate milpa RFC**, sequenced after S1–S6 and after
`rfc-index-deps` — except the `parse_index` tuple-key update, which is pulled forward
as the S6 sequencing gate above.
