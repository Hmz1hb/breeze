#!/bin/zsh
# Run once, right after making the repo public: these two features need a public repo (or GitHub Pro).
set -euo pipefail
repo=${1:-Hmz1hb/breeze}

[[ $(gh repo view "$repo" --json visibility --jq .visibility) == PUBLIC ]] || { print -u2 "$repo is still private. Make it public first (Settings → General → Danger Zone)."; exit 1; }

gh api -X PUT "repos/$repo/private-vulnerability-reporting"

# main: no deletion, no force push, PRs with 1 code-owner approval, CI must pass, squash only.
# Admins (you) may merge your own PRs without approval but still can't push to main directly.
gh api -X POST "repos/$repo/rulesets" --input - <<'JSON'
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" } ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"] } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "Build and test" } ] } }
  ]
}
JSON
echo "Done: private vulnerability reporting on, main protected."
