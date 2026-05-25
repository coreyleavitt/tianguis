## Typed data model for the tianguis package index.
##
## KDL (`index.kdl`) and JSON (`index.json`) are projections of this model;
## the model is the canonical artifact, both serializations are derivable.

type
  Package* = object
    ## Placeholder for now — versions/namespace/upstream land in upcoming
    ## tracer cycles. Kept as an empty-equivalent record so `Index` with
    ## `packages: @[]` round-trips cleanly today and the field can grow
    ## without API churn.
    name*: string

  Index* = object
    ## Top-level index document.
    schemaVersion*: int
    packages*: seq[Package]
