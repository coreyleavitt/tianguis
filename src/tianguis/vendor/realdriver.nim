## Real AddEntryDriver implementation — wraps subprocess `oras` for OCI
## artifact pulls and the existing identity algorithm for content hashing.
##
## No crypto here: cosign verify of the author signature happens in the
## commit-entry.yaml workflow before this CLI runs. See
## dispatch_security_architecture memory.

import std/[os, osproc, strutils, tempfiles]
import ../identity
import ./addentry

type RealAddEntryDriver* = ref object of AddEntryDriver

proc newRealAddEntryDriver*(): RealAddEntryDriver =
  RealAddEntryDriver()

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
