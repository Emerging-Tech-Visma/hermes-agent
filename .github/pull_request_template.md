## What changed

<!-- One or two sentences. What does this change about the installable configuration? -->

## Changelog and version

<!-- Required. Every PR claims a new version, and that entry becomes the notes of the
     release published on merge. Write it for the Releases page. Title this PR
     'vX.Y.Z — what changed'. Nothing to document? Add the `skip-changelog` label
     instead — then no version and no release. -->

- [ ] New `## [x.y.z] — YYYY-MM-DD` entry at the top of `CHANGELOG.md`, above `main`'s version
- [ ] Version badge in `README.md` and the "Currently" line in `CLAUDE.md` bumped to match
- [ ] MAJOR/MINOR/PATCH picked per the rules at the top of `CHANGELOG.md`
- [ ] `AGENTS.md` / `README.md` / the install package kept in sync

## Verification

<!-- Facts carry dates in this repo. What did you actually probe, and when?
     "Verify, don't trust the docs in here." -->

- [ ] Claims re-probed against live GCP/Vertex, with dates updated
- [ ] No secrets committed (`__PLACEHOLDER__` tokens only)
