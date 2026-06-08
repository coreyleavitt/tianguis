## Shared filesystem utilities.
##
## Provides atomicWrite — write to a staging file then rename into place,
## so the target file is never observed in a partially-written state.
##
## Single source of truth: cmd_migrate.nim previously contained a local copy;
## addentry.nim uses this for the live publish path.

import std/os

proc atomicWrite*(dest, content: string) =
  ## Write `content` to a `.tmp` staging file then rename it over `dest`.
  ##
  ## On success, no staging file remains (rename is atomic on POSIX). On
  ## moveFile failure the `.tmp` file is cleaned up via defer so it does
  ## not accumulate on disk.
  let staging = dest & ".tmp"
  defer:
    # Clean up staging file if it still exists after moveFile failure.
    if fileExists(staging):
      try: removeFile(staging)
      except: discard
  writeFile(staging, content)
  moveFile(staging, dest)
