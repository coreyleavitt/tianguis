## tianguis binary entry point.
##
## Currently exposes one subcommand: `tianguis project [--check]`.
## Future R5 subcommands (publish helpers, frontend) layer on the
## same dispatch.

import std/[os, parseopt]
import tianguis/cli

proc usage(): int =
  echo "usage: tianguis <command> [args]"
  echo ""
  echo "  project           regenerate index.json from index.kdl"
  echo "  project --check   verify index.json matches index.kdl; exit non-zero on drift"
  echo "  vendor            run one vendor-en-absentia pass against nim-lang/packages.json"
  1

proc main(): int =
  var args: seq[string] = @[]
  var check = false
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: args.add(key)
    of cmdShortOption, cmdLongOption:
      case key
      of "check": check = true
      of "help", "h":
        discard usage()
        return 0
      else:
        stderr.writeLine("tianguis: unknown option --" & key)
        return usage()
    of cmdEnd: discard

  if args.len == 0:
    return usage()

  case args[0]
  of "project":
    return cmdProject(getCurrentDir(), check = check)
  of "vendor":
    return cmdVendor(getCurrentDir())
  else:
    stderr.writeLine("tianguis: unknown command '" & args[0] & "'")
    return usage()

when isMainModule:
  quit(main())
