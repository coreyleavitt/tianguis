## tianguis binary entry point.
##
## Subcommands:
##   project [--check]   regenerate / verify index.json from index.kdl
##   vendor              run one vendor-en-absentia pass
##   add-entry           add an author-signed entry from dispatched payload
##                       (invoked by .github/workflows/commit-entry.yaml)

import std/[os, parseopt]
import tianguis/cli
import tianguis/vendor/[addentry, realdriver]

proc usage(): int =
  echo "usage: tianguis <command> [args]"
  echo ""
  echo "  project [--check]   regenerate index.json from index.kdl"
  echo "  vendor              run one vendor-en-absentia pass against nim-lang/packages.json"
  echo "  add-entry           add an author-signed entry; consumed from commit-entry.yaml"
  echo "    --name --oci-ref --namespace --upstream --signed-by --published-at --rekor-uuid"
  1

proc parseAddEntryArgs(parser: var OptParser): AddEntryArgs =
  ## Walk the remaining options; populate AddEntryArgs.
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument: discard
    of cmdLongOption:
      case key
      of "name":         result.name = val
      of "oci-ref":      result.ociRef = val
      of "namespace":    result.namespace = val
      of "upstream":     result.upstream = val
      of "signed-by":    result.signedBy = val
      of "published-at": result.publishedAt = val
      of "rekor-uuid":   result.rekorUuid = val
      else:
        stderr.writeLine("tianguis add-entry: unknown option --" & key)
    of cmdShortOption: discard
    of cmdEnd: discard

proc main(): int =
  # First pass: pull the verb out of the args (parseopt walks once).
  var p = initOptParser()
  var verb = ""
  var check = false
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if verb == "":
        verb = key
      # subcommand-specific positional args (none today) would land here
    of cmdLongOption, cmdShortOption:
      case key
      of "check": check = true
      of "help", "h":
        discard usage()
        return 0
      else:
        # Subcommand-specific options handled below per-verb.
        # Stash by re-initializing parser inside the dispatch.
        discard
    of cmdEnd: discard

  case verb
  of "":
    return usage()
  of "project":
    return cmdProject(getCurrentDir(), check = check)
  of "vendor":
    return cmdVendor(getCurrentDir())
  of "add-entry":
    # Re-parse for the subcommand's options (parseopt was consumed above).
    var sub = initOptParser()
    discard sub  # skip the verb itself
    var saw_add = false
    for kind, key, val in sub.getopt():
      if kind == cmdArgument and key == "add-entry":
        saw_add = true
        break
    let args = parseAddEntryArgs(sub)
    return cmdAddEntry(
      projectDir = getCurrentDir(),
      args = args,
      driver = newRealAddEntryDriver(),
    )
  else:
    stderr.writeLine("tianguis: unknown command '" & verb & "'")
    return usage()

when isMainModule:
  quit(main())
