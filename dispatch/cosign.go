package function

import "context"

// CosignVerifier verifies that an OCI artifact has a cosign signature
// attributable to a recognized OIDC identity.
//
// Production: sigstore-go-backed implementation that fetches the artifact's
// signature from Rekor, verifies the signature against Sigstore's trust
// root, and extracts the signer's certificate identity.
//
// Tests: injected fake that returns a canned identity (or error).
type CosignVerifier interface {
	Verify(ctx context.Context, ociRef string) (*CosignVerification, error)
}

// CosignVerification is the verified-truth from a cosign signature check.
// SignerIdentity is the OIDC identity bound to the cosign certificate
// (e.g. "https://github.com/coreyleavitt/sample" for a GH-Actions-signed
// artifact). Anti-impersonation check (cycle 5) compares this to the
// dispatch's verified OIDC identity.
type CosignVerification struct {
	SignerIdentity string
}
