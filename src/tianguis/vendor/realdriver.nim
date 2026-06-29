## Real AddEntryDriver implementation — delegates OCI pull + content hashing
## to `milpa hash oci=<ref>`, the canonical SSOT for content-addressed identity.
##
## No crypto here: cosign verify of the author signature happens in the
## commit-entry.yaml workflow before this CLI runs. See
## dispatch_security_architecture memory.

import std/[osproc, strutils]
import ./addentry

type RealAddEntryDriver* = ref object of AddEntryDriver

proc newRealAddEntryDriver*(): RealAddEntryDriver =
  RealAddEntryDriver()

method pullAndHash*(d: RealAddEntryDriver, ociRef: string): tuple[hash, sha: string] =
  # Delegate OCI pull + extract + identity hash to milpa's OciFetcher.
  # milpa emits a single `dag-sha256:…` line; strip whitespace to get the hash.
  let (hashOut, hashCode) = execCmdEx("milpa hash " & quoteShell("oci=" & ociRef))
  if hashCode != 0:
    raise newException(IOError,
      "milpa hash failed (exit " & $hashCode & "): " & hashOut)
  let hash = strip(hashOut)
  let atIdx = ociRef.find('@')
  let shortSha = if atIdx >= 0 and ociRef.len > atIdx + 14: ociRef[atIdx + 8 .. atIdx + 14]
                 else: ""
  (hash, shortSha)
