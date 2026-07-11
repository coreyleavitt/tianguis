## tianguis binary entry point.
##
## Subcommands:
##   project [--check]   regenerate / verify index.json from index.kdl
##   vendor              run one vendor-en-absentia pass
##   reindex             epoch-migration: re-vendor all packages, re-baseline
##                       content_hash to dag-sha256 (one-shot, auditable)
##   add-entry           add an author-signed entry from dispatched payload
##                       (invoked by .github/workflows/commit-entry.yaml)
##   migrate [--execute] one-time #32 namespace migration (dry-run by default)

import std/[os, parseopt]
import tianguis/cli
import tianguis/cmd_migrate
import tianguis/vendor/[addentry, realdriver]

proc usage(): int =
  echo "usage: tianguis <command> [args]"
  echo ""
  echo "  project [--check]   regenerate index.json from index.kdl"
  echo "  vendor              run one vendor-en-absentia pass against nim-lang/packages.json"
  echo "  reindex             epoch-migration: re-vendor all packages and re-baseline content_hash to dag-sha256"
  echo "  add-entry           add an author-signed entry; consumed from commit-entry.yaml"
  echo "    --name --version --oci-ref --upstream --signed-by [--published-at]"
  echo "    [--rekor-uuid --rekor-log-index --rekor-integrated-time] [--bundle-pin]"
  echo "    (namespace is derived inside the binary from the verified OIDC SAN in --signed-by;"
  echo "     rekor fields are the durable transparency-log pointer captured by commit-entry.yaml;"
  echo "     --bundle-pin is the sha256 hex of the minted attestation bundle's bytes, S7b)"
  echo "  attest-statement    print the S3 in-toto statement JSON for one entry (S7c)"
  echo "    --namespace --name --version --content-hash --attestation-kind --signed-by"
  echo "    (single source of truth for the bytes scripts/sign_statement.py signs;"
  echo "     never re-derive this statement in Python)"
  echo "  show <url>          derive and print the namespace (host/org) for an upstream URL"
  echo "  migrate [--execute] one-time #32 namespace migration; --dry-run is default"
  1

proc parseAddEntryArgs(parser: var OptParser): AddEntryArgs =
  ## Walk the remaining options; populate AddEntryArgs.
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument: discard
    of cmdLongOption:
      case key
      of "name":         result.name = val
      of "version":      result.version = val
      of "oci-ref":      result.ociRef = val
      of "upstream":     result.upstream = val
      of "signed-by":    result.signedBy = val
      of "published-at": result.publishedAt = val
      of "rekor-uuid":            result.rekorUuid = val
      of "rekor-log-index":       result.rekorLogIndex = val
      of "rekor-integrated-time": result.rekorIntegratedTime = val
      of "bundle-pin":            result.bundlePin = val
      of "namespace":
        stderr.writeLine("tianguis add-entry: --namespace is no longer accepted;" &
          " namespace is derived from --signed-by (P2.1)")
        quit(4)
      else:
        stderr.writeLine("tianguis add-entry: unknown option --" & key)
    of cmdShortOption: discard
    of cmdEnd: discard

proc parseAttestStatementArgs(parser: var OptParser): AttestStatementArgs =
  ## Walk the remaining options; populate AttestStatementArgs. Unlike
  ## add-entry, `--namespace` IS accepted here — this command has no OIDC
  ## SAN to derive it from (it's the pure S3 statement builder, invoked
  ## before any signing/dispatch has happened).
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument: discard
    of cmdLongOption:
      case key
      of "namespace":        result.namespace = val
      of "name":             result.name = val
      of "version":          result.version = val
      of "content-hash":     result.contentHash = val
      of "attestation-kind": result.attestationKind = val
      of "signed-by":        result.signedBy = val
      else:
        stderr.writeLine("tianguis attest-statement: unknown option --" & key)
    of cmdShortOption: discard
    of cmdEnd: discard

proc main(): int =
  # First pass: pull the verb out of the args (parseopt walks once).
  var p = initOptParser()
  var verb = ""
  var check = false
  var showUrl = ""
  var execute = false
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if verb == "":
        verb = key
      elif verb == "show" and showUrl == "":
        showUrl = key
      # other subcommand-specific positional args would land here
    of cmdLongOption, cmdShortOption:
      case key
      of "check": check = true
      of "execute": execute = true
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
  of "reindex":
    return cmdReindex(getCurrentDir())
  of "show":
    if showUrl == "":
      stderr.writeLine("tianguis show: missing <url> argument")
      return usage()
    return cmdShow(showUrl)
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
  of "attest-statement":
    # Re-parse for the subcommand's options (parseopt was consumed above).
    var sub = initOptParser()
    let args = parseAttestStatementArgs(sub)
    return cmdAttestStatement(args)
  of "migrate":
    return cmdMigrate(getCurrentDir(), execute = execute)
  else:
    stderr.writeLine("tianguis: unknown command '" & verb & "'")
    return usage()

when isMainModule:
  quit(main())
