## Parse denylist.kdl — packages the vendoring bot must skip.
##
## Authors who don't want milpa-bot publishing index entries for their
## packages file an issue; we add a denylist entry. Existing vendored
## entries are not retroactively removed (would break lockfiles); they
## just stop receiving updates.
##
## Schema:
##   package "<name>" {
##       reason "<human-readable explanation>"
##   }

import std/[options, sets, tables]
import nkdl
import ../errors

export errors

type
  Denylist* = object
    names*: HashSet[string]

proc parseDenylist*(text: string): Denylist =
  ## Parse denylist.kdl text. Returns an empty denylist on empty input.
  ## Unknown nodes are tolerated (forward-compat); only `package "<name>"`
  ## entries are extracted.
  result = Denylist(names: initHashSet[string]())
  if text.len == 0: return
  let doc = parse(text)
  if doc.isErr: return  # malformed denylist treated as empty (defensive)
  for node in doc.get.nodes:
    if node.name == "package":
      let v = node.argStr(0)
      if v.isSome: result.names.incl(v.get)

proc contains*(dl: Denylist, packageName: string): bool =
  packageName in dl.names
