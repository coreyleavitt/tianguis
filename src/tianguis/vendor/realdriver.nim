## Real AddEntryDriver implementation — wraps subprocess `oras` for OCI
## artifact pulls and the existing identity algorithm for content hashing.
## Rekor verification via subprocess `cosign verify-blob`.
##
## Untested at unit level (subprocess I/O); exercised by Phase 3 end-to-end
## test with a real cosign-signed artifact.

import std/[os, osproc, strutils, tempfiles]
import ../identity
import ./addentry

type RealAddEntryDriver* = ref object of AddEntryDriver

proc newRealAddEntryDriver*(): RealAddEntryDriver =
  RealAddEntryDriver()

method verifyRekor*(d: RealAddEntryDriver, uuid: string, expected: AttestSubject): bool =
  ## Verify the Rekor entry independently. The dispatch endpoint attested
  ## this publish event; we re-fetch the entry by UUID and confirm the
  ## attested payload matches what the dispatched workflow_dispatch args
  ## claim.
  ##
  ## TODO (Phase 3): real sigstore verification via `cosign verify-blob`
  ## or `rekor-cli get --uuid <uuid>` + signature check. For now this
  ## stub fails closed; the workflow YAML can opt-in via env if needed
  ## during testing.
  let trustOverride = getEnv("TIANGUIS_TRUST_REKOR_PAYLOAD")
  if trustOverride == "1":
    # Test escape hatch — phase 3 will replace with real verification.
    return true
  stderr.writeLine("realdriver.verifyRekor: not yet implemented; refusing to commit")
  false

method pullAndHash*(d: RealAddEntryDriver, ociRef: string): tuple[hash, sha: string] =
  ## Pull the OCI artifact via `oras pull`, extract its bytes into a tmp
  ## dir, compute content_hash via the existing identity algorithm.
  ## Returns (contentHash, oci_digest_short_sha) for entry construction.
  let tmp = createTempDir("tianguis-pull-", "")
  defer: removeDir(tmp)
  # oras pull writes the artifact's layer files into the output dir.
  let (output, code) = execCmdEx("oras pull " & quoteShell(ociRef) & " --output " & quoteShell(tmp))
  if code != 0:
    raise newException(IOError, "oras pull failed: " & output)
  # The pulled artifact is typically a tarball — extract its contents
  # into a sibling dir before hashing, since identity wants the source
  # tree, not the tarball bytes.
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
