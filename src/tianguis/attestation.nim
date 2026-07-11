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
