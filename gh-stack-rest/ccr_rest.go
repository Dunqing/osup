// REST replacements for gh-stack's GraphQL calls, for Claude Code cloud sessions,
// whose GitHub proxy refuses GraphQL. Ready-for-review and auto-merge use the
// proxy's /ccr/ routes. Copied in by build.sh in Dunqing/osup
// gh-stack-rest; apply.py points each GraphQL method here.
// REST exposes no merge-queue entry, so IsQueued is always false.
package github

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"

	"github.com/cli/go-gh/v2/pkg/api"
)

type restPR struct {
	NodeID         string           `json:"node_id"`
	Number         int              `json:"number"`
	State          string           `json:"state"`
	HTMLURL        string           `json:"html_url"`
	Title          string           `json:"title"`
	Body           *string          `json:"body"`
	Draft          bool             `json:"draft"`
	MergedAt       *string          `json:"merged_at"`
	MergeCommitSHA string           `json:"merge_commit_sha"`
	AutoMerge      *json.RawMessage `json:"auto_merge"`
	Head           struct {
		Ref string `json:"ref"`
		SHA string `json:"sha"`
	} `json:"head"`
	Base struct {
		Ref string `json:"ref"`
	} `json:"base"`
}

func (p *restPR) merged() bool { return p.MergedAt != nil && *p.MergedAt != "" }

// GraphQL-style PullRequestState: OPEN, CLOSED or MERGED.
func (p *restPR) state() string {
	if p.merged() {
		return "MERGED"
	}
	return strings.ToUpper(p.State)
}

// prNumbers maps PR node IDs to numbers: ready-for-review and auto-merge take an
// ID, the REST routes take a number, and every PR the caller holds came from here.
var prNumbers sync.Map

func (c *Client) restPullRequest(p *restPR) *PullRequest {
	prNumbers.Store(p.NodeID, p.Number)
	pr := &PullRequest{ID: p.NodeID, Number: p.Number, State: p.state(), URL: p.HTMLURL, Title: p.Title,
		HeadRefName: p.Head.Ref, HeadRefOID: p.Head.SHA, BaseRefName: p.Base.Ref, IsDraft: p.Draft, Merged: p.merged()}
	if p.Body != nil {
		pr.Body = *p.Body
	}
	if p.AutoMerge != nil && string(*p.AutoMerge) != "null" {
		pr.AutoMergeRequest = &AutoMergeRequest{}
	}
	return pr
}

func isNotFound(err error) bool {
	var h *api.HTTPError
	return errors.As(err, &h) && h.StatusCode == http.StatusNotFound
}

func (c *Client) restPRsForHead(branch, state string) ([]restPR, error) {
	path := fmt.Sprintf("repos/%s/%s/pulls?head=%s&state=%s&sort=created&direction=desc&per_page=1",
		c.owner, c.repo, url.QueryEscape(c.owner+":"+branch), state)
	var prs []restPR
	err := c.rest.Get(path, &prs)
	return prs, err
}

func (c *Client) restFindPRForBranch(branch string) (*PullRequest, error) {
	prs, err := c.restPRsForHead(branch, "open")
	if err != nil {
		return nil, fmt.Errorf("querying PRs: %w", err)
	}
	if len(prs) == 0 {
		return nil, nil
	}
	return c.restPullRequest(&prs[0]), nil
}

func (c *Client) restFindPRDetailsForBranch(branch string) (*PRDetails, error) {
	prs, err := c.restPRsForHead(branch, "all")
	if err != nil {
		return nil, fmt.Errorf("querying PR details: %w", err)
	}
	if len(prs) == 0 {
		return nil, nil
	}
	p := &prs[0]
	d := &PRDetails{Number: p.Number, State: p.state(), URL: p.HTMLURL, IsDraft: p.Draft, Merged: p.merged(), HeadRefOID: p.Head.SHA}
	if p.merged() {
		d.MergeCommitOID = p.MergeCommitSHA
	}
	return d, nil
}

func (c *Client) restFindPRByNumber(number int) (*PullRequest, error) {
	var p restPR
	if err := c.rest.Get(fmt.Sprintf("repos/%s/%s/pulls/%d", c.owner, c.repo, number), &p); err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("querying PR #%d: %w", number, err)
	}
	return c.restPullRequest(&p), nil
}

func (c *Client) restCreatePR(base, head, title, body string, draft bool) (*PullRequest, error) {
	req, err := json.Marshal(map[string]interface{}{"base": base, "head": head, "title": title, "body": body, "draft": draft})
	if err != nil {
		return nil, fmt.Errorf("marshaling request: %w", err)
	}
	var p restPR
	if err := c.rest.Post(fmt.Sprintf("repos/%s/%s/pulls", c.owner, c.repo), bytes.NewReader(req), &p); err != nil {
		return nil, fmt.Errorf("creating PR: %w", err)
	}
	return c.restPullRequest(&p), nil
}

func (c *Client) restPRRoute(method, prID, route, what string) error {
	n, ok := prNumbers.Load(prID)
	if !ok {
		return fmt.Errorf("%s: unknown pull request ID %s", what, prID)
	}
	resp, err := c.rest.Request(method, fmt.Sprintf("repos/%s/%s/pulls/%d/ccr/%s", c.owner, c.repo, n, route), nil)
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	return resp.Body.Close()
}

func (c *Client) restMarkPRReadyForReview(prID string) error {
	return c.restPRRoute(http.MethodPost, prID, "ready_for_review", "marking PR ready for review")
}

func (c *Client) restDisableAutoMerge(prID string) error {
	return c.restPRRoute(http.MethodDelete, prID, "auto_merge", "disabling auto-merge")
}

func (c *Client) restRepositoryID() (string, error) {
	var r struct {
		NodeID string `json:"node_id"`
	}
	if err := c.rest.Get(fmt.Sprintf("repos/%s/%s", c.owner, c.repo), &r); err != nil {
		return "", fmt.Errorf("fetching repository ID: %w", err)
	}
	return r.NodeID, nil
}

// REST has no viewer's last-used merge method: prefer squash, then merge, then rebase.
func (c *Client) restRepoMergeConfig() (*RepoMergeConfig, error) {
	var r struct {
		Merge  bool `json:"allow_merge_commit"`
		Squash bool `json:"allow_squash_merge"`
		Rebase bool `json:"allow_rebase_merge"`
	}
	if err := c.rest.Get(fmt.Sprintf("repos/%s/%s", c.owner, c.repo), &r); err != nil {
		return nil, fmt.Errorf("querying repository merge config: %w", err)
	}
	cfg := &RepoMergeConfig{MergeAllowed: r.Merge, SquashAllowed: r.Squash, RebaseAllowed: r.Rebase, DefaultMethod: MergeMethodMerge}
	if r.Squash {
		cfg.DefaultMethod = MergeMethodSquash
	} else if !r.Merge && r.Rebase {
		cfg.DefaultMethod = MergeMethodRebase
	}
	return cfg, nil
}

// Rulesets only: a merge queue set by classic branch protection isn't visible here.
func (c *Client) restBaseBranchUsesMergeQueue(baseRef string) (bool, error) {
	var rules []struct {
		Type string `json:"type"`
	}
	if err := c.rest.Get(fmt.Sprintf("repos/%s/%s/rules/branches/%s", c.owner, c.repo, url.PathEscape(baseRef)), &rules); err != nil {
		return false, fmt.Errorf("querying base branch merge queue: %w", err)
	}
	for _, r := range rules {
		if r.Type == "merge_queue" {
			return true, nil
		}
	}
	return false, nil
}

func (c *Client) restPRTitles(numbers []int) (map[int]string, error) {
	titles := make(map[int]string, len(numbers))
	for _, n := range numbers {
		pr, err := c.restFindPRByNumber(n)
		if err != nil {
			return titles, fmt.Errorf("querying pull request titles: %w", err)
		}
		if pr != nil {
			titles[n] = pr.Title
		}
	}
	return titles, nil
}
