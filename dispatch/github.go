package function

import "context"

// GitHubAPI represents the (very narrow) GitHub surface dispatch uses:
// trigger a workflow_dispatch event on the tianguis repo, authenticated
// via the dispatch-bot GH App's installation token.
//
// Production: ghAppClient that generates a JWT signed with the App's
// private key, exchanges for an installation token (~1hr), POSTs to
// /repos/{owner}/{repo}/actions/workflows/{workflow_file}/dispatches.
//
// Tests: fake that captures the call for assertion.
type GitHubAPI interface {
	DispatchWorkflow(ctx context.Context, owner, repo, workflowFile string, inputs map[string]string) error

	// EnableWorkflow re-enables a workflow via
	// PUT /repos/{owner}/{repo}/actions/workflows/{workflow_file}/enable.
	// GitHub auto-disables schedule-triggered workflows after 60 days of
	// repository inactivity (and bot/GITHUB_TOKEN commits don't reset that
	// clock). This is the recovery primitive for the keepalive heartbeat:
	// an external Scaleway cron — independent of GitHub's inactivity clock —
	// calls it so a disabled cron gets revived, not merely prevented from
	// disabling. Idempotent: enabling an already-enabled workflow is a no-op.
	EnableWorkflow(ctx context.Context, owner, repo, workflowFile string) error
}
