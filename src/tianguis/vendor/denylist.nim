## Parse denylist.kdl — packages the vendoring bot must skip.
##
## Authors who don't want milpa-bot publishing index entries for their
## packages file an issue; we add a denylist entry. Existing vendored
## entries are not retroactively removed (would break lockfiles); they
## just stop receiving updates.
##
## Schema:
##   package "<name>" {
##       namespace "<host/org>"
##       reason "<human-readable explanation>"
##   }
##
## The key is the QUALIFIED (namespace, name) tuple — a denylist entry
## blocks one publisher's package, NOT every package sharing a leaf name.

import std/[options, sets]
import nkdl
import ../errors

export errors

type
  Denylist* = object
    entries*: HashSet[tuple[namespace, name: string]]

proc parseDenylist*(text: string): Denylist =
  ## Parse denylist.kdl text. Returns an empty denylist on empty input.
  ## Unknown nodes are tolerated (forward-compat); only `package "<name>"`
  ## entries with a `namespace "<host/org>"` child are extracted.
  result = Denylist(entries: initHashSet[tuple[namespace, name: string]]())
  if text.len == 0: return
  let doc = parse(text)
  if doc.isErr: return  # malformed denylist treated as empty (defensive)
  for node in doc.get.nodes:
    if node.name == "package":
      let nameOpt = node.argStr(0)
      if nameOpt.isNone: continue
      # Extract the namespace child's first arg (the host/org string).
      let nsNode = node.child("namespace")
      if nsNode.isNil: continue
      let nsOpt = nsNode.argStr(0)
      if nsOpt.isNone: continue
      result.entries.incl((namespace: nsOpt.get, name: nameOpt.get))

proc contains*(dl: Denylist, namespace, name: string): bool =
  ## Return true iff the qualified (namespace, name) pair is denylisted.
  (namespace: namespace, name: name) in dl.entries
