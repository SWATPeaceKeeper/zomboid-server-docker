<!--
Thanks for the change. Describe what the code does now - not the approaches you
discarded on the way. Plain language: a bug fix is a bug fix.
-->

## What this changes

<!-- One or two sentences. Link the issue if there is one: Closes #123 -->

## Why

<!--
What was wrong, or what could not be done before. If it fixes a failure you hit
in a real deployment, say what the symptom looked like - that is what someone
searching the issue tracker in six months will match on.
-->

## How it was tested

<!-- Delete what does not apply. -->

- [ ] `./tests/run-unit.sh`
- [ ] `./tests/compose-network.sh`
- [ ] `./tests/stack-smoke.sh` or `./tests/smoke.sh`
- [ ] `prek run`
- [ ] Ran it against a real server

## Checklist

- [ ] Documentation updated in this same PR (README, `docs/`, `CHANGELOG.md`)
- [ ] New behaviour has a test that fails without the change
- [ ] Linter versions in `.pre-commit-config.yaml` and
      `.github/workflows/lint.yml` still match, if either was touched —
      `./tests/check-lint-versions.sh` says so, and CI runs it
- [ ] No credentials, `.env` files or real passwords in the diff

## AI assistance

<!--
Per AI-POLICY.md: one line on which assistant helped and with what. "None" is a
perfectly good answer. Nobody is judged for using one - an undisclosed one that
turns out to be wrong just costs the reviewer more time.
-->
