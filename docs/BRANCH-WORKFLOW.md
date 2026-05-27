# Branch workflow and the autonomous PR loop

This doc explains how PRs are produced and reviewed in k8s-pilot,
including the AI-driven autonomous loop the harness was built with.
The contract is intentionally lightweight — the same loop is run by
human contributors and AI agents alike.

## Branch model

- `main` is the single long-lived branch. All changes land there via
  squash merge from a feature branch.
- Feature branches use the pattern `pr/NN-short-slug` for the
  numbered PRs in the README roadmap (e.g. `pr/12-pre-commit`), or
  `feat/<slug>` / `fix/<slug>` for ad-hoc work.
- No `develop`, no `release/*`, no GitFlow. Trunk-based.

## PR lifecycle

1. **Branch from `main`** (`git checkout main && git pull && git
   checkout -b pr/NN-short-slug` for a roadmap PR, or
   `feat/<slug>` for ad-hoc work).
2. **Make the change** following the relevant agent persona and the
   skill (`skills/kubernetes/SKILL.md`). Run validators locally via
   `scripts/Validate-Manifests.ps1` on rendered manifests. Once
   `scripts/Pre-Commit.ps1` orchestrates the minimum set automatically
   as a pre-push gate (auto-renders kustomize directories under
   `examples/` then runs `Validate-Manifests.ps1` + the MCP secret
   scanner).
3. **Commit** using Conventional Commits with one of the scopes from
   [CONTRIBUTING.md](../CONTRIBUTING.md).
4. **Push** the branch and **open a PR** via `gh pr create --fill`
   (or the GitHub UI).
5. **Request Copilot review** as the first reviewer (see below).
6. **Iterate**: address Copilot's comments by pushing fixup commits.
   Reply on the PR with what you changed.
7. **Resolve the threads** you addressed via the GraphQL
   `resolveReviewThread` mutation. Do not leave addressed threads
   open at merge time.
8. **Squash-merge** once Copilot's latest pass is clean and any
   human reviewer has approved.
9. **Delete the branch** on merge.

## Requesting Copilot review

The Copilot bot is invited as a reviewer via the REST
`/requested_reviewers` endpoint, not via `gh pr edit --add-reviewer`
(which uses the GraphQL `requestReviewsByLogin` that rejects bots):

```bash
gh api repos/<OWNER>/<REPO>/pulls/<PR>/requested_reviewers \
  --method POST \
  -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

The display name is `Copilot`; the actual login is the bracketed bot
name. Confirm success by reading the response's `requested_reviewers`
array.

Copilot typically returns a review within 60–180 seconds. The wrapper
loop polls every ~4 minutes.

## Resolving review threads

Each Copilot inline comment lives in a "review thread". After you push
a fix, **resolve** the addressed threads via the GraphQL
`resolveReviewThread` mutation so the PR doesn't accumulate stale open
discussions:

```bash
# 1. List unresolved threads
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:50){
          nodes{ id isResolved path comments(first:1){ nodes{ body } } }
        }
      }
    }
  }' -F owner=OWNER -F repo=REPO -F pr=PR

# 2. For each addressed thread:
gh api graphql -f query='
  mutation($id:ID!){
    resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } }
  }' -f id=<thread-node-id>
```

If a thread is NOT addressed (deferred, declined, debated), leave it
open and reply explaining why.

## The autonomous PR loop

The harness was built via an autonomous loop across the README
roadmap PRs:

1. The agent creates a branch, makes a focused change, commits, pushes,
   opens a PR with `gh pr create`, and requests Copilot review.
2. The agent waits for Copilot's review (poll the PR's `reviews`
   collection via `gh pr view --json reviews`).
3. The agent reads each inline comment, classifies it
   (valid / declined / debated), applies the corresponding fix, pushes,
   replies on the PR, resolves the addressed threads, and re-requests
   review.
4. The loop continues until Copilot's review body says
   "generated no new comments" and there are no outstanding
   unresolved threads.
5. The agent then squash-merges the PR, deletes the branch, and moves
   to the next item in the roadmap.

This is documented at
<https://www.linkedin.com/pulse/autonomous-pr-loop-claude-github-cli-copilot-review-codex-johnson-ou9rc/>.

## Hard rules that constrain the loop

- **No GitHub Actions** in this repo. The owner is conserving Actions
  minutes; validation is local-only via `scripts/Validate-Manifests.ps1`
  (orchestrated by `scripts/Pre-Commit.ps1`).
- **No `--no-verify` on commits**, no `--force` on pushes to `main`,
  no skipping hooks. If a hook fails, fix the underlying issue.
- **Squash-merge only**. The PR title becomes the squash commit
  subject; the PR body becomes the commit body.
- **Branch protections**: not enforced server-side in this repo
  (private + small team), but the loop honors them as if they were:
  Copilot must review, threads must resolve, the merge must squash.

## When to break out of the loop

- If a Copilot comment is wrong (stale quote, misreads the code,
  insists on a worse pattern), reply with the rationale, mark the
  thread resolved if appropriate, and proceed. Don't relitigate.
- If a review keeps surfacing the same class of issue across many
  rounds, step back: maybe a structural change up-front would
  collapse all of them. Push that one bigger fix instead of N small
  ones.
- If a PR has hit double-digit review cycles with diminishing
  returns, consider merging with a follow-up TODO rather than
  trying to converge in one PR. The history will show the trajectory.

## What the loop is NOT

- It is not a substitute for human judgment on architectural choices.
- It is not a way to skip the diff-before-mutate discipline of the
  per-tool wrappers (which target a cluster, not a repo).
- It is not bound to Copilot specifically: any code-reviewing bot that
  emits inline comments at PR review URLs is a drop-in replacement.
