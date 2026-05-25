## Content-hash identity algorithm — port of milpa's identity.py.
##
## See milpa/docs/rfc-content-addressed-identity.md §"What exactly is 'content'"
## for the bytes-level spec; this module's output must be bit-identical to
## milpa's compute_content_hash on every input.
##
## Algorithm (canonical):
##
##   For each entry under `path`, sorted by POSIX relpath, excluding .git/:
##       relpath_bytes + 0x00 + mode_marker + 0x00 + entry_content + 0x00
##
##   mode_marker:
##     0x00 — regular file, non-executable
##     0x01 — regular file, executable (owner-execute bit set)
##     0x80 — symlink (content is the link target string as UTF-8)
##
##   Empty directories are not hashed.
##   Final output: "sha256:<hex>" (multihash-encoded, lowercase hex).

import std/[algorithm, os, posix, strutils]
import nimcrypto/[hash, sha2]

const
  MODE_REGULAR*    = 0x00'u8
  MODE_EXECUTABLE* = 0x01'u8
  MODE_SYMLINK*    = 0x80'u8

type
  EntryKind = enum
    ekFile, ekSymlink

  Entry = object
    relpath: string         ## POSIX relpath (forward slashes)
    modeMarker: uint8
    content: string         ## file contents or symlink target

proc isExecutable(path: string): bool =
  ## True iff the owner-execute bit is set (matches Python's stat.S_IXUSR).
  var st: Stat
  if stat(path.cstring, st) != 0:
    return false
  (st.st_mode.uint32 and S_IXUSR.uint32) != 0

proc enumerateEntries(root: string): seq[Entry] =
  ## Walk `root`, collecting one Entry per regular file or symlink.
  ## Skips .git/ at any depth and directories themselves.
  result = @[]
  for path in walkDirRec(root,
                         yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir},
                         relative = true,
                         followFilter = {pcDir}):
    # Exclude anything under .git/ at any depth.
    var skip = false
    for part in path.split(DirSep):
      if part == ".git":
        skip = true
        break
    if skip:
      continue

    let absPath = root / path
    # Normalize relpath to POSIX (forward slashes) for parity with
    # milpa's `as_posix()`.
    let relposix = path.replace(DirSep, '/')

    if symlinkExists(absPath):
      let target = expandSymlink(absPath)
      result.add(Entry(
        relpath: relposix,
        modeMarker: MODE_SYMLINK,
        content: target,
      ))
    elif fileExists(absPath):
      let marker = if isExecutable(absPath): MODE_EXECUTABLE else: MODE_REGULAR
      result.add(Entry(
        relpath: relposix,
        modeMarker: marker,
        content: readFile(absPath),
      ))

  result.sort(proc(a, b: Entry): int = cmp(a.relpath, b.relpath))

proc computeContentHash*(path: string): string =
  ## Compute the sha256 content hash of the source tree at `path`.
  ## Returns the multihash-encoded identity string `sha256:<64-hex>`.
  var ctx: sha256
  ctx.init()
  for e in enumerateEntries(path):
    ctx.update(cast[seq[byte]](e.relpath))
    ctx.update([0'u8])
    ctx.update([e.modeMarker])
    ctx.update([0'u8])
    ctx.update(cast[seq[byte]](e.content))
    ctx.update([0'u8])
  let digest = ctx.finish()
  "sha256:" & toLowerAscii($digest)
