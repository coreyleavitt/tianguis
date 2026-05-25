## Tianguis-level error catalog.
##
## Stable IDX-* codes for any consumer (CI scripts, alternate
## implementations) to depend on. Mirrors milpa's MAN-* catalog
## discipline ([[error_catalog_discipline]]) at a smaller scale —
## the full bijection-tested registry can wait until tianguis grows
## more error surfaces.

type
  IndexErrorCode* = enum
    iecKdlParse        = "IDX-KDL-PARSE"
      ## KDL syntax error reported by the kdl library.
    iecJsonParse       = "IDX-JSON-PARSE"
      ## JSON syntax error reported by stdlib std/json.
    iecUnknownNode     = "IDX-NODE-UNKNOWN"
      ## A KDL node (top-level or child) or JSON key is not in the
      ## index schema's allowed set for its context.
    iecUnknownProperty = "IDX-PROP-UNKNOWN"
      ## A KDL property (key=value entry) is not in the allowed set.
    iecMissingField    = "IDX-FIELD-MISSING"
      ## A required field is absent.
    iecBadType         = "IDX-TYPE-MISMATCH"
      ## A field's value is the wrong type (e.g., int where string expected).

  IdxError* = object
    code*:    IndexErrorCode
    message*: string
    line*:    int    ## 1-based source line; 0 if location unknown
    col*:     int    ## 1-based source column; 0 if location unknown

proc initIndexError*(
    code: IndexErrorCode, message: string, line = 0, col = 0): IdxError =
  IdxError(code: code, message: message, line: line, col: col)
