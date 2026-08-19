# Contributing

`main` is protected. **Nothing lands on `main` except through a pull request**, and
**every pull request must update [CHANGELOG.md](CHANGELOG.md)**.

## The rules on `main`

Enforced by a GitHub repository ruleset (`main-protected`), not by convention:

| Rule | Effect |
| --- | --- |
| Pull request required | Direct `git push` to `main` is rejected |
| Required approvals: **0** | You may merge your own PR — the gates below still apply |
| Stale approvals dismissed | A new push invalidates prior approvals |
| Conversations must be resolved | No merging over open review threads |
| Required status check: **`changelog`** | The PR must update `CHANGELOG.md` |
| Strict status checks | The branch must be up to date with `main` before merging |
| No force-push, no deletion | `main`'s history is linear and permanent |
| Linear history | Squash or rebase merges only — no merge commits |

Repository admins can bypass the ruleset for emergencies. Bypasses are recorded in
the ruleset's audit trail — use them and then follow up with a real PR.

## The workflow

```bash
git switch -c short-topic-branch
# ...make the change, and add the CHANGELOG.md entry in the same commit...
git push -u origin HEAD
gh pr create --fill
```

The `changelog` check runs on every PR. It fails unless the PR's file list contains
`CHANGELOG.md`.

## Writing the changelog entry

Read the MAJOR / MINOR / PATCH rules at the top of `CHANGELOG.md`. The version tracks
the **installable configuration**, not the prose:

- **MAJOR** — a new architecture you cannot reach by editing `00-vars.sh`.
- **MINOR** — a new install variant, a new service in the stack, or a changed default
  (model, region, provider).
- **PATCH** — corrections, re-probed facts, doc fixes, script robustness.

Work that isn't ready to be released as a version goes under `## [Unreleased]`.

Facts in this repo carry dates. If you re-probe something, update the date; if you
add a claim about model availability or pricing, probe it first and date it.

## The escape hatch

For a change that genuinely documents nothing — CI plumbing, a typo, a broken link —
add the **`skip-changelog`** label to the PR and re-run the check. Reach for it rarely:
if a change alters what someone would install or run, it needs an entry.

## Releases

After a version entry merges, tag it and cut a GitHub release:

```bash
git switch main && git pull
git tag -a v0.14.2 -m "v0.14.2 — <headline>"
git push origin v0.14.2
gh release create v0.14.2 --title "v0.14.2 — <headline>" --notes-from-tag
```
