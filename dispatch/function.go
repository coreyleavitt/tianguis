package function

// Scaleway Functions Go runtime entry point. Scaleway compiles this
// package and generates its own main wrapper that calls Handle per
// request — so this package MUST NOT be `main` and MUST NOT define
// its own main().
//
// For local development, see cmd/server/main.go in this module, which
// imports this package and runs the same handler via http.ListenAndServe.

import (
	"context"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
)

// Handle is invoked per request by the Scaleway runtime.
func Handle(w http.ResponseWriter, r *http.Request) {
	scalewayHandler().ServeHTTP(w, r)
}

var (
	handlerOnce sync.Once
	handlerMu   http.Handler
)

func scalewayHandler() http.Handler {
	handlerOnce.Do(func() {
		verifier := NewMultiIssuerVerifier(context.Background(), issuerConfigs())
		handlerMu = NewRouter(verifier)
	})
	return handlerMu
}

// NewLocalHandler is exported so cmd/server/main.go can run the same
// handler locally via http.ListenAndServe. Construction is identical
// to Handle's lazy-init path.
func NewLocalHandler() http.Handler {
	return scalewayHandler()
}

// issuerConfigs reads the trusted OIDC issuer set from env. Format:
//
//	TIANGUIS_ISSUERS=github,gitlab
//
// Each name maps to a built-in config below. Adding a new provider
// means adding to issuerCatalog and (in #5) any per-provider repo-
// ownership-check logic.
func issuerConfigs() []IssuerConfig {
	names := os.Getenv("TIANGUIS_ISSUERS")
	if names == "" {
		// Sensible default: trust GitHub Actions + GitLab CI out of the box.
		names = "github,gitlab"
	}
	var out []IssuerConfig
	for _, n := range strings.Split(names, ",") {
		n = strings.TrimSpace(n)
		if cfg, ok := issuerCatalog[n]; ok {
			out = append(out, cfg)
		} else {
			log.Printf("warning: unknown issuer %q in TIANGUIS_ISSUERS, skipping", n)
		}
	}
	return out
}

// issuerCatalog is the curated list of supported OIDC providers.
// The aud "sigstore" is the standard audience used by cosign keyless;
// reusing it means authors don't have to mint a second token just for
// the dispatch call.
var issuerCatalog = map[string]IssuerConfig{
	"github": {
		Name:      "github",
		URL:       "https://token.actions.githubusercontent.com",
		JWKSURL:   "https://token.actions.githubusercontent.com/.well-known/jwks",
		Audiences: []string{"sigstore"},
	},
	"gitlab": {
		Name:      "gitlab",
		URL:       "https://gitlab.com",
		JWKSURL:   "https://gitlab.com/oauth/discovery/keys",
		Audiences: []string{"sigstore"},
	},
}
