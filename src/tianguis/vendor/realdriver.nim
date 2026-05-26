## Real AddEntryDriver implementation — wraps subprocess `oras` for OCI
## artifact pulls, the existing identity algorithm for content hashing,
## and `cosign verify-blob` for Rekor entry verification.
##
## Why shell to cosign instead of FFI to sigstore-go:
##   - cosign is the canonical Sigstore client; its CLI is a supported
##     interface upstream commits to
##   - subprocess overhead (~200ms) is irrelevant for our workload
##     (one verify per commit; we're not in a hot path)
##   - we don't ship/audit/maintain crypto code
##   - workflow already needs cosign installed for users to publish
## See dispatch_security_architecture memory + the Phase 3 discussion.

import std/[base64, json, os, osproc, strutils, tempfiles]
import ../identity
import ./addentry

type RealAddEntryDriver* = ref object of AddEntryDriver

proc newRealAddEntryDriver*(): RealAddEntryDriver =
  RealAddEntryDriver()

# ---------------------------------------------------------------------------
# Rekor verification — shell to cosign + rekor-cli
#
# Flow:
#   1. rekor-cli get --uuid <uuid> --format json → returns the entry's
#      Body (base64 of the in-toto envelope) plus integratedTime + logIndex
#   2. Extract the payload from the envelope, base64-decode
#   3. Parse the in-toto statement (subject, predicate)
#   4. Verify cosign signature on the envelope using the dispatch identity
#      (cosign verify-blob --bundle <bundle> --certificate-identity ...)
#   5. Cross-check the verified predicate's fields against expected
# ---------------------------------------------------------------------------

const
  RekorURL          = "https://rekor.sigstore.dev"
  # Dispatch's OIDC identity — when dispatch runs in Scaleway, it signs
  # via Sigstore keyless using whatever OIDC identity dispatch presents
  # to Fulcio. For initial phase 3 we use github-actions identity as a
  # placeholder; switch to Scaleway's OIDC issuer when dispatch's real
  # Rekor attest goes live.
  DispatchIdentityRegex = "^https://github\\.com/coreyleavitt/tianguis/"
  DispatchOIDCIssuer    = "https://token.actions.githubusercontent.com"

# decodeDsseStatement — extract the in-toto statement JSON from a Rekor
# entry's Body field. Declared before verifyRekor (Nim resolves top-to-
# bottom). DSSE intoto entries have shape:
#   { intotoObj: { content: { envelope: { payload: <base64> } } } }
# Returns "" for non-DSSE entry kinds (HashedRekord etc.) — supports
# the dispatch attestation shape only for now.
proc decodeDsseStatement*(body: JsonNode): string =
  try:
    let env = body{"intotoObj"}{"content"}{"envelope"}
    if env == nil: return ""
    let payloadB64 = env{"payload"}.getStr("")
    if payloadB64 == "": return ""
    return base64.decode(payloadB64)
  except CatchableError:
    return ""

method verifyRekor*(d: RealAddEntryDriver, uuid: string, expected: AttestSubject): bool =
  ## Verify the Rekor entry referenced by uuid + confirm its payload
  ## matches the dispatched args. Returns true only if BOTH the cosign
  ## signature verifies against dispatch's identity AND the predicate
  ## fields equal what we expected.
  let (entryJson, getCode) = execCmdEx(
    "rekor-cli get --rekor_server " & RekorURL &
    " --uuid " & quoteShell(uuid) & " --format json"
  )
  if getCode != 0:
    stderr.writeLine("rekor-cli get failed (uuid=" & uuid & "): " & entryJson)
    return false

  # rekor-cli get returns a JSON object containing the entry. The Body
  # field is base64 of a HashedRekord or DSSE envelope; the in-toto
  # statement we want is in the DSSE payload.
  let entry = try: parseJson(entryJson)
              except CatchableError as e:
                stderr.writeLine("rekor entry not parseable: " & e.msg); return false

  # Extract the in-toto statement. Real implementation depends on the
  # entry type (HashedRekord, DSSE Intoto, etc.). For dispatch's attestation
  # we use DSSE → unwrap envelope.payload (base64) → JSON statement.
  let body = entry{"Body"}
  if body == nil:
    stderr.writeLine("rekor entry has no Body field")
    return false
  let statementJson = decodeDsseStatement(body)
  if statementJson == "":
    stderr.writeLine("could not extract in-toto statement from rekor entry")
    return false

  let stmt = try: parseJson(statementJson)
             except CatchableError as e:
               stderr.writeLine("in-toto statement not parseable: " & e.msg); return false
  let predicate = stmt{"predicate"}
  if predicate == nil:
    stderr.writeLine("in-toto statement has no predicate")
    return false

  # Cross-check predicate fields against expected.
  if predicate{"name"}.getStr("") != expected.name:
    stderr.writeLine("predicate.name mismatch: got " & predicate{"name"}.getStr & " want " & expected.name); return false
  if predicate{"oci_ref"}.getStr("") != expected.ociRef:
    stderr.writeLine("predicate.oci_ref mismatch"); return false
  if predicate{"repo_url"}.getStr("") != expected.repoUrl:
    stderr.writeLine("predicate.repo_url mismatch"); return false
  if predicate{"signer_identity"}.getStr("") != expected.signerIdentity:
    stderr.writeLine("predicate.signer_identity mismatch"); return false

  # Verify cosign signature on the entry. For attestations stored in
  # Rekor with DSSE, cosign verify-blob-attestation handles it.
  let bundleTmp = createTempFile("tianguis-bundle-", ".json").path
  defer: removeFile(bundleTmp)
  writeFile(bundleTmp, entryJson)
  let (verifyOut, verifyCode) = execCmdEx(
    "cosign verify-blob-attestation " &
    "--bundle " & quoteShell(bundleTmp) & " " &
    "--certificate-identity-regexp " & quoteShell(DispatchIdentityRegex) & " " &
    "--certificate-oidc-issuer " & quoteShell(DispatchOIDCIssuer)
  )
  if verifyCode != 0:
    stderr.writeLine("cosign verify-blob-attestation failed: " & verifyOut)
    return false
  true

# ---------------------------------------------------------------------------
# OCI artifact pull + hash — shells to oras + tar, runs identity algorithm
# ---------------------------------------------------------------------------

method pullAndHash*(d: RealAddEntryDriver, ociRef: string): tuple[hash, sha: string] =
  let tmp = createTempDir("tianguis-pull-", "")
  defer: removeDir(tmp)
  let (output, code) = execCmdEx("oras pull " & quoteShell(ociRef) & " --output " & quoteShell(tmp))
  if code != 0:
    raise newException(IOError, "oras pull failed: " & output)
  let extracted = tmp / "_tianguis_extracted"
  createDir(extracted)
  for kind, path in walkDir(tmp):
    if kind == pcFile and path.endsWith(".tar.gz"):
      let (extOutput, extCode) = execCmdEx("tar -xzf " & quoteShell(path) &
                                            " -C " & quoteShell(extracted))
      if extCode != 0:
        raise newException(IOError, "tar extract failed: " & extOutput)
  let hash = computeContentHash(extracted)
  let atIdx = ociRef.find('@')
  let shortSha = if atIdx >= 0 and ociRef.len > atIdx + 14: ociRef[atIdx + 8 .. atIdx + 14]
                 else: ""
  (hash, shortSha)
