## Corpus-driven conformance test for deriveNamespace.
##
## Reads spec/fixtures/derive-namespace.json — the single-source-of-truth oracle
## that every implementation (Nim now, Python later) runs against.  Any case
## mismatch causes a test failure; the corpus is therefore load-bearing.
##
## Cross-repo note: the JSON is impl-agnostic (no Nim-specific encoding) so
## milpa's Python suite can import it directly.

import std/[unittest, json, os]
import tianguis/namespace

const CORPUS_PATH =
  currentSourcePath().parentDir().parentDir() / "spec" / "fixtures" / "derive-namespace.json"

suite "deriveNamespace — corpus":
  let corpus = parseFile(CORPUS_PATH)
  for i, entry in corpus.getElems:
    let inputUrl = entry["input_url"].getStr

    if entry.hasKey("expected_namespace"):
      let expected = entry["expected_namespace"].getStr
      test "case " & $i & ": " & inputUrl & " → " & expected:
        let r = deriveNamespace(inputUrl)
        check r.isOk
        if r.isOk:
          check namespaceString(r.get) == expected

    elif entry.hasKey("expected_error"):
      let errCode = entry["expected_error"].getStr
      test "case " & $i & ": " & inputUrl & " → " & errCode:
        let r = deriveNamespace(inputUrl)
        check r.isErr
        if r.isErr:
          case errCode
          of "derrNoOrg":             check r.error == derrNoOrg
          of "derrGitlabNestedGroup": check r.error == derrGitlabNestedGroup
          of "derrUnparseable":       check r.error == derrUnparseable
          else:
            # Unknown error code in the corpus — fail loudly
            check false

    else:
      # Malformed corpus entry — fail loudly (neither expected_namespace nor expected_error)
      test "case " & $i & ": malformed corpus entry (missing expected_namespace or expected_error)":
        check false
