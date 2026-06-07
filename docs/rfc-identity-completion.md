# RFC: package-identity completion (#32 finish-out)

> **⚠ SUPERSEDED (2026-06-07) by `milpa/docs/rfc-identity-and-resolution-completion.md`.**
> This RFC was architect-reviewed rounds 1+2; all its hardened content (audit facts, slices,
> SSOT proc, MergeAlert, MigrationHalt, the `checkOidcGitAgreement`-deletion resolution) is
> carried forward into the unified cross-repo RFC, which adds #38 (folded in, not split out)
> and the milpa resolver-core work, with one master ordering. Do not implement from this doc;
> use the successor. Kept for review provenance.

**Status:** SUPERSEDED (was: draft, rfc-flow stage 1 — sliced, architect rounds 1+2 done)
**Depends on / completes:** `docs/rfc-package-identity.md` (S1–S5 landed; this RFC
corrects + executes S6 and closes the spin-offs #37/#38)
**Spans:** tianguis (primary) + one narrow milpa prerequisite (`parse_index`)

---

## 1. Why this RFC exists

`rfc-package-identity.md` (#32) established identity = `(namespace, name)` with
`namespace = host/org` derived from a version's provenance. Slices **S1–S5 are
implemented and green** (18 Nim test files). What remains was *deferred*, not
designed-away, and now has to be finished:

1. **S6 (the live-index migration) is blocked on a wrong-spec escalation.** The RFC
   tells S6 to "preserve existing non-empty namespaces verbatim, derive only empties."
   A pre-flight audit of the live index proves that instruction is wrong (§3).
2. **Two pure mechanisms shipped as dead code.** `checkIdentityStable` (the
   immutability guard) and `checkOidcGitAgreement` were built in S1/S4 and are called
   by nothing. Immutability is currently *prose, not an invariant*.
3. **#38 (author-signed namespace) is a live identity-spoofing surface.**
   `addentry.nim` stamps `namespace` from an untrusted `--namespace` flag instead of
   deriving it from the verified OIDC signer.
4. **#37 (gitlab nested groups)** was filed as a deferral. The audit shows it is **not
   a migration blocker** — recorded here so it stays correctly out of scope.
5. **One cross-repo prerequisite:** milpa's `tianguis_client.parse_index` keys by bare
   name and would silently drop a collision pair; it must be tuple-keyed before S6's
   migrated index is verifiable end-to-end.

The milpa **consumer contract** (merged NamedDep/UrlDep, row-selection, lockfile
soft-cutover) remains a *separate milpa-repo RFC* per the #32 handoff. Only the narrow
`parse_index` gate is pulled into this RFC, because S6's final gate depends on it.

---

## 2. What is already done (do not re-touch)

| Slice | Landed artifact |
|---|---|
| S1 | `src/tianguis/namespace.nim` — `deriveNamespace -> Result[ForgeRef, DerivationError]` (structured parse→normalize→serialize; forges + case policy + SSH residue + percent-decode + gitlab-depth>2 fail + no-org fail). Model promoted to `(namespace,name)` (merge lookup, canonicalize sort, qualified `DriftAlert`). |
| S1/S4 | `checkIdentityStable`, `checkOidcGitAgreement` — pure, **delivered unwired**. This RFC wires `checkIdentityStable` (C2). `checkOidcGitAgreement` wiring is an **open escalation** (§6): its precondition — a version with both git + OIDC provenance — cannot exist on the current `pkOci`-only add-entry path, so wiring it now re-creates dead code; #38 closes without it. |
| S2 | `docs/spec/index-format.md` host/org model + `spec/fixtures/derive-namespace.json` (40-case cross-language corpus). |
| S3 | kdl_io host/org round-trip; the two-`nimkdl` pair survives parse→emit as two entries. |
| S4 | `buildVendoredEntry -> Result` (hard-reject underivable provenance); intra-org leaf collision → reject-new/preserve-existing; tuple-keyed denylist; `tianguis show <url>`. |
| S5 | `vendor/resolve.nim` pure bare→qualified require mapping; `Version.partiallyResolved`. |

---

## 3. The wrong-spec escalation (resolved here) — corrected S6

**Audit of the live `index.kdl` (2613 packages):**

- **All 2509 non-empty namespaces are stale *org-only*** (`nim-lang`, `status-im`, …) —
  **zero** are `host/org`. The RFC's "preserve verbatim" would leave 2509 entries
  failing gate #3 (`^[a-z0-9.-]+/…` requires a slash) as invalid, host-less #32
  identities. Immutability is meant to protect *valid #32* identities; **there are none
  yet** — every entry is a pre-#32 form (org-only or empty).
- **0 entries lack a derivable git provenance URL.** The RFC's "drop / manual-patch"
  pre-flight branch is moot; 2612/2613 migrate mechanically. 2508/2509 org-only values
  already equal the derived org (host-prepend is consistent and safe).
  *Audit precision: all 104 zero-namespace entries have a non-empty, structurally valid
  `pkGit` `provenance.url`; the zero-namespace was caused by the old `namespaceOf()`
  only handling `github.com`, not by an absent URL. All 2509 non-empty org-only entries
  have `github.com` provenance URLs, so `github.com/<stored_org>` is the correct
  migration output in every case. No version carries only OCI provenance without a
  derivable git URL or a `signed_by` OIDC SAN.*
- **The 1 mismatch is `nimkdl` — the #32 artifact.** The merged node conflates two
  projects: v2.1.0 (git `github.com/greenm01/nimkdl`, milpa-vendored) is greenm01's;
  v0.1.4 (OCI `ghcr.io/coreyleavitt/nimkdl`, author-signed) is coreyleavitt's; the node
  namespace `coreyleavitt` is wrong for v2.1.0. **The RFC over-stated the damage:**
  greenm01's version data survived intact (full `content_hash` + `commit_sha` on
  v2.1.0). **No `packages.json` re-ingest is needed** — the repair is a *deterministic
  per-version split by provenance*.
- **0 gitlab nested-group URLs** (all 64 gitlab refs are clean `gitlab.com/org/repo`),
  so `derive-all` rejects nothing → **#37 is not a blocker** and stays additive/future.

**Corrected S6 algorithm (replaces preserve-verbatim):**

> Migrate by **deriving `host/org` per *version* from that version's own attestation
> anchor, then regrouping versions by `(namespace, name)`.** The anchor is:
> - **vendored version** → the git `provenance.url`
>   (`github.com/greenm01/nimkdl` → `github.com/greenm01`)
> - **author-signed version** → the OIDC `signed_by` SAN
>   (`https://github.com/coreyleavitt/tianguis/.github/…` → `github.com/coreyleavitt`)
>
> Both anchors are git-forge URLs, so `deriveNamespace` handles them with **no new
> code** and there is **no namespace-less case**: the author-signed path is hardcoded
> to GitHub Actions keyless OIDC
> (`cosign verify --certificate-oidc-issuer=token.actions.githubusercontent.com`), so
> `signed_by` is always a `github.com/<owner>` identity. The informational `upstream`
> field is **never** an identity source. This uniformly upgrades all org-only/empty
> entries to `host/org` *and* splits `nimkdl` into two correct entries in one pass — no
> re-ingest, no fallback, no manual repair.

This is a one-time migration transform; **immutability binds post-migration** (org-only
and empty are pre-#32 forms the migration is *allowed* to derive, exactly once). If any
version fails to derive (audit says zero do), the migration **halts and escalates** —
it never silently drops a package.

**Migration implementation requirements:**
- **Atomic write:** the migration writes to a staging file and renames it over `index.kdl`
  only on all-gates-pass. A halt leaves `index.kdl` untouched — no partial writes.
- **Idempotent:** running the migration twice on an already-migrated index is a no-op
  (all gates pass, output is byte-identical to input). Gate: run twice, diff is empty.
- **Split diagnostic:** every split performed (versions regrouped across namespace
  boundaries) is logged as a named diagnostic. If any split beyond the known `nimkdl`
  case is discovered, the migration halts and reports all splits for operator review
  before committing. Unexpected splits indicate a prior silent merge requiring human
  triage, not mechanical correction.
- **C2 ordering guard:** the immutability guard (`checkIdentityStable`) fires only on
  stored namespaces that are already in `host/org` form (contain a `/`). A stored
  org-only namespace is a pre-migration form; re-deriving it during re-ingest before C3
  has run would produce a false identity-drift. The guard condition:
  `if '/' in stored_namespace: assert rederived == stored`. This prevents false-positives
  in the C2→C3 window regardless of landing order.

**Single source of truth — `deriveVersionNamespace` (SSOT for anchor-picking):**
The "pick the attestation anchor, then derive" rule is needed wherever a *version object*
must yield its identity: C2 re-ingest guard and C3 migration (both iterate versions whose
attestation kind is not statically known). It must NOT be reimplemented as a prose
`if vendored … else …` branch in each. It lands as **its own pre-slice C0** in
`namespace.nim` (so it exists before C2 *or* C3a — see §5 sequencing) and both call it:

```nim
proc deriveVersionNamespace*(v: Version): Result[ForgeRef, DerivationError] =
  ## The per-version identity anchor rule (SSOT). Picks the attestation anchor
  ## from the version's own provenance/attestation and derives host/org from it.
  ## DISCRIMINANT = PROVENANCE PRESENCE, not the freeform `attestation` string
  ## (legacy index entries predate the "milpa-vendored"/"author-signed" string
  ## constants, so string-branching would mis-derive them):
  ##   - first `pkGit` entry in `v.provenances` → deriveNamespace(prov.url)
  ##   - else if `v.signedBy` non-empty (OIDC SAN) → deriveNamespace(v.signedBy)
  ##   - else → err(derrUnparseable)  (caller halts; never falls back to `upstream`)
  for prov in v.provenances:
    if prov.kind == pkGit:
      return deriveNamespace(prov.url)
  if v.signedBy.len > 0:
    return deriveNamespace(v.signedBy)
  err[ForgeRef, DerivationError](derrUnparseable)
```

Two model facts make this correct (both verified against `model.nim`/`merge.nim`):
`Version.provenances` is a `seq[Provenance]` (case object; `pkGit` carries `url`), **not** a
scalar `provenance.url`; and author-signed versions are `pkOci`-only with the SAN in
`signedBy`, so "no `pkGit` ⇒ use `signedBy`" is the exact vendored-vs-author-signed split.

**Why a `Version`-typed proc and not a typed `AttestationAnchor` sum** (considered, rejected
as over-machinery for a 2-kind discriminant recoverable from the `Version`): the only two
callers that don't statically know their anchor kind are C2 and C3, and both hold a
`Version` (C2 via `entry.version`). C5 is *not* a caller — at add-entry time the anchor is
statically the OIDC SAN, so C5 calls `deriveNamespace(extractedSan)` directly. A sum type
+ two `anchorOf` overloads would add surface for no caller that needs it.

This is the one place a future Rust reimpl reads the anchor rule; §3's two-bullet prose
is the *specification*, this proc is its *single implementation*. `checkOidcGitAgreement`
and `deriveNamespace` stay as the lower-level primitives.

**Vendored-anchor consistency invariant (verified):** `buildVendoredEntry` sets
`package.upstream` and `provenances[0].url` from the same `pkg.url`, so for a vendored entry
`deriveVersionNamespace(entry.version)` (reads `provenances[0].url`) and the stored
`package.namespace` (derived from `package.upstream` at build time) always agree — the C2
guard cannot false-positive on a well-formed vendored entry. This invariant is asserted by a
post-condition test in C0 so a future divergence (e.g. fork that moved repos) is caught.

**Spec edits this RFC makes to `rfc-package-identity.md`** (C1): rewrite the "Identity
stability" trap paragraph (lines ~184–186) and the S6 slice (lines ~491–519) to
derive-all-per-version + regroup; correct the nimkdl repair to a per-version split;
restate gate #4 as achievable by the migration alone (no manual re-ingest). C1 also
updates `docs/spec/index-format.md` (the normative spec) — see "Doc ownership" below.

---

## 4. Slices

Each slice is independently testable; gate = the full Nim suite green (container command
in the handoff) unless noted. Sequencing in §5.

### C0 — land the SSOT proc `deriveVersionNamespace`  *(/tdd slice — must precede C2 and C3a)*
A pure addition to `namespace.nim`: the `deriveVersionNamespace(v: Version)` proc specified
in §3 (provenance-presence discriminant; first `pkGit` → `provenances` url, else `signedBy`,
else `err(derrUnparseable)`). No existing call sites, so it cannot break the suite — it lands
green and is then consumed by C2 and C3a. Carved out as its own slice because §5 sequences C2
"anytime" and C3a after C1; if the proc only landed "at the head of C3a", a C2-first ordering
would have nothing to call. C0 removes that dependency inversion.
**Behaviors to test:**
- a version with a `pkGit` provenance derives `host/org` from that provenance url.
- a version with only `pkOci` provenance + a GH Actions `signedBy` SAN derives `github.com/<owner>`.
- a version with neither (no `pkGit`, empty `signedBy`) → `err(derrUnparseable)`.
- a version with both a `pkGit` provenance and a `signedBy` prefers the `pkGit` anchor
  (provenance-presence wins; documents the vendored-anchor rule).
- **vendored-anchor consistency invariant:** for an entry built by `buildVendoredEntry`,
  `deriveVersionNamespace(entry.version)` equals `deriveNamespace(entry.package.upstream)`
  (pins the §3 invariant so a future `upstream`/`provenances[0].url` divergence is caught).
**Done when:** the proc exists in `namespace.nim`, the above tests pass, full suite green.

### C1 — correct the S6 spec (resolve the escalation)  *(precondition, doc-only — not a /tdd slice)*
C1 has no RED test; it is a **precondition that gates the queue**, not a TDD cycle.
It must be reviewed and signed off before C3 is queued (otherwise the migration could
run against a spec still in review).
Edit `rfc-package-identity.md`: replace preserve-verbatim with derive-all-per-version +
regroup (§3); fix the "Identity stability" paragraph to say org-only/empty are pre-#32
forms the migration derives once and immutability binds *after*; correct the nimkdl
repair to a deterministic per-version split; restate gate #4.
**Doc ownership (also C1):** update `docs/spec/index-format.md` (the *normative* spec, not
just this RFC) to describe the per-version attestation-anchor algorithm and the normative
`signed_by` format (see C5); note the migration path. `docs/identity-and-provenance.md`
lives in the milpa repo — its user-facing update (incl. the org-rename scenario, B5) is
owned by the milpa consumer RFC, recorded here so it isn't dropped.
**Done when:** `rfc-package-identity.md` S6 + Identity-stability sections and
`index-format.md` are internally consistent with §3 and contain no preserve-verbatim
language. (No code; verification is review + the audit evidence in §3 + human sign-off.)

### C2 — wire the immutability guard (kill dead code)
Wire `checkIdentityStable` into the vendor-bot re-ingest correlation (`orchestrate` /
`merge`): on re-ingest of an already-present `(namespace, name)`, re-derive the
namespace from the incoming provenance and assert it equals the stored one; on
disagreement raise a **distinct identity-drift error** (separate from the content-hash
`DriftAlert`) and **never overwrite**. Make immutability an enforced invariant, not
prose.

**Wiring point:** inside `mergeVendored` in `merge.nim`, **after the `foundPkgIdx >= 0`
match is confirmed** (i.e. after the lookup loop, before the intra-org collision check at
line ~115 — *not* inside the loop body, which runs per-candidate; the guard fires **once**
per `mergeVendored` call). Call `checkIdentityStable` comparing the incoming namespace
re-derived via `deriveVersionNamespace(entry.version)` (the SSOT proc from C0 — note the
argument is `entry.version`, the `Version` inside the `VendoredEntry`, not the entry itself)
against `packages[foundPkgIdx].namespace` (stored). **Guard condition:** only fire when the
stored namespace is already in `host/org` form (contains `/`). Pre-migration org-only
stored values must be skipped — they are pre-#32 forms that C3 will migrate; firing the
guard on them before C3 produces false identity-drift. Post-C3, all stored namespaces are
`host/org` and the guard is unconditional.

**Deliverables (named explicitly) — collapse the alert bag into one variant:** `MergeOutcome`
today carries `drift: Option[DriftAlert]` + `collision: Option[IntraOrgCollision]`; C2 would
add a third parallel optional (`identityDrift`). At most one of the three is ever set per
`mergeVendored` call (they sit in mutually-exclusive branches), so three parallel `Option`s
encode an 8-state space of which only 4 are reachable — a shallow interface. Replace them with
a single sum type (this is the SSOT/deep-module fix, and it makes the `alerts.kdl` sink one
dispatch instead of three formatters):

```nim
type
  MergeAlertKind* = enum maContentDrift, maIntraOrgCollision, maIdentityDrift
  MergeAlert* = object
    case kind*: MergeAlertKind
    of maContentDrift:      drift*:     DriftAlert
    of maIntraOrgCollision: collision*: IntraOrgCollision
    of maIdentityDrift:     identity*:  IdentityDrift   ## type from namespace.nim
  MergeOutcome* = object
    index*: Index
    alert*: Option[MergeAlert]   ## at-most-one per merge; if that ever changes → seq[MergeAlert]
```

`IdentityDrift` already exists in `namespace.nim`. **Operator surface:** `MergeAlert` is
serialized to **`alerts.kdl`** by one `formatAlert(a: MergeAlert)` dispatch (replacing the
current split where `orchestrate.nim` sends `drift` through `appendAlert` but formats
`collision` inline). The identity-drift alert is a **distinct KDL node kind** — specify its
node name + fields (`identity-drift name=… stored=… rederived=…`) so a future Rust impl emits
it identically. Identity-drift never overwrites the stored identity and never silently passes.
*This refactors S1–S5-landed `drift`/`collision` call sites in `merge.nim`/`orchestrate.nim`;
allowed (no external consumers, pre-1.0), and C2 already had to touch `MergeOutcome` anyway.*

**Behaviors to test:**
- re-ingest, same derived namespace → no alert, merge proceeds.
- re-ingest of a pre-migration org-only stored namespace → guard skipped (no false-drift).
- re-ingest post-migration, provenance now derives a *different* namespace → `maIdentityDrift`
  alert surfaced, stored identity unchanged, no silent overwrite.
- a content-hash drift still surfaces as `maContentDrift`; an intra-org collision as
  `maIntraOrgCollision` — the three alert kinds are distinct and round-trip through `alerts.kdl`.

### C3 — S6 migration

Decomposed into a TDD-able pure transform (C3a) and a one-time operational run (C3b),
because the migration logic and "run it on the real 1.5MB file + commit" are different
kinds of work with different gates.

#### C3a — the pure migration transform  *(/tdd slice)*
A pure function `migrateIndex(idx: Index): Result[Index, MigrationHalt]` — no disk I/O.
For each version it derives `host/org` via `deriveVersionNamespace` (the C0 SSOT proc — §3),
regroups by `(namespace, name)`, splits `nimkdl`, and **`canonicalize`s the output before
returning** (so package order is deterministic — required for gate 6 idempotency, since
`Index ==` is `seq`-order-sensitive and `canonicalize` is itself idempotent). No fallback; a
non-deriving version (or an unexpected split beyond `nimkdl`) returns `err(MigrationHalt)`.
The I/O (read `index.kdl`, re-emit) lives at the call site (C3b), reusing the existing
`cmdProject` parse→emit machinery.

`MigrationHalt` is a two-variant sum so "halt and report all splits for operator review" is
actionable (it must carry *which* failure and enough detail to triage):

```nim
type
  MigrationHaltKind* = enum mhkDerivationFailed, mhkUnexpectedSplit
  MigrationHalt* = object
    case kind*: MigrationHaltKind
    of mhkDerivationFailed:
      packageName*: string
      version*:     string
      error*:       DerivationError
    of mhkUnexpectedSplit:
      splits*: seq[tuple[name: string, namespaces: seq[string]]]
```
**Gates 1–5b are pure assertions over the output value**, testable on a small synthetic
index (org-only entry, empty-namespace entry, the two-`nimkdl` pair, an already-`host/org`
entry for idempotency) — the live file is NOT needed for C3a:
1. `tianguis project --check` passes on the re-emitted output (KDL↔JSON parity).
2. zero `namespace ""` entries remain.
3. every namespace matches `^[a-z0-9.-]+/[a-zA-Z0-9_.~-]+$`.
4. the `nimkdl` pair appears as **two** `package` blocks with different `namespace`,
   each carrying its own version(s) intact — **per-version split, no re-ingest**.
5a. `output_package_count >= input_package_count` (only splits or preserves, never drops).
5b. every version from every input package appears in exactly one output package
    (version conservation — the load-bearing "no data lost" invariant). The original gate
    #5 (`distinct (namespace,name) count == node count`) is NOT this invariant: it misses a
    drop+split that numerically cancels and would flag a correct merge of two pre-migration
    nodes.
6. **idempotency:** `migrateIndex(migrateIndex(idx)) == migrateIndex(idx)` (second run is a
   no-op; see §3 migration requirements).
**Depends on:** C1 (correct spec).

#### C3b — run the migration + commit  *(operational, not a /tdd slice)*
Invocation surface: a `tianguis migrate` subcommand (kept in-tree — it's the auditable
record of how the index was migrated, and the idempotency gate makes a re-run harmless),
with `--dry-run` (print the diff + every split diagnostic, write nothing) as the default
safety. **Mark the subcommand `{.deprecated: "one-time #32 migration; remove after the
migration commit lands".}`** (or an equivalent header comment + removal issue) so this
one-shot operational verb does not silently become permanent CLI surface. Atomic write per
§3 (staging file + rename; halt leaves `index.kdl` intact). A pre-run `index.kdl` →
`index.kdl.bak` backup is written before the rename — **this `.bak` is a local operational
aid only, not a repo-committed recovery artifact** (see rollback below). Operator runs
`--dry-run`, reviews the split diagnostics (expect exactly `nimkdl`), then commits the
result; the post-migration commit is the new trust anchor (consumer-side index
attestation binds here — milpa#103, deferred).

**Regenerate `index.json` in the same commit:** the migration rewrites `index.kdl`; the
`parity.yaml` CI runs `tianguis project --check` (KDL↔JSON parity) on any `index.kdl` change
and will fail if `index.json` is stale. C3b must run `tianguis project` (no `--check`) after
the atomic write to regenerate `index.json`, and commit both files together.

**Rollback (post-commit recovery):** the pre-migration state is recovered by
`git revert <C3b-commit-sha>` followed by re-running `tianguis migrate` once the defect is
fixed (the `.bak` is not relied on — it may be overwritten by a re-run). A revert intentionally
undoes the trust-anchor commit; if vendor-en-absentia additions landed between C3b and the
revert, re-apply them on top of the re-migrated index before re-committing.

**Downstream consequence — site URLs change (record, coordinate):** `site/scripts/build.py`
uses `namespace` as both a URL segment and a filesystem path (`/p/<namespace>/<name>.html`).
Post-migration these go from `/p/coreyleavitt/…` to `/p/github.com/coreyleavitt/…`; the
`pages.yaml` rebuild on the C3b commit will produce the new shapes and old external links will
404. Not a blocker, but the C3b commit should land with a redirect/404 note for the Pages
config (or an explicit decision that the old URLs are invalidated).

**Done when:** the real `index.kdl` is migrated, gates 1–5b + idempotency hold on it,
`index.json` is regenerated, and `tianguis project --check` passes.
**Depends on:** C3a.

#### Post-migration checklist (cross-repo — not a tianguis test gate)
Run once C3b and C4 are both committed; cannot be automated in the Nim suite:
- milpa `parse_index` on the migrated index drops no entry (was gate #6; it requires the
  milpa repo + C4 landed + the committed migrated index, so it is a manual end-to-end
  smoke check, not a tianguis unit gate).

### C4 — milpa `parse_index` tuple-key gate  *(cross-repo, Python)*
In `milpa/tianguis_client.py`, key `packages` on `(namespace, name)` instead of bare
`name` (≈ line 376), so a collision pair yields two `Package`s. **This is wider than a
dict-rekey** — name the real surface so it doesn't surprise the implementer:
- (a) add a `namespace` field to the `Package` dataclass (absent today);
- (b) rekey the internal store to `dict[tuple[str,str], Package]`;
- (c) `Index.lookup(name: str)` keeps its bare-name signature but fans out across
  namespaces: return the single hit when unambiguous, raise a coded
  `TNG-AMBIGUOUS-NAME` (new error) when a bare name maps to >1 namespace. **Register
  `TNG-AMBIGUOUS-NAME` in `_TNG_CODES`** (currently 12 codes, none for this) so the raise
  doesn't itself `AssertionError` on an unregistered code;
- (d) `resolve_named` propagates that error rather than silently picking.
This is still the *narrow* parse + lookup fix — it does NOT touch fetch/solve logic or
add row-selection (that's the separate milpa consumer RFC). The ambiguous-name *error* is
the correct narrow behavior; *resolving* the ambiguity (row-selection) is the consumer RFC.
**Behaviors to test (milpa repo, `uv run pytest`):**
- a two-`nimkdl`-blocks fixture string parses to **2** packages, not 1 (no live index).
- bare-name lookup still resolves when unambiguous.
- bare-name lookup on a collision pair raises `TNG-AMBIGUOUS-NAME` (does not silently pick).
**Sequencing:** **do now** (Corey 2026-06-07) — land the narrow `parse_index` tuple-key
change ahead of the resolver-swap commit; it's a prerequisite for the post-migration
cross-repo check.

### C5 — #38 author-signed namespace from OIDC (close the spoofing surface)
Derive the author-signed `namespace` from the **verified OIDC signer** (`signedBy`),
not the `--namespace` flag. Pin the OIDC SAN → `github.com/<owner>` parse (reuse
`deriveNamespace`); drop `--namespace` from `addentry.nim` and stop passing it in
`commit-entry.yaml`. **This alone fully closes #38** — the spoofing surface is the
untrusted `--namespace` flag, and deriving from the verified SAN removes it.

> **⚠ OPEN ESCALATION — `checkOidcGitAgreement` wiring (awaiting Corey).** The RFC (§1
> item 2, and this slice as originally written) assumed C5 would *wire*
> `checkOidcGitAgreement`. Round-2 feasibility found this assumption is **wrong**: that
> proc only does work when a single version carries **both** a `pkGit` provenance **and**
> an OIDC SAN, but the add-entry path constructs `pkOci`-only versions (verified in
> `addentry.nim`), so **no such version can exist** — wiring it now would re-create exactly
> the dead-code problem this RFC exists to remove. The proc's own docstring already says
> "NOT currently wired… wire this in when that combination becomes possible." **Closing #38
> does not require it.** Recommendation: **descope the `checkOidcGitAgreement` wiring from
> C5** (keep it as a delivered-but-dormant primitive) and **file a follow-on issue** to wire
> it if/when a both-provenance path is introduced. The alternative — expand C5 to also add a
> `pkGit` provenance to author-signed versions so the wiring becomes live — is a model/scope
> change beyond #38 and is not recommended here. *This contradicts a stated RFC goal, so it
> is surfaced rather than silently applied; the rest of C5 below assumes the recommended
> descope.*

**SAN extraction requirement:** `commit-entry.yaml` currently passes the caller-supplied
`signed_by` input through to `add-entry` after using it as a regexp *prefix* in `cosign
verify --certificate-identity-regexp="^${SIGNED_BY}@"`. A prefix match is not the same
as the verified certificate SAN. C5 must extract the actual certificate SAN from `cosign
verify`'s JSON output (e.g. `cosign verify ... --output json | jq -r '.[0].optional.Subject'`)
and pass the *extracted* SAN — not the input — to `tianguis add-entry`. `deriveNamespace`
applied to a full GitHub Actions SAN
(`https://github.com/owner/repo/.github/workflows/publish.yaml@refs/heads/main`) correctly
derives `github.com/owner` by taking the first path segment as the org and discarding the
rest; no new code is needed for the parse. The `--signed-by` flag carried into `add-entry`
must be treated as the source-of-truth for namespace derivation, and `addentry.nim` must
validate at entry time that `deriveNamespace(signed_by)` succeeds — a hard reject if it does
not. This is the code-level enforcement of the "always derivable" invariant.

**Conformance corpus (also C5):** `spec/fixtures/derive-namespace.json` (40 cases) is
currently all git/SSH clone URLs — zero OIDC SAN inputs. C5 adds SAN cases so the
cross-language corpus covers the author-signed derivation path: (a) a full GH Actions SAN
(`https://github.com/owner/repo/.github/workflows/publish.yaml@refs/heads/main` →
`github.com/owner`); (b) a SAN whose issuer/host is not `github.com` → derivation error
(bounds the GH-Actions-OIDC-only assumption). Without these, the Python/Rust consumer
impls have no corpus coverage for the SAN path.

**`signed_by` normative format (also C1/index-format.md):** specify per attestation kind —
author-signed `signed_by` is a **parseable** GH Actions SAN URL (load-bearing for C5
derivation); milpa-vendored `signed_by` stays a freeform provenance string and is **not**
an identity anchor (vendored identity comes from `provenance.url`). `deriveVersionNamespace`
encodes exactly this split.

**Cross-cutting scope — the Go dispatch relay is a fourth `deriveNamespace` (also C5):**
`dispatch/handler.go` has its **own** `deriveNamespace` (lines 157–173) that returns
**org-only** (`coreyleavitt`, no host) and passes it as the `"namespace"` workflow input to
`commit-entry.yaml` (line 115). It is a third/fourth independent impl of the identity
algorithm (alongside Nim `namespace.nim`, milpa's parse path, future Rust) and is **not**
covered by the `derive-namespace.json` corpus. When C5 drops `--namespace` from
`addentry.nim`, the `"namespace"` key must also be removed from the dispatch inputs map
(`handler.go:115`) and from its tests (`handler_test.go:526` hardcodes
`"namespace": "coreyleavitt"`; `function_test.go`). C5 scope therefore includes
`dispatch/handler.go` + `dispatch/handler_test.go` + `dispatch/function_test.go`. *(Recording
the larger SSOT debt: the Go relay should eventually be governed by `derive-namespace.json`
too — out of scope here, noted so it doesn't drift further.)*

**Transition-window safety (C3b → C5):** between the migrated index committing (C3b, all
namespaces now `host/org`) and C5 landing, the live author-signed publish path still accepts
`--namespace` and the dispatch relay still emits org-only — a new publish in that window would
write an org-only namespace back into the migrated index, undoing the migration for that
package and failing gate #3. Mitigation (consistent with the hard-reject philosophy): land a
**`host/org`-form guard in `cmdAddEntry` as C5's first behavior** — reject any incoming
`namespace`/derived value that does not contain `/`. Recommended sequencing: **land C5
immediately after C3b** (it is small) to keep the window closed; the guard is the belt-and-
suspenders if any publish races the deploy.

**Behaviors to test:**
- a signer identity (full GH Actions SAN) derives the expected `github.com/<owner>` namespace.
- `add-entry` rejects a `signed_by` value from which `deriveNamespace` fails (hard reject,
  not namespace "").
- `add-entry` ignores/rejects a caller-supplied `--namespace` flag; identity comes from the
  verified signer.
- a non-`host/org`-form namespace reaching `cmdAddEntry` is hard-rejected (transition-window guard).
- extracted SAN (not input prefix) is what gets stored as `signed_by` in the index entry.
- dispatch no longer emits a `namespace` workflow input (its tests updated accordingly).
- *(moved to the `checkOidcGitAgreement` follow-on issue, not C5: "a version with both git
  provenance and OIDC that disagree → rejected" — unreachable until a both-provenance path
  exists; see the open-escalation note above.)*

**Org-rename consequence (B5 — document, don't fix here):** once immutability binds
(post-C3), a package whose new version derives a *different* namespace (org rename, repo
transfer) is correctly rejected by the C2 guard — the author cannot publish a new version
under a moved org against the old identity. This is intended (identity is immutable), but
it is the surfacing point for the deferred general unification mechanism (#36). The
user-facing explanation belongs in `docs/identity-and-provenance.md` (milpa repo), owned
by the milpa consumer RFC; recorded here so the scenario isn't lost.
**Depends on:** S1–S6 landed (per #38) → after C3.

### C6 — yank the stale `coreyleavitt/nimkdl` v0.1.4
After C3 splits `nimkdl` into `github.com/greenm01/nimkdl` (v2.1.0) and
`github.com/coreyleavitt/nimkdl` (v0.1.4), the coreyleavitt entry is a **dead pre-rename
publish** (the project is now `nkdl`). Remove it as an explicit curation step, distinct
from the mechanical migration.
- **Mechanism:** **a direct KDL edit (delete the `package` block), NOT a yank-flag
  operation.** `#13` yank semantics are unimplemented (`cli.nim` has no `cmdYank`;
  `index-format.md` reserves `yanked*` fields as parsed-but-unenforced), so "per #13"
  would mean building the yank subsystem — out of scope. Hard-remove here is the curation
  edit; `tianguis project --check` catches any resulting JSON staleness. *Was a
  sub-decision for architect (tombstone vs. hard-remove); resolved hard-remove* — the
  `github.com/coreyleavitt/nimkdl` identity
  only comes into existence at C3 (it was conflated before), so no existing lockfile using
  *qualified* keys can reference it; a tombstone protects nothing for qualified-key
  consumers. **Caveat:** milpa lockfiles currently key by *bare* name (pre-milpa-consumer-RFC).
  A bare-name `nimkdl` lockfile entry might have resolved against the coreyleavitt entry.
  Hard-remove is safe here because: (a) C6 is a curation step, not a migration; (b) the
  milpa consumer RFC soft-cutover will warn on stale bare-name entries anyway; (c) the
  coreyleavitt/nimkdl entry is a dead package (project renamed to `nkdl`). Hard-remove
  confirmed — no tombstone needed.
- **Done when:** no `coreyleavitt/nimkdl` entry remains; `tianguis project --check`
  passes; greenm01's `nimkdl` is untouched.
**Depends on:** C3 (the split must exist before the coreyleavitt half can be removed).

### Out of scope (recorded, not deferred-silently)
- **#37 (gitlab nested groups):** 0 in the live index; `derive-all` rejects nothing.
  Purely additive; future, non-blocking. Stays an open enhancement.
- **milpa consumer contract** (merged dep kind, row-selection, lockfile soft-cutover):
  separate milpa-repo RFC, sequenced after this one. (Only the narrow `parse_index`
  gate, C4, is in scope here.)
- **#36 (cross-identity unification after rename):** the *general* alias/supersede
  mechanism stays out of scope; C6 is a one-off hard-remove of a single dead entry, not
  the general mechanism.

---

## 5. Sequencing

```
C0 (SSOT deriveVersionNamespace in namespace.nim) ──┬──► C2 (immutability guard)
                                                    └──► C3a
C1 (precondition: spec + index-format.md; human sign-off) ──┐
                                                            ▼
                              C3a (pure migrateIndex + gates 1–5b + idempotency)
                                                            │
                                                            ▼
                              C3b (run on real index + commit; new trust anchor)
                                              ├──► C6 (hard-remove coreyleavitt/nimkdl)
                                              └──► C5 (#38 OIDC enforcement + SAN corpus)
                                                   ▲ land immediately after C3b
                                                     (closes the org-only write-back window)
C4 (milpa parse_index, do now) — independent; needed for the post-migration
                                 cross-repo check (was gate #6).
C2 (immutability guard) — needs C0; otherwise independent; guard conditioned on
                          host/org form, so landing order vs C3 is safe either way.
```

- **C0** first (pure proc, lands green); both C2 and C3a call it, so it must precede either.
  This removes the round-1 dependency inversion (the proc was scheduled "at the head of C3a"
  while C2 — which also needs it — was "anytime").
- **C1** is a *precondition*, not a /tdd slice; sign off before queueing C3a.
- **C2** anytime *after C0* (the `/`-form guard removes the C2↔C3 ordering hazard).
- **C4** do now (decided 2026-06-07); prerequisite for the post-migration cross-repo check.
- **C3a** needs C0 + C1; **C3b** needs C3a; the cross-repo check needs C3b + C4 both committed.
- **C6** needs C3b (the split must exist first).
- **C5** immediately after C3b (depends on the full S1–S6 identity model; landing it right
  after C3b closes the transition window where a publish could write an org-only namespace
  back into the migrated index — see C5 transition-window safety).

---

## 6. Open forks (for architect / Corey)

All four implementation decisions are settled (2026-06-07): derive-all; namespace from
the per-version attestation anchor (`provenance.url` | `signed_by`), no fallback;
`parse_index` now; yank the stale entry. Architecture review (round 1) resolved the
remaining items:

- **C6 tombstone vs hard-remove:** **RESOLVED — hard-remove.** Confirmed above (C6 section).
  Tombstone protects nothing for this case; bare-name lockfile risk is acceptable given
  the milpa consumer RFC soft-cutover.
- **C5 OIDC SAN field:** **RESOLVED — extract verified SAN from cosign output, do not
  pass input through.** `deriveNamespace` handles the full GH Actions SAN with no new
  code. `addentry.nim` must hard-reject a `signed_by` value that fails `deriveNamespace`.
  See C5 section for the full SAN extraction requirement.
- **C2 guard ordering hazard:** **RESOLVED — guard is conditioned on stored namespace
  containing `/`** (host/org form). Pre-migration org-only values skip the guard.
  See C2 section and migration requirements above.
- **C3 gate #5 replacement:** **RESOLVED — gates 5a + 5b replace the original gate #5.**
  Version conservation (5b) is the load-bearing invariant, not tuple-count equality.
  See C3a.

**Round-1 structural fixes (applied to this RFC):**
- **SSOT:** anchor-picking was prose duplicated across C2/C3/C5 → unified into one
  `deriveVersionNamespace` proc (§3). Project non-negotiable; a Rust reimpl reads one rule.
- **C3 decomposed** into C3a (pure `migrateIndex`, TDD-able on a synthetic index) + C3b
  (one-time operational run via a `tianguis migrate --dry-run`-default subcommand, atomic
  write + backup). Cross-repo gate #6 moved to a post-migration checklist (it can't be a
  Nim unit gate). Added an idempotency gate.
- **C1 reframed** as a precondition (not a /tdd slice) and given doc ownership
  (`index-format.md` normative update; milpa-side user docs owned by the consumer RFC).
- **C2 deliverables named:** `MergeOutcome.identityDrift` field + `alerts.kdl` operator
  surface (same sink as content `DriftAlert`).
- **C4 surface named:** `Package.namespace` field, tuple rekey, `Index.lookup` fan-out,
  new `TNG-AMBIGUOUS-NAME` error — wider than a line-376 rekey.
- **C5 corpus + format:** OIDC SAN cases added to `derive-namespace.json`; normative
  `signed_by` format specified per attestation kind.
- **C6 mechanism:** direct KDL edit, not a (nonexistent) yank subsystem.

**Round-2 structural fixes (applied to this RFC):**
- **SSOT proc carved out as pre-slice C0** (was scheduled "at the head of C3a" while C2 also
  needs it → dependency inversion). Signature/body corrected against the real model:
  `Version.provenances` is a `seq[Provenance]` (not `provenance.url`); discriminant is
  **provenance-presence** (first `pkGit` → its url, else `signedBy`), robust to legacy
  attestation strings. `AttestationAnchor` sum type considered and rejected as over-machinery.
  C5 is **not** a caller (it derives from the statically-known SAN directly).
- **`MergeOutcome` alert-bag collapsed** into one `Option[MergeAlert]` variant (was going to
  be three parallel mutually-exclusive optionals); unifies the `alerts.kdl` sink to one
  dispatch. Identity-drift gets a distinct, specified KDL node kind.
- **`MigrationHalt` defined** (two-variant sum: derivation-failed vs unexpected-split) so the
  "halt + report all splits" gate is actionable; **`migrateIndex` canonicalizes its output**
  so the idempotency gate holds (`Index ==` is order-sensitive).
- **C2 wiring point corrected:** fires once after `foundPkgIdx >= 0` (not per loop iteration);
  argument is `entry.version`. Vendored-anchor consistency invariant stated + pinned in C0.
- **C3b hardened:** regenerate `index.json` in the migration commit (else `parity.yaml` CI
  fails); explicit `git revert` rollback procedure; `{.deprecated.}` on the one-shot `migrate`
  subcommand; site-URL-shape change recorded.
- **C5 scope widened:** the Go `dispatch/handler.go` is a fourth `deriveNamespace` emitting
  org-only — folded into C5 (drop the `namespace` workflow input + fix its tests). Transition-
  window guard (`host/org`-form reject in `cmdAddEntry`) + sequence C5 right after C3b.
- **C4:** register `TNG-AMBIGUOUS-NAME` in `_TNG_CODES` explicitly.

**One open escalation (awaiting Corey) — does NOT block the rest:**
- **`checkOidcGitAgreement` wiring (C5).** Round-2 feasibility proved the RFC's stated goal
  (§1 item 2: "wire the two dead mechanisms") is unachievable for this proc as scoped — the
  add-entry path is `pkOci`-only, so no version carries both a git provenance and an OIDC SAN,
  and wiring it would re-create dead code. **#38 closes without it.** *Recommendation:* descope
  the wiring from C5, keep the proc as a delivered-but-dormant primitive, and file a follow-on
  to wire it if/when a both-provenance path exists. Surfaced (not silently applied) because it
  narrows a baked-in RFC goal. The rest of the RFC assumes this descope; if you'd rather expand
  C5 to *create* a both-provenance path so the wiring goes live, say so and C5 grows.

Everything else is settled. Once the escalation above is decided, the RFC is ready for `/tdd`
(slice order: C0 → C4 → C1 → C3a → C3b → C5 → C6, with C2 anytime after C0).
