# rfc-identity-completion — handoff

> **⚠ SUPERSEDED (2026-06-07).** Consolidated into
> `milpa/docs/rfc-identity-and-resolution-completion.md` (+ its handoff). #38 folded back in,
> `checkOidcGitAgreement` deletion settled, milpa resolver-core added. Resume from the new
> handoff. Below kept for review provenance.


- **Stage:** 2 architect — **round 2 COMPLETE** (4 lenses; all clear-best fixes applied).
  **ONE open escalation awaiting Corey** (checkOidcGitAgreement wiring — see below); does
  NOT block the rest. Both architect rounds done.
- **Resume:** decide the open escalation, then stage 3:
  `/loop implement the next unimplemented RFC slice from docs/rfc-identity-completion.md with
  /tdd …`. Slice order: C0 → C4 → C1 → C3a → C3b → C5 → C6 (C2 anytime after C0). Safe to
  `/compact` first.

## OPEN ESCALATION (round 2) — awaiting Corey
- **C5 `checkOidcGitAgreement` wiring.** Feasibility proved the RFC's §1-item-2 goal ("wire
  both dead mechanisms") is unachievable for this proc: add-entry path is `pkOci`-only, so no
  version carries both git + OIDC → wiring = new dead code. **#38 closes without it.**
  Recommend: descope the wiring, keep proc dormant, file a follow-on. RFC §6 + C5 written
  assuming this descope. Alternative (not recommended): expand C5 to create a both-provenance
  path so the wiring goes live. **Corey to confirm descope vs expand.**

## Round-2 architect results (applied to the RFC)
- **C0 new pre-slice:** SSOT `deriveVersionNamespace` carved out of C3a (fixes dependency
  inversion — C2 also needs it). Body corrected vs real model: `Version.provenances` is a
  `seq[Provenance]`; discriminant = provenance-presence (first `pkGit`→url, else `signedBy`),
  not the freeform `attestation` string. `AttestationAnchor` sum considered+rejected. C5 is
  NOT a caller (derives from statically-known SAN directly). +vendored-anchor invariant test.
- **C2 `MergeAlert` variant:** collapsed `MergeOutcome`'s `drift`+`collision`+(new)identityDrift
  into one `Option[MergeAlert]` sum (at-most-one); unifies alerts.kdl to one dispatch. Wiring
  point corrected (fires once after `foundPkgIdx>=0`, arg = `entry.version`).
- **C3a:** `MigrationHalt` defined (derivation-failed | unexpected-split); `migrateIndex`
  canonicalizes output (idempotency gate needs deterministic order).
- **C3b:** regenerate `index.json` in commit (parity.yaml); `git revert` rollback; `migrate`
  subcommand `{.deprecated.}`; site-URL-shape change recorded.
- **C5:** Go `dispatch/handler.go` is a 4th `deriveNamespace` (org-only) feeding the same
  workflow — folded into C5 scope (drop `namespace` input + fix handler_test/function_test).
  Transition-window guard (`host/org`-form reject in `cmdAddEntry`); sequence C5 right after C3b.
- **C4:** register `TNG-AMBIGUOUS-NAME` in `_TNG_CODES` explicitly.
- All claims verified against source: model.nim (provenances seq, canonicalize idempotent),
  merge.nim (mergeVendored takes VendoredEntry, buildVendoredEntry sets upstream==prov[0].url),
  dispatch/handler.go:115/157 (org-only Go deriveNamespace).

## Round-1 architect results (applied to the RFC)
- **SSOT proc `deriveVersionNamespace(v)`** added (§3) — unifies anchor-picking that was
  prose-duplicated across C2/C3/C5. Reused by all three.
- **C3 split** → C3a (pure `migrateIndex(Index)->Result[Index,MigrationHalt]`, TDD-able on
  synthetic index, gates 1–5b + idempotency) + C3b (one-time `tianguis migrate`,
  `--dry-run` default, atomic write + `.bak`, post-commit = new trust anchor / #103).
  Old cross-repo gate #6 → post-migration checklist (not a Nim unit gate).
- **C1** reframed precondition (not /tdd slice) + doc ownership (`index-format.md`
  normative; milpa user docs → consumer RFC).
- **C2** deliverables named: `MergeOutcome.identityDrift` + `alerts.kdl` sink; guard
  conditioned on stored ns containing `/` (kills C2↔C3 ordering hazard).
- **gates 5a/5b** replace old gate #5 (version conservation is load-bearing).
- **C4** real surface named: `Package.namespace`, tuple rekey, `Index.lookup` fan-out,
  new `TNG-AMBIGUOUS-NAME`.
- **C5** OIDC SAN corpus cases + normative `signed_by` format per attestation kind +
  extract verified SAN from cosign JSON (not input prefix).
- **C6** = direct KDL edit (no yank subsystem); hard-remove confirmed.
- Round-2 watch items: confirm C3a/C3b decomposition + that `deriveVersionNamespace`
  absorbs the C2 site cleanly (input there is a built `VendoredEntry`, not a `Version`).
- **RFC:** `docs/rfc-identity-completion.md` • **Completes:** `rfc-package-identity.md`
  (S1–S5 landed; this RFC corrects + executes S6 and closes #37/#38).

## Slices  (order: C0 → C4 → C1 → C3a → C3b → C5 → C6; C2 anytime after C0)
- [ ] C0 — SSOT `deriveVersionNamespace(v: Version)` in namespace.nim (NEW, round 2).
      provenance-presence discriminant; +vendored-anchor invariant test. Precedes C2/C3a.
- [ ] C1 — correct S6 spec in rfc-package-identity.md (resolve preserve-verbatim
      escalation → derive-all-per-version + regroup). doc-only.
- [ ] C2 — wire `checkIdentityStable` immutability guard into re-ingest (kill dead code).
      Now also: collapse MergeOutcome → `Option[MergeAlert]` variant. Needs C0.
- [ ] C3 — S6 migration transform (derive per-version from attestation anchor + regroup
      + nimkdl split; 6 gates; halt on non-deriving version). Depends: C1, C4.
- [ ] C4 — milpa `parse_index` tuple-key gate (cross-repo). **DO NOW** (decided
      2026-06-07). Prerequisite for C3 gate #6.
- [ ] C5 — #38 author-signed namespace: ENFORCEMENT only (derive from `signed_by` via
      existing deriveNamespace, drop `--namespace` in addentry.nim + commit-entry.yaml,
      wire `checkOidcGitAgreement`). Depends: full S1–S6.
- [ ] C6 — yank stale `coreyleavitt/nimkdl` v0.1.4 (hard-remove; #13 semantics).
      Depends: C3.

## Out of scope (recorded)
- #37 gitlab nested groups — 0 in live index, not a blocker, additive/future.
- milpa consumer contract — separate milpa RFC.
- #36 cross-identity unification — unchanged.

## Audit facts grounding the draft (live index, 2613 pkgs)
- 2509 non-empty namespaces ALL org-only (zero host/org); 104 empty; 0 missing
  provenance URL; 2508/2509 org-only == derived org.
- 1 mismatch = nimkdl (#32 artifact): greenm01 v2.1.0 git + coreyleavitt v0.1.4 OCI
  conflated under namespace="coreyleavitt"; greenm01 version data SURVIVED → per-version
  split, NO re-ingest.
- 0 gitlab nested-group (depth>2) URLs → #37 not a blocker.
- #38 hole confirmed live: addentry.nim:91 stamps `namespace: args.namespace` from
  `--namespace` (commit-entry.yaml:124); `signedBy` captured but unused for identity.

## Open forks (awaiting Corey) — all four impl decisions SETTLED 2026-06-07
Remaining for architect only:
- C6 tombstone vs hard-remove → recommend hard-remove (conflated identity, no possible
  existing lockfile ref).
- C5 SAN→namespace parse → confirm existing deriveNamespace suffices (it does on the
  github.com OIDC SAN).

## Key decisions (this session)
- Premise settled (grill-me past): identity holds as fully-qualified host/org; draft
  executes the migration, does not reconsider it.
- "Everything we put off" scoped as #32 completion (S6 + wiring + #37/#38 + narrow
  milpa gate); full milpa consumer contract stays a separate RFC.
- **D1 — derive-all** (not preserve-verbatim). org-only/empty = pre-#32; immutability
  binds post-migration.
- **D2 — namespace from the per-version attestation anchor**: git `provenance.url` for
  vendored, OIDC `signed_by` SAN for author-signed. NO `upstream` fallback — there is no
  non-git OCI signing path (author path hardcoded to GH-Actions OIDC issuer
  `token.actions.githubusercontent.com`), so `signed_by` is always `github.com/<owner>`
  and `deriveNamespace` already handles it. Non-deriving version → halt + escalate.
- **D3 — milpa parse_index: do now** (don't wait for resolver-swap).
- **D4 — yank stale coreyleavitt/nimkdl v0.1.4** in this RFC (C6, hard-remove).
- #37 NOT a blocker (0 nested-group URLs in live index).
