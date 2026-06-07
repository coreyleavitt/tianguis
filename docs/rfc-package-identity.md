# RFC: Package identity = `(namespace, name)` (DRAFT)

Status: **draft** — design resolved in the 2026-06-06 grill session; slices below.
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

### Resolved commitments (grill 2026-06-06)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Namespaced identity, not flat | No central curator (vendor-en-absentia); flat silently merges (#32) |
| 2 | `namespace` includes forge **host** — `(host/org, name)` | `github.com/x` ≠ `gitlab.com/x`; host-less reintroduces a cross-forge collision class |
| 3 | `namespace` = the **attested publisher identity**, *derived from provenance* | Author-signed → OIDC org; vendored → forge org from URL. No separate claiming authority (consistent with no-curation) |
| 4 | **No bare-name ownership** — fully qualified always, in index + manifests | Go model. Kills the alias table, the "who owns `chronos`" authority, and TOFU claiming entirely |
| 5 | bare→qualified is a **one-way vendor-bot ingest mechanic** over `packages.json` | The legacy ecosystem speaks bare; the bot resolves `name→URL→(host/org,name)` once at ingest and persists only qualified edges. `packages.json` becomes a bare→URL *lookup*, not a namespace authority |
| 6 | Interop is **one-way**: milpa consumes legacy; **no reverse shim** | nimble can't name tianguis-native packages; we don't build that. Want nimble reach → register in `packages.json` (join the legacy world) |
| 7 | The bare-name world is **closed over `packages.json`** | Only legacy `.nimble`s emit bare requires, and they can only reference other `packages.json` names (or URL-requires that self-qualify) ⇒ every bare edge resolves at ingest by construction. A bare require absent from `packages.json` = an upstream package that wouldn't install under nimble either → vendoring skip, not our problem |

## Identity model

- **Key:** `(namespace, name)`, `namespace = "<host>/<org>"` (e.g. `github.com/coreyleavitt`).
- **Derivation (no claiming step):**
  - *vendor-en-absentia (git):* parse the canonical `upstream` URL → `host/org`.
  - *author-signed (OCI/dispatch):* the Sigstore/OIDC identity (GH org) → `host/org`
    = `github.com/<org>`, **independent of where the OCI bytes live** (the OCI
    registry/digest is *provenance*, not identity — preserves identity-vs-provenance).
- **No bare names anywhere a consumer or resolver can see them.** `milpa.kdl` and the
  index are 100% qualified. Bare names exist only inside legacy `.nimble` source the
  bot reads, resolved at the ingest membrane and never persisted.

## Index schema change

Current (`docs/spec/index-format.md`):

```kdl
package "AccurateSums" {
    namespace ""
    upstream (url)"https://gitlab.com/lbartoletti/accuratesums"
    version "…" { content_hash "…"; provenance { … }; … }
}
```

`namespace` already exists as a field but is empty and **not part of the key**. This
RFC promotes `(namespace, name)` to *the* key:

- `namespace` is populated (derived per the rules above), never `""` for a real entry.
- Lookups, dedup, and dep-edge references (`rfc-index-deps.md`) key on the tuple.
- Schema version bump. (Open: bundle with the `rfc-index-deps` bump as one v2
  migration, or separate — see that RFC.)

## Vendor bot

- Derive `(host/org, name)` for every entry from its `upstream` URL.
- At ingest, resolve each upstream `.nimble`'s bare/`URL` requires to qualified edges:
  bare → `packages.json` name→URL→`(host/org,name)`; URL-require → self-qualify from
  the URL. (Edge persistence is `rfc-index-deps.md`; the *resolution* is here.)
- Collision is no longer a merge: `github.com/greenm01/nimkdl` and
  `github.com/coreyleavitt/nimkdl` become two distinct entries.
- Unresolvable bare require (absent from `packages.json`) → skip/flag the package
  (upstream bug; un-vendorable coherently).

## Consumer contract (milpa) — determined here, implemented under a milpa RFC

These follow from the identity decision and are **fixed**, but their *implementation*
is milpa-side (separate milpa RFC; sequenced after this lands):

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
  | Qualified reference (merged named+url), default | registry attestation + `content_hash` | strongest, automatic |
  | …pinned to an index-known target | the matched index entry | strong |
  | …pinned to an unattested ref | none → opt-in **+** lockfile `unverified` mark | weak, deliberate |
  | Tarball | user `sha256` | strong, self-declared |
  | …tarball with no sha (pure TOFU) | none → same opt-in + mark | weak, deliberate |
  | Local | possession | first-party, gate-exempt |

  - **Merge `NamedDep` + `UrlDep`** into one qualified-reference kind (identity = index
    key = locator, Go-style). Trust is a *computed property of each resolution* (does
    the resolved target carry attestation?), not a manifest kind. This also fixes a
    latent **under**-trust in the old two-kinds model (a `UrlDep` at an attested
    release was fetched raw, unverified).
  - **Anchorless fetch handler (the generic "left the trusted path" case):** require
    explicit opt-in **and** record `unverified` in the lockfile — reused for both an
    unattested git pin and an anchorless tarball. (Consistent with the #97 H1
    empty-`content_hash` hard-error + #103.)
  - **`local` stays distinct** (possession-trust: editable / self-vendored;
    `cas_admissible=False`, gate-exempt). **`tarball` stays distinct** (different
    transport; `sha256` anchor, not registry attestation).

## Non-goals

- Making two same-module packages co-importable in one build (impossible under flat
  Nim imports + interop; permanent detect-and-error).
- A name-claiming / uniqueness authority (deliberately none).
- The dep-edge *schema* — that's `rfc-index-deps.md` (this RFC only settles the
  identity that edges reference).
- milpa's manifest/dep-kind *implementation* — separate milpa RFC.

## Open questions

- Exact `host/org` normalization: case, trailing `.git`, `www.`/host aliases, SSH vs
  HTTPS URL forms, redirects (e.g. nimkdl→nkdl) — canonicalization rules for the
  derivation so two spellings of the same repo don't split identity.
- Schema-version bump: one combined v2 migration with `rfc-index-deps`, or staged.
- OIDC→`host/org` mapping precision for author-signed (org vs user; enterprise hosts).
- Does the index record the exposed Nim module name(s) per package so milpa can detect
  module collisions *pre-fetch*? (milpa-side optimization; cross-cuts index-deps.)

## Slices (tianguis-scoped; gate = green each)

- **S1 — identity key + derivation.** `(namespace, name)` as the key in the parse/
  build model; pure `deriveNamespace(url) -> host/org` with canonicalization (Open-Q
  rules); unit tests incl. the greenm01-vs-coreyleavitt nimkdl pair as distinct.
- **S2 — `docs/spec/index-format.md`** updated: namespace populated + part of the key;
  examples; schema-version note.
- **S3 — kdl_io** parse/encode of the populated `namespace` + tuple-keyed lookup;
  round-trip + strict-membership tests.
- **S4 — vendor bot derivation:** stamp `(host/org, name)` from `upstream`; collision
  case produces two entries (regression for #32).
- **S5 — vendor bot bare→qualified require resolution** at ingest over `packages.json`
  (bare → map; URL-require → self-qualify; absent → skip/flag). (Edge *persistence*
  defers to `rfc-index-deps`; this is the resolver step + tests.)
- **S6 — migration:** re-emit the live ~2613-pkg index with derived namespaces;
  validate (no `namespace ""`; collision count; spot-check known pairs); milpa still
  parses. Byte/own-format diff as the gate.

Milpa-side slices (consume qualified identity, merged dep kind, detect-and-error,
trust-anchor + b/c surfacing) are a **separate milpa RFC**, sequenced after S1–S6 and
after `rfc-index-deps`.
