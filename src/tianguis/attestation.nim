## The §1 in-toto statement builder — the bytes that get signed
## (rfc-attestation-delivery.handoff.md S3, per-entry-attestation.md §1).
##
## `buildEntryStatement` is a PURE function: no I/O, no crypto. It produces
## the canonical in-toto Statement JSON whose `subject[0]` is later wrapped
## in a DSSE envelope and cosign-signed (vendored: S7; author-signed: S8),
## and whose bundle bytes get content-addressed + pinned (S4).
##
## Subject binding is a byte-format CONTRACT with milpa's verifier, not a
## style choice: milpa's gate (impls/python/milpa/entry_trust.py,
## `build_entry_subject`) computes the expected subject as
##
##     EntrySubject(
##       name=f"pkg:tianguis/{namespace}/{name}@{version}",
##       sha256=hex_digest,   # scheme-agnostically split from content_hash
##     )
##
## and checks `subject[0].name` / `subject[0].digest.sha256` for EQUALITY
## against that (RFC §5 stages 3/4, pre-crypto). This module reproduces that
## exact coordinate: plain string interpolation, no purl percent-encoding —
## milpa itself does none, so matching milpa (the oracle/verifier) means
## doing none here either, even though `namespace` can itself contain `/`
## (tianguis namespaces are `host/org`; RFC package-identity.md).
##
## `_type` / `predicateType` / `predicate` shape are NOT normatively fixed by
## the RFC — milpa's verifier only ever inspects `subject[0]` plus the DSSE
## envelope/crypto (RFC §6: predicate contents are never inspected). This
## module picks:
##   `_type`: "https://in-toto.io/Statement/v1" — the current in-toto
##     Statement type (supersedes the old "Statement/v0.1").
##   `predicateType`: "https://tianguis.dev/attestation/v1" — a
##     tianguis-owned predicate type URI, so the statement is
##     self-describing without needing an external schema registry.
##   `predicate`: `{attestation_kind, signed_by}` — carries the
##     "milpa-vendored" vs "author-signed" distinction and the signer, since
##     nothing else in the DSSE envelope records those (the cert SAN records
##     the *cryptographic* signer identity, but the intended-kind label is
##     registry-domain data, not a Sigstore concept).

import std/[json, strutils]
import nkdl  # for Result[T,E], ok(), err() — matches namespace.nim/merge.nim convention
export nkdl  # so callers of extractStatementSubject get .isOk/.isErr/.get without a separate import

type
  StatementSubject* = tuple[name, digestSha256: string]

proc extractContentHashHex*(contentHash: string): string =
  ## Scheme-agnostic hex extraction from a `content_hash` string.
  ##
  ## Handles milpa's canonical `dag-sha256:<64-hex>` form (identity.md §2.1)
  ## by stripping everything up to and including the LAST `:` — never a
  ## hardcoded `removeprefix("sha256:")`, which would silently no-op on the
  ## real `dag-sha256:` scheme. A bare `<hex>` with no scheme prefix at all
  ## (no `:` present) is returned unchanged, so this proc is total over any
  ## content-hash-shaped input, including inputs from schemes not yet
  ## defined. Mirrors the scheme-splitting INTENT of milpa's
  ## `identity.split_identity_scheme`, which tianguis (the producer) does
  ## not need to import: unlike milpa's consumer-side seam, this proc never
  ## errors on a missing separator — a hash with no scheme is still a valid
  ## hex digest to bind into a subject.
  let idx = contentHash.rfind(':')
  if idx == -1: contentHash
  else: contentHash[idx + 1 .. ^1]

proc buildEntrySubjectName*(namespace, name, version: string): string =
  ## The exact `pkg:tianguis/<namespace>/<name>@<version>` coordinate,
  ## matching milpa's `entry_trust.build_entry_subject` byte-for-byte:
  ## plain string interpolation, deliberately UNESCAPED (milpa's oracle
  ## implementation does no purl percent-encoding either).
  "pkg:tianguis/" & namespace & "/" & name & "@" & version

proc buildEntryStatement*(
  namespace, name, version, contentHash, attestationKind, signedBy: string
): string =
  ## Build the canonical in-toto Statement JSON for one registry entry —
  ## the payload that gets DSSE-enveloped and cosign-signed.
  ##
  ## Deterministic: `std/json`'s `JObject` is backed by an ordered table, so
  ## inserting keys in a fixed order below always serializes to the same
  ## byte sequence for the same inputs (required: the author and the
  ## vendor-bot must each be able to independently reproduce the identical
  ## statement bytes for the same entry).
  var subject = newJObject()
  subject["name"] = %buildEntrySubjectName(namespace, name, version)
  var digest = newJObject()
  digest["sha256"] = %extractContentHashHex(contentHash)
  subject["digest"] = digest

  var predicate = newJObject()
  predicate["attestation_kind"] = %attestationKind
  predicate["signed_by"] = %signedBy

  var subjects = newJArray()
  subjects.add(subject)

  var statement = newJObject()
  statement["_type"] = %"https://in-toto.io/Statement/v1"
  statement["subject"] = subjects
  statement["predicateType"] = %"https://tianguis.dev/attestation/v1"
  statement["predicate"] = predicate

  $statement

proc buildIndexStatement*(digestSha256, signedBy: string): string =
  ## Build the canonical in-toto Statement JSON for the WHOLE `index.kdl`
  ## document — the payload that gets DSSE-enveloped and signed into
  ## `index.kdl.bundle` (milpa `docs/rfc-registry-trust-federation.md` §4/
  ## §7.3; tianguis-side cross-repo bundle-delivery gap, TNG-INDEX-BUNDLE-
  ## MISSING).
  ##
  ## Unlike `buildEntryStatement`'s per-package subject, milpa's whole-index
  ## verifier (`impls/python/milpa/index_trust.py::_check_dsse_payload_digest`,
  ## mirrored in `index_trust.rs`) checks ONLY `subject[0].digest.sha256`
  ## against `sha256(index_bytes)` — it never inspects `subject[0].name` or
  ## the predicate contents. So `digestSha256` is the ONE load-bearing byte-
  ## format contract here; the subject `name` ("index.kdl") and the
  ## predicate fields are descriptive metadata only, matching the same
  ## "predicate is never inspected" property `buildEntryStatement` documents
  ## for the per-entry case.
  ##
  ## `digestSha256` is the caller's already-computed sha256 hex of the raw
  ## `index.kdl` bytes — the whole-file digest, NOT a `content_hash`-shaped
  ## value, so (unlike `buildEntryStatement`) no `dag-sha256:`-scheme
  ## stripping applies; pass the bare 64-hex digest.
  var subject = newJObject()
  subject["name"] = %"index.kdl"
  var digest = newJObject()
  digest["sha256"] = %digestSha256
  subject["digest"] = digest

  var predicate = newJObject()
  predicate["attestation_kind"] = %"whole-index"
  predicate["signed_by"] = %signedBy

  var subjects = newJArray()
  subjects.add(subject)

  var statement = newJObject()
  statement["_type"] = %"https://in-toto.io/Statement/v1"
  statement["subject"] = subjects
  statement["predicateType"] = %"https://tianguis.dev/attestation/index/v1"
  statement["predicate"] = predicate

  $statement

proc buildEpochCommitmentStatement*(commitmentDigest, signedBy: string): string =
  ## Build the canonical in-toto Statement JSON for the D-Watermark
  ## pre-epoch set commitment `C` (milpa `docs/rfc-attestation-v1-normative.md`
  ## §6 S-EpochCommitment; spec `registry-protocol.md` §3.4.8/§3.4.9) — the
  ## payload that gets DSSE-enveloped and signed into the `.epoch-commitment`
  ## sidecar, analogous to `buildIndexStatement`'s whole-index counterpart.
  ##
  ## Subject binding is the ONE load-bearing byte-format contract here,
  ## exactly as `buildIndexStatement` documents for the whole-index case:
  ## milpa's verifier (`epoch_commitment.py::evaluate_epoch_commitment`,
  ## mirrored in Rust) passes `canonical_preimage(S)` — NOT the raw
  ## commitment digest bytes — as the composed verifier's `index_bytes`
  ## parameter and relies on that verifier's existing
  ## `sha256(index_bytes) == DSSE_subject_digest` check (the same check
  ## `index_trust.py` already performs for the whole-index bundle). Because
  ## `sha256(canonical_preimage(S)) == C` by construction, `subject[0].digest
  ## .sha256` here MUST be `C` itself — the caller's already-computed
  ## `preepoch_commitment.commitmentDigest(S)`, the bare 64-hex digest, no
  ## scheme prefix — never a re-hash of `commitmentDigest` and never the raw
  ## `S` bytes. `subject[0].name` is never inspected by milpa's verifier (RFC
  ## §6: predicate/subject-name contents are never inspected beyond the
  ## digest), so it is a fixed, human-readable marker rather than a derived
  ## coordinate — mirrors milpa's own minting-workflow convention for naming
  ## this subject.
  var subject = newJObject()
  subject["name"] = %"milpa-preepoch-set-commitment"
  var digest = newJObject()
  digest["sha256"] = %commitmentDigest
  subject["digest"] = digest

  var predicate = newJObject()
  predicate["attestation_kind"] = %"preepoch-set-commitment"
  predicate["signed_by"] = %signedBy

  var subjects = newJArray()
  subjects.add(subject)

  var statement = newJObject()
  statement["_type"] = %"https://in-toto.io/Statement/v1"
  statement["subject"] = subjects
  statement["predicateType"] = %"https://tianguis.dev/attestation/epoch-commitment/v1"
  statement["predicate"] = predicate

  $statement

proc extractStatementSubject*(statementJson: string): Result[StatementSubject, string] =
  ## Parse an in-toto Statement JSON — either this module's own
  ## `buildEntryStatement` output, or (S8) the byte-identical statement a CI
  ## crypto-verification step extracted from a cryptographically-verified
  ## author DSSE envelope — and pull out `subject[0].name` +
  ## `subject[0].digest.sha256`.
  ##
  ## This is the ONLY parsing half of the subject-binding check: the caller
  ## (`add-entry --entry-statement`, rfc-attestation-delivery S8) compares
  ## the returned tuple against `buildEntrySubjectName(...)` and
  ## `extractContentHashHex(...)` computed from tianguis's OWN recomputed
  ## content_hash — this proc never validates those values against
  ## anything, it only extracts them.
  ##
  ## Total over any string input: never raises. Malformed JSON or a
  ## missing/mis-shaped subject returns `Err` with a human-readable reason
  ## rather than letting a JSON exception escape into the CLI layer (the
  ## statement here is UNTRUSTED — it travelled over `repository_dispatch`
  ## before any crypto check ran).
  var j: JsonNode
  try:
    j = parseJson(statementJson)
  except CatchableError as e:
    return err[StatementSubject, string]("malformed statement JSON: " & e.msg)
  if j.kind != JObject:
    return err[StatementSubject, string]("statement is not a JSON object")
  if not j.hasKey("subject") or j["subject"].kind != JArray or j["subject"].len == 0:
    return err[StatementSubject, string]("statement missing non-empty 'subject' array")
  let subj = j["subject"][0]
  if subj.kind != JObject:
    return err[StatementSubject, string]("subject[0] is not a JSON object")
  if not subj.hasKey("name") or subj["name"].kind != JString:
    return err[StatementSubject, string]("subject[0].name missing or not a string")
  if not subj.hasKey("digest") or subj["digest"].kind != JObject:
    return err[StatementSubject, string]("subject[0].digest missing or not an object")
  let digest = subj["digest"]
  if not digest.hasKey("sha256") or digest["sha256"].kind != JString:
    return err[StatementSubject, string]("subject[0].digest.sha256 missing or not a string")
  ok[StatementSubject, string]((name: subj["name"].getStr, digestSha256: digest["sha256"].getStr))
