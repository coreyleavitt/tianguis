## Typed data model for the tianguis package index.
##
## KDL (`index.kdl`) and JSON (`index.json`) are projections of this model;
## the model is the canonical artifact, both serializations are derivable.

type
  Version* = object
    version*:     string         ## semver-shaped version identifier
    contentHash*: string         ## multihash: "sha256:<hex>"
    attestation*: string         ## "milpa-vendored" | "author-signed"
    signedBy*:    string         ## URI identifying the signer
    publishedAt*: string         ## ISO 8601 UTC timestamp

  Package* = object
    name*:      string
    namespace*: string           ## OCI/GH namespace owning this name
    upstream*:  string           ## Upstream source URL (for human reference + link)
    versions*:  seq[Version]

  Index* = object
    ## Top-level index document.
    schemaVersion*: int
    packages*:      seq[Package]
