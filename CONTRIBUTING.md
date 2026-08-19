# Contributing

`main` is protected. **Nothing lands on `main` except through a pull request**, every
pull request **claims a new version in [CHANGELOG.md](CHANGELOG.md)**, and every version
is **published as a [GitHub release](https://github.com/Emerging-Tech-Visma/hermes-agent/releases)
automatically** when the PR merges — with that changelog entry as its notes.

## The rules on `main`

Enforced by a GitHub repository ruleset (`main-protected`), not by convention:

| Rule | Effect |
| --- | --- |
| Pull request required | Direct `git push` to `main` is rejected |
| Required approvals: **0** | You may merge your own PR — the gates below still apply |
| Stale approvals dismissed | A new push invalidates prior approvals |
| Conversations must be resolved | No merging over open review threads |
| Required status check: **`changelog`** | The PR must update `CHANGELOG.md`, bump the version, and keep the badges in step |
| Strict status checks | The branch must be up to date with `main` before merging |
| No force-push, no deletion | `main`'s history is linear and permanent |
| Linear history | Squash or rebase merges only — no merge commits |

**Admins cannot push to `main` either.** The admin bypass is scoped to pull requests
(`bypass_mode: pull_request`), so the emergency escape hatch is "merge a PR that fails a
required check", not "push straight to `main`". Bypasses are recorded in the ruleset's
audit trail.

Because status checks are *strict*, a PR must be up to date with `main` before it can
merge. With concurrent agent sessions in this repo, expect the occasional **Update
branch** click when someone else's PR lands first — it re-runs the `changelog` check,
which takes about ten seconds.

## The workflow

```bash
git switch -c short-topic-branch
# ...make the change, add the CHANGELOG.md entry for the NEW version, and bump the
#    version badge in README.md and the "Currently" line in CLAUDE.md...
python3 .github/scripts/changelog.py top     # what this PR will release
git push -u origin HEAD
gh pr create --fill
```

The `changelog` check runs on every PR and fails unless all three hold:

1. the PR touches `CHANGELOG.md`;
2. its top entry names a version **strictly above** the one on `main`, not already tagged;
3. `README.md`'s badge and `CLAUDE.md`'s "Currently" line both say that version.

If another PR lands your version number while yours is open, the check says which version
`main` reached — renumber your entry to the next one above it.

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

## Releases — automatic, do not tag by hand

When your PR merges, `.github/workflows/release.yml` reads the top entry of
`CHANGELOG.md`, tags the merge commit `vX.Y.Z`, and publishes a release whose notes are
that entry. The release title is the merge commit's subject, so name the PR
`vX.Y.Z — what changed`.

Consequences worth knowing:

- **The changelog entry *is* the release note.** Write it for someone reading the
  Releases page, not for a diff.
- **Fixing an entry fixes the release.** Re-running the workflow (or landing a correction
  while that version is still the top entry) refreshes the published notes.
- **A `skip-changelog` PR ships no release** — no version, no tag, nothing on the
  Releases page.

Preview exactly what will be published:

```bash
python3 .github/scripts/changelog.py notes "$(python3 .github/scripts/changelog.py top)"
```

Re-publish by hand only if Actions is down:

```bash
gh workflow run release.yml --ref main
```
