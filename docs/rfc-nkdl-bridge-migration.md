# RFC: Migrate tianguis KDL I/O to the nkdl bridge API

**Status:** DRAFT (2026-06-06) — Stage 1 of `/flow`. A contained, low-design-risk
*mechanical migration* (not a research RFC): tianguis is pinned to a pre-rebuild nkdl
(`coreyleavitt/nkdl`, the lib it imports as `kdl`); the library was rewritten
(self-contained ref-AST + a new public consumer API). This ports tianguis's KDL I/O
onto the new API.

**Decision (settled — do not re-open):** tianguis maps its schema through the nkdl
**typed↔DOM bridge** (`parse` + node accessors + `decodeArg`/`decodeChild`), **not**
nkdl's typed `decode[T]` derive. Rationale: tianguis's wire format (scalars as named
child nodes, a node-name-keyed `requires` map, a `kind`-discriminated `provenance`
variant) is *idiomatic KDL* but nkdl's derive doesn't express it yet — and we will NOT
grow nkdl's derive for a single consumer with a stable, bespoke schema. The bridge is
the designed escape hatch for exactly this. (Grow derive only when ≥2 consumers prove a
shape.)

## Invariants (must hold — these are the safety net)
1. **`formatKdl` (encode) does not change.** It is pure model→string and has zero kdl
   dependency. The emitted `index.kdl` bytes stay identical.
2. **milpa is unaffected.** milpa (`tianguis_client.py`) parses `index.kdl` semantically
   by node name (`_scalar_child`, `node.args[0]`), tolerant of formatting. Since (1)
   holds, its consumption is unchanged. (Verify with a smoke test, don't assume.)
3. **Behavior preserved:** the existing tests are the spec. `test_kdl_roundtrip`
   (semantic `parseKdl(formatKdl(x)) == x`, not byte-exact) and `test_strict_schema`
   (`iecUnknownNode` on unknown nodes at each level) must stay green. Lenient `""`
   defaults on absent scalars preserved; `(url)` annotated + plain forms both accepted.
4. **No nkdl changes.** This is tianguis-only.

## Surface (grounded)
- **4 files import `kdl`:** `kdl_io.nim`, `vendor/denylist.nim`, `json_io.nim`,
  `vendor/upstream.nim`. (`cli.nim`/`addentry.nim`/tests get it transitively via
  `kdl_io`'s re-export — unaffected.)
- `json_io.nim` / `upstream.nim` import kdl **only** for `Result`/`ok`/`err` → import
  rename only (the new `nkdl` umbrella re-exports `spans` = `Result`/`ParseError`).
- **The real work is `kdl_io.nim`'s decode path** (`parseKdl`/`parsePackage`/
  `parseVersion`/`parseProvenance`/`parseRequires`, ~150 LOC) + `denylist.nim`'s ~10-LOC
  mini-walk. Encode is untouched (Invariant 1).

## The bridge pattern (the canonical "do it this way")
```nim
import nkdl

proc argStr(n: KdlNode, i = 0): string =
  if n.isNil: "" else: decodeArg[string](n, i).valueOr("")
proc childStr(n: KdlNode, name: string): string =   # scalar-child: `name "value"`
  n.child(name).argStr
func unknownNode(doc: KdlDoc, n: KdlNode): IdxError =
  let (line, col) = doc.lineMap.lineColOf(n.span.offset)   # line/col from the doc's map
  IdxError(code: iecUnknownNode, msg: "unexpected node '" & n.name & "'", line: line, col: col)

proc parseProvenance(doc: KdlDoc, n: KdlNode): Result[Provenance, IdxError] =
  for c in n.children:
    if c.name notin ProvenanceChildren: return err unknownNode(doc, c)
  case n.childStr("kind")
  of "git", "": ok Provenance(kind: pkGit, url: n.childStr("url"),
                              gitRef: n.childStr("ref"), commitSha: n.childStr("commit_sha"))
  of "oci":     ok Provenance(kind: pkOci, registry: n.childStr("registry"),
                              repository: n.childStr("repository"), digest: n.childStr("digest"))
  else:         err IdxError(code: iecBadType, msg: "unknown provenance kind")

proc parseVersion(doc: KdlDoc, n: KdlNode): Result[Version, IdxError] =
  var v = Version(version: n.argStr)
  for c in n.children:
    case c.name
    of "content_hash": v.contentHash = c.argStr
    of "attestation":  v.attestation = c.argStr
    of "signed_by":    v.signedBy    = c.argStr
    of "published_at": v.publishedAt = c.argStr
    of "requires":     (for r in c.children: v.requires[r.name] = r.argStr)
    of "provenance":   v.provenances.add(? parseProvenance(doc, c))
    else: return err unknownNode(doc, c)
  ok v
```
The old API removals this replaces: `doc.interner.lookup(node.name)` → `n.name`;
`node.entries[0].argValue.strVal` → `n.arg(0)`/`decodeArg`; `node.span.start.line` →
`doc.lineMap.lineColOf(n.span.offset)`; `KdlNode.children` field → `n.children`.

## Slices (existing tests are the gate)
The dep bump turns the existing suite RED (won't compile); each slice brings a chunk
back to green.

- **S1 — dep bump + import rename.** `milpa.kdl`: re-resolve `kdl ref=main` → nkdl
  `50a5c11`; `import kdl`→`import nkdl` in the 4 files + `export kdl,errors`→
  `export nkdl,errors` in kdl_io/json_io. Stub the decode procs to compile. Outcome:
  everything compiles, `json_io`/`upstream`/encode green, decode tests RED.
- **S2 — leaf parsers.** Rewrite `parseProvenance` + `parseRequires` to the bridge.
- **S3 — structural walk.** Rewrite `parseVersion` + `parsePackage` + `parseKdl` (strict
  membership + line/col). → `test_kdl_roundtrip` + `test_strict_schema` GREEN.
- **S4 — denylist.** Port `vendor/denylist.nim`'s mini-walk.
- **S5 — verify.** Full suite green; smoke-test `parseKdl` against the real 1.5 MB
  `index.kdl`; confirm `formatKdl` output is byte-identical (Invariant 1) and milpa
  reads it (Invariant 2).

## Right-sizing the flow (recommended)
This is a mechanical port with **no design forks** and the existing tests as the spec —
so it does **not** warrant the full architect-rounds + multi-round-review treadmill.
Recommended: **skip Stage 2 (architect)**, go straight to Stage 3 (`/tdd` grind over
S1–S5 with the existing suite as the safety net), then **one** light `/code-review` pass.
Effort: ~half a day.

## Non-goals
- No nkdl derive changes. No schema redesign (the schema is good idiomatic KDL).
- No `index.kdl` format change (Invariant 1).
- The `index.json` projection / `json_io` parsing logic is unchanged beyond the import rename.
