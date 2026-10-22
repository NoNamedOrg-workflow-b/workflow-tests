# workflow-tests

Central rebase check for pull requests. Run `tests/runTests.sh` to test the check locally.

## Pinning the required workflow

A ruleset that requires `.github/workflows/enforceRebase.yml` must not follow `main`: the commit that runs would move
with every merge here. Pin it to a **lightweight** tag (`git tag v1-light <commit>`, never `-a`) or to a commit sha.
An annotated tag is accepted by the ruleset API but the workflow then never runs and the pull requests get no check.
