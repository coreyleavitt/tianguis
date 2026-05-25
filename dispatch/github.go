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
}
