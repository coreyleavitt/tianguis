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

import std/[sets, tables]
import kdl
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
    if doc.get.interner.lookup(node.name) == "package" and node.entries.len > 0:
      result.names.incl(node.entries[0].argValue.strVal)

proc contains*(dl: Denylist, packageName: string): bool =
  packageName in dl.names
