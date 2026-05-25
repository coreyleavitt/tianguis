package function

import (
	"context"
	"time"
)

// RekorAttester records a verified publish event as a cosign-signed
// attestation in Rekor, returning the entry UUID. The commit workflow
// later re-fetches the entry by UUID and verifies it independently
// before committing — so even a fully-compromised dispatch can't inject
// entries without leaving a publicly-verifiable trail.
//
// Production: sigstore-go-backed implementation that builds an in-toto
// statement, cosign-signs it via dispatch's own OIDC identity (Sigstore
// keyless), and uploads to Rekor.
//
// Tests: injected fake that captures the payload and returns a canned UUID.
type RekorAttester interface {
	Attest(ctx context.Context, payload AttestPayload) (string, error)
}

// AttestPayload is what dispatch attests about each verified publish.
// Anchors the attestation to a specific verified event: who requested
// what when, with which OCI artifact, signed by whom.
type AttestPayload struct {
	Name           string    `json:"name"`
	OciRef         string    `json:"oci_ref"`
	RepoURL        string    `json:"repo_url"`
	SignerIdentity string    `json:"signer_identity"`
	VerifiedAt     time.Time `json:"verified_at"`
}
