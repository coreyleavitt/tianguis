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

import std/[os, parseopt, strutils]
import tianguis/cli
import tianguis/cmd_migrate
import tianguis/cmd_set_attestation_epoch
import tianguis/vendor/[addentry, realdriver]

proc usage(): int =
  echo "usage: tianguis <command> [args]"
  echo ""
  echo "  project [--check]   regenerate index.json from index.kdl"
  echo "  vendor              run one vendor-en-absentia pass against nim-lang/packages.json"
  echo "    [--emit-bundle-candidates=<path>] write post-epoch entries still needing a"
  echo "      minted attestation bundle to <path> as JSON (rfc-attestation-delivery S7b;"
  echo "      consumed by vendor.yaml's mint loop, never re-fetched from upstream)"
  echo "    [--bundle-pins=<path>]      apply-only pass: NO network, merges entries from a"
  echo "      previously-minted pins file (produced from the candidates above) into"
  echo "      index.kdl; takes precedence over --emit-bundle-candidates if both are given"
  echo "  backfill            full-index sweep: mint bundles for EXISTING entries that lack"
  echo "                      a bundle pin (rfc-attestation-delivery S9). NO network/Driver;"
  echo "                      same two-phase shape as `vendor`'s candidate/pin flow, but its"
  echo "                      OWN apply path (`--bundle-pins` here, not `vendor --bundle-pins`"
  echo "                      — that one silently no-ops on already-committed entries)"
  echo "    --emit-bundle-candidates=<path>  write eligible existing entries as JSON (same"
  echo "      BundleCandidate shape S7b uses)"
  echo "    [--cap=<n>]  bound how many candidates this pass emits (0/absent = unlimited);"
  echo "      skipped-beyond-cap count is logged to stderr, never silently dropped"
  echo "    --bundle-pins=<path>  apply-only pass: sets bundlePin on each matching EXISTING"
  echo "      entry from a previously-minted pins file; takes precedence over"
  echo "      --emit-bundle-candidates if both are given"
  echo "    (only milpa-vendored, already-pinless entries are eligible; author-signed"
  echo "     entries are never backfilled — that would misattribute authorship)"
  echo "  reindex             epoch-migration: re-vendor all packages and re-baseline content_hash to dag-sha256"
  echo "  add-entry           add an author-signed entry; consumed from commit-entry.yaml"
  echo "    --name --version --oci-ref --upstream --signed-by [--published-at]"
  echo "    [--rekor-uuid --rekor-log-index --rekor-integrated-time]"
  echo "    [--bundle-pin --entry-statement] [--source=<git-url>]"
  echo "    (namespace is derived inside the binary from the verified OIDC SAN in --signed-by;"
  echo "     rekor fields are the durable transparency-log pointer captured by commit-entry.yaml;"
  echo "     --bundle-pin is the sha256 hex of the minted attestation bundle's bytes, S7b/S7a;"
  echo "     --entry-statement=<path> is a CI-crypto-VERIFIED in-toto statement JSON file (S8) —"
  echo "     add-entry binds its subject[0].digest.sha256/name to the content_hash it just"
  echo "     recomputed + the purl it derives, rejecting (exit 5) on any mismatch; must be"
  echo "     supplied together with --bundle-pin, or neither;"
  echo "     --source=<git-url> is the SOURCE git repo this OCI artifact was published from"
  echo "     (milpa `publish --output`'s source_url), recorded on the oci provenance's"
  echo "     `source` child; empty/omitted stays absent, same as commit_sha on git provenance)"
  echo "  attest-statement    print the S3 in-toto statement JSON for one entry (S7c)"
  echo "    --namespace --name --version --content-hash --attestation-kind --signed-by"
  echo "    (single source of truth for the bytes scripts/sign_statement.py signs;"
  echo "     never re-derive this statement in Python)"
  echo "  attest-index-statement  print the whole-index in-toto statement JSON (subject ="
  echo "                          index.kdl); consumed by .github/workflows/attest-index.yaml"
  echo "    --content-hash --signed-by"
  echo "    (--content-hash is the sha256 hex of the raw index.kdl bytes, no scheme prefix;"
  echo "     single source of truth for the bytes scripts/sign_statement.py signs into"
  echo "     index.kdl.bundle — the fix for TNG-INDEX-BUNDLE-MISSING)"
  echo "  show <url>          derive and print the namespace (host/org) for an upstream URL"
  echo "  derive-namespace    print the namespace (host/org) for a --signed-by OIDC SAN (S8 Layer 2a)"
  echo "    --signed-by=<url-or-SAN>"
  echo "    (single source of truth for namespace derivation from a signer identity;"
  echo "     both add-entry and any client-side caller — e.g. the publish composite"
  echo "     action — MUST derive the exact same namespace from the exact same"
  echo "     --signed-by value, or the §1 subject-name binding check rejects every"
  echo "     publish; this subcommand is that shared derivation, exposed over the CLI)"
  echo "  migrate [--execute] one-time #32 namespace migration; --dry-run is default"
  echo "  set-attestation-epoch --epoch=<ISO8601>  arm the S5 strict-attestation gate"
  echo "    registry-wide (rfc-attestation-delivery S5; tianguis#42). SET-ONCE: refuses"
  echo "    if attestation-epoch is already set. SAFETY: refuses if arming this epoch"
  echo "    would make any EXISTING entry violate the gate (pinless/unattested entry"
  echo "    whose published_at >= epoch) — backfill those first. --epoch must be the"
  echo "    exact YYYY-MM-DDTHH:MM:SSZ shape (same as published_at)."
  1

proc splitLongOpt(a: string): (string, string) =
  ## Split a "--key=val" argument into (key, val). Both "--key" (no '=') and
  ## an explicit empty "--key=" yield an empty val, and the NEXT argument is
  ## never consumed.
  ##
  ## Why not `std/parseopt` here: `parseopt.getopt` looks ahead for a value
  ## when a long option's value is empty, so a stray `--source=` swallows the
  ## FOLLOWING `--signed-by=…` as its value — which zeroed out signed_by and
  ## broke first-package onboarding (the empty `--source=` came from
  ## commit-entry.yaml when a package had no source URL; that side now omits
  ## the flag entirely, and this manual split is immune regardless).
  let body = a[2 .. ^1]                 # caller guarantees the leading "--"
  let eq = body.find('=')
  if eq < 0: (body, "")
  else: (body[0 ..< eq], body[eq + 1 .. ^1])

proc parseAddEntryArgs(args: seq[string]): AddEntryArgs =
  ## Parse add-entry's long options from the raw argv (manual split — see
  ## `splitLongOpt`). Non-`--` args (the verb, any positional) are skipped.
  for a in args:
    if not a.startsWith("--"):
      continue
    let (key, val) = splitLongOpt(a)
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
    of "entry-statement":       result.entryStatementPath = val
    of "source":                result.sourceUrl = val
    of "namespace":
      stderr.writeLine("tianguis add-entry: --namespace is no longer accepted;" &
        " namespace is derived from --signed-by (P2.1)")
      quit(4)
    else:
      stderr.writeLine("tianguis add-entry: unknown option --" & key)

proc parseAttestIndexStatementArgs(parser: var OptParser): AttestIndexStatementArgs =
  ## Walk the remaining options; populate AttestIndexStatementArgs.
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument: discard
    of cmdLongOption:
      case key
      of "content-hash": result.contentHash = val
      of "signed-by":     result.signedBy = val
      else:
        stderr.writeLine("tianguis attest-index-statement: unknown option --" & key)
    of cmdShortOption: discard
    of cmdEnd: discard

proc parseDeriveNamespaceArgs(parser: var OptParser): string =
  ## Walk the remaining options; return the `--signed-by` value (empty if
  ## not supplied — `deriveNamespaceResult` rejects that with exit 4).
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument: discard
    of cmdLongOption:
      case key
      of "signed-by": result = val
      else:
        stderr.writeLine("tianguis derive-namespace: unknown option --" & key)
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
  var emitCandidatesPath = ""
  var bundlePinsPath = ""
  var backfillCap = 0
  var epochArg = ""
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
      of "emit-bundle-candidates": emitCandidatesPath = val
      of "bundle-pins": bundlePinsPath = val
      of "epoch": epochArg = val
      of "cap":
        try: backfillCap = parseInt(val)
        except ValueError:
          stderr.writeLine("tianguis: --cap must be an integer, got: " & val)
          return 4
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
    return cmdVendor(getCurrentDir(),
      emitCandidatesPath = emitCandidatesPath,
      bundlePinsPath = bundlePinsPath)
  of "backfill":
    return cmdBackfill(getCurrentDir(),
      emitCandidatesPath = emitCandidatesPath,
      bundlePinsPath = bundlePinsPath,
      cap = backfillCap)
  of "reindex":
    return cmdReindex(getCurrentDir())
  of "show":
    if showUrl == "":
      stderr.writeLine("tianguis show: missing <url> argument")
      return usage()
    return cmdShow(showUrl)
  of "add-entry":
    # Parse the subcommand's long options straight from the raw argv (manual
    # split — never parseopt's lookahead, which an empty `--key=` abuses).
    let args = parseAddEntryArgs(commandLineParams())
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
  of "attest-index-statement":
    # Re-parse for the subcommand's options (parseopt was consumed above).
    var sub = initOptParser()
    let args = parseAttestIndexStatementArgs(sub)
    return cmdAttestIndexStatement(args)
  of "derive-namespace":
    # Re-parse for the subcommand's options (parseopt was consumed above).
    var sub = initOptParser()
    let signedBy = parseDeriveNamespaceArgs(sub)
    return cmdDeriveNamespace(signedBy)
  of "migrate":
    return cmdMigrate(getCurrentDir(), execute = execute)
  of "set-attestation-epoch":
    return cmdSetAttestationEpoch(getCurrentDir(), epochArg)
  else:
    stderr.writeLine("tianguis: unknown command '" & verb & "'")
    return usage()

when isMainModule:
  quit(main())
