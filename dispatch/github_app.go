package function

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// ghAppClient implements GitHubAPI using the dispatch-bot GH App.
//
// Per request: signs a JWT with the App's RSA private key (~10min validity),
// exchanges it for an installation token (~1hr validity) for our target
// installation, then makes the actual API call with the installation token.
// The JWT signing key never leaves our process; tokens that traverse the
// wire are always short-lived. See dispatch_security_architecture memory.
//
// Installation ID is discovered on first call and cached for the process
// lifetime — a warm Scaleway function reuses it across invocations.
type ghAppClient struct {
	appID        string
	privateKey   *rsa.PrivateKey
	httpClient   *http.Client

	installCache sync.Map // owner → int64 installation ID
}

func NewGitHubAppClient(appID string, privateKey *rsa.PrivateKey) GitHubAPI {
	return &ghAppClient{
		appID:      appID,
		privateKey: privateKey,
		httpClient: &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *ghAppClient) DispatchWorkflow(ctx context.Context, owner, repo, workflowFile string, inputs map[string]string) error {
	installID, err := c.installationIDFor(ctx, owner)
	if err != nil {
		return fmt.Errorf("locate installation for %s: %w", owner, err)
	}
	token, err := c.installationToken(ctx, installID)
	if err != nil {
		return fmt.Errorf("exchange JWT for installation token: %w", err)
	}

	url := fmt.Sprintf(
		"https://api.github.com/repos/%s/%s/actions/workflows/%s/dispatches",
		owner, repo, workflowFile,
	)
	body, _ := json.Marshal(map[string]any{
		"ref":    "main",
		"inputs": inputs,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNoContent {
		return nil // GH returns 204 on successful workflow_dispatch
	}
	respBody, _ := io.ReadAll(resp.Body)
	return fmt.Errorf("workflow_dispatch returned %d: %s", resp.StatusCode, string(respBody))
}

func (c *ghAppClient) EnableWorkflow(ctx context.Context, owner, repo, workflowFile string) error {
	installID, err := c.installationIDFor(ctx, owner)
	if err != nil {
		return fmt.Errorf("locate installation for %s: %w", owner, err)
	}
	token, err := c.installationToken(ctx, installID)
	if err != nil {
		return fmt.Errorf("exchange JWT for installation token: %w", err)
	}

	// Same `actions: write` scope the dispatch path already uses, so no new
	// App permission is required.
	url := fmt.Sprintf(
		"https://api.github.com/repos/%s/%s/actions/workflows/%s/enable",
		owner, repo, workflowFile,
	)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNoContent {
		return nil // GH returns 204 on successful enable (and on already-enabled)
	}
	respBody, _ := io.ReadAll(resp.Body)
	return fmt.Errorf("enable workflow returned %d: %s", resp.StatusCode, string(respBody))
}

// signJWT mints a fresh App JWT (~10 min validity per GitHub's recommendation).
// Either appID or Client ID works as the iss claim; we use whatever
// was passed at construction.
func (c *ghAppClient) signJWT() (string, error) {
	now := time.Now()
	claims := jwt.MapClaims{
		"iat": now.Add(-30 * time.Second).Unix(), // small clock-skew tolerance
		"exp": now.Add(10 * time.Minute).Unix(),
		"iss": c.appID,
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	return tok.SignedString(c.privateKey)
}

// installationIDFor finds the installation ID for `owner` by listing
// the App's installations. Cached after first lookup.
func (c *ghAppClient) installationIDFor(ctx context.Context, owner string) (int64, error) {
	if v, ok := c.installCache.Load(owner); ok {
		return v.(int64), nil
	}
	jwt, err := c.signJWT()
	if err != nil {
		return 0, err
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://api.github.com/app/installations", nil)
	req.Header.Set("Authorization", "Bearer "+jwt)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return 0, fmt.Errorf("list installations returned %d: %s", resp.StatusCode, string(body))
	}
	var installs []struct {
		ID      int64 `json:"id"`
		Account struct {
			Login string `json:"login"`
		} `json:"account"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&installs); err != nil {
		return 0, err
	}
	for _, i := range installs {
		if i.Account.Login == owner {
			c.installCache.Store(owner, i.ID)
			return i.ID, nil
		}
	}
	return 0, errors.New("no installation found for owner: " + owner)
}

// installationToken exchanges the App JWT for an installation access token
// scoped to a specific installation. Tokens expire after ~1 hour.
func (c *ghAppClient) installationToken(ctx context.Context, installID int64) (string, error) {
	jwt, err := c.signJWT()
	if err != nil {
		return "", err
	}
	url := fmt.Sprintf("https://api.github.com/app/installations/%d/access_tokens", installID)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	req.Header.Set("Authorization", "Bearer "+jwt)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("installation token returned %d: %s", resp.StatusCode, string(body))
	}
	var r struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return "", err
	}
	return r.Token, nil
}
