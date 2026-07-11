## CLI tests for `tianguis derive-namespace` — the S8 Layer 2a single-source
## seam for namespace derivation from a signer identity.
##
## Both `add-entry` (server-side, from the cryptographically-verified
## `--signed-by`) and any client-side caller (the publish composite action,
## building the purl for `attest-statement --namespace=…`) MUST derive the
## exact same namespace from the exact same signed-by/SAN value, or the §1
## subject-name binding check (`add-entry --entry-statement`) rejects every
## publish. This subcommand exposes `namespace.deriveNamespace` over the CLI
## so nothing client-side re-implements (and risks diverging from) that
## derivation.

import std/unittest
import tianguis/[cli, namespace]

suite "cli derive-namespace":
  test "emits exactly deriveNamespace(signedBy)'s namespaceString for a plain org URL":
    let signedBy = "https://github.com/coreyleavitt/tianguis"
    let r = deriveNamespaceResult(signedBy)
    check r.code == 0
    check r.stderr == ""
    let expected = namespaceString(deriveNamespace(signedBy).get)
    check r.stdout == expected
    check r.stdout == "github.com/coreyleavitt"

  test "real GH-Actions workflow SAN derives to github.com/<owner>":
    let signedBy = "https://github.com/alice/foo/.github/workflows/release.yaml@refs/tags/v1"
    let r = deriveNamespaceResult(signedBy)
    check r.code == 0
    check r.stderr == ""
    check r.stdout == "github.com/alice"
    # sanity: matches the shared parser directly, not a re-derivation
    check r.stdout == namespaceString(deriveNamespace(signedBy).get)

  test "another author's GH-Actions SAN derives to a DIFFERENT namespace":
    let signedBy = "https://github.com/bob/bar/.github/workflows/publish.yaml@refs/heads/main"
    let r = deriveNamespaceResult(signedBy)
    check r.code == 0
    check r.stdout == "github.com/bob"

  test "missing --signed-by fails: exit 4, empty stdout, non-empty stderr":
    let r = deriveNamespaceResult("")
    check r.code == 4
    check r.stdout == ""
    check r.stderr.len > 0

  test "unparseable signed-by fails: non-zero exit, empty stdout":
    let r = deriveNamespaceResult("not a url at all")
    check r.code != 0
    check r.stdout == ""
    check r.stderr.len > 0

  test "bare host with no org segment fails":
    let r = deriveNamespaceResult("https://github.com")
    check r.code != 0
    check r.stdout == ""

  test "cmdDeriveNamespace (I/O wrapper) mirrors the pure core's exit code":
    check cmdDeriveNamespace("https://github.com/coreyleavitt/tianguis") == 0
    check cmdDeriveNamespace("") == 4

  test "determinism: same input produces byte-identical output":
    let signedBy = "https://github.com/coreyleavitt/nkdl/.github/workflows/publish.yaml@refs/tags/v1.0.0"
    let a = deriveNamespaceResult(signedBy)
    let b = deriveNamespaceResult(signedBy)
    check a.stdout == b.stdout
