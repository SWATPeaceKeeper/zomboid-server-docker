# AI policy

This project is developed with AI assistance. This page says exactly what that
means, so you can judge the code on the same terms the maintainers do.

## How this project was built

Most of the code, the tests and the documentation in this repository were
written with an AI coding assistant, working from designs and reviews by a
human maintainer. Every change was read before it was committed, and nothing
reaches `main` that has not passed the checks below.

That is the honest description. It is not a disclaimer: the maintainer is
responsible for every line here, whoever or whatever typed it first.

## What actually verifies the code

Disclosure is cheap. These are the things that would catch a mistake regardless
of its author:

- **Unit tests** (`bats`) cover the shell libraries as behaviour — INI patching
  preserving comments and unrelated keys, mod-list validation, branch selection,
  backup rotation.
- **Two end-to-end tests** install a real Project Zomboid server, boot it, save
  over RCON, stop it and assert a clean exit with a written world. One drives
  the image, one drives the Compose stack.
- **The release pipeline pulls back the image it just pushed** and runs that
  same end-to-end test against it, so the artefact you download is the one
  proven to boot.
- **It all runs nightly**, so a Project Zomboid update that breaks the image
  shows up on the badge rather than in your deployment.
- **Every change is linted** by shellcheck, shfmt, hadolint, yamllint, `go vet`
  and zizmor, and every image is scanned by Trivy before it is published. The
  scanner is not allowed to fail softly: a broken scanner and a clean scan must
  not look the same.

If you want to know whether a claim in the README is true, the tests are the
place to check, not this page.

## What this means for you as a user

- **The licence is unchanged.** GPL-3.0-or-later, no warranty, exactly as
  written in [LICENSE](LICENSE). AI involvement adds no extra terms and removes
  none.
- **Attribution is real.** Where this project adapts someone else's work — the
  graceful-shutdown mechanism and the in-place INI patching come from
  [Danixu/project-zomboid-server-docker](https://github.com/Danixu/project-zomboid-server-docker),
  GPL-3.0 — it is named in the file header and in the README. That obligation
  does not weaken because an assistant helped write the surrounding code.
- **No game files are redistributed.** SteamCMD downloads Project Zomboid at
  runtime. Nothing from The Indie Stone or Valve is in these images.
- **You are running a game server, not a security product.** Read
  [SECURITY.md](SECURITY.md) for the threat model and what to report.

## Rules for AI-assisted contributions

AI-assisted pull requests are welcome. The rules are the same ones that make any
pull request reviewable:

1. **Say so.** One line in the pull request description: which assistant, and
   what it did. "Claude Code wrote the parser, I wrote the tests" is enough.
   Nobody is judged for it; an undisclosed one that turns out to be wrong costs
   the reviewer far more time than a disclosed one.
2. **You own the diff.** Submitting a change means you have read it, understood
   it, and can explain why each part is there. "The model wrote it" is not an
   answer to a review comment.
3. **Run the tests yourself before opening the PR.** At minimum
   `./tests/run-unit.sh` and `./tests/compose-network.sh`. Do not let CI find
   what a two-second local run would have.
4. **New behaviour needs a test that fails without it.** Break the code, confirm
   the test goes red, then fix it. A test written alongside generated code is
   worth nothing until you have seen it fail.
5. **Do not paste code you cannot license.** If an assistant reproduces a
   recognisable chunk of someone else's project, it needs the same attribution
   and licence compatibility as if you had copied it by hand. GPL-3.0-or-later
   is the bar here.
6. **Keep the comments honest.** This codebase uses comments to record why a
   decision was made, usually because something failed once. A generated comment
   that restates the code adds noise; a generated comment that invents a
   rationale that never happened is worse.
7. **Scope it.** One logical change per pull request. A model that helpfully
   reformatted forty unrelated files makes the actual change unreviewable —
   split it or revert the noise.

## What is not done here

- **No AI-generated security claims.** Nothing on this repository asserts that
  the images are secure, hardened or audited because a model said so. Security
  statements are backed by a scanner run, a configuration you can read, or they
  are not made.
- **No generated changelog or release notes.** [CHANGELOG.md](CHANGELOG.md)
  records what changed, written by whoever made the change.
- **No AI-generated issue or pull request replies posted as if they were
  human.** If an assistant drafted a reply, it is the maintainer's reply and the
  maintainer stands behind it.
- **No automated merging of AI-authored changes.** Dependency updates from
  Renovate are ordinary automation with a pinned minimum release age; they are
  not covered by this section, and they are not merged without the CI suite
  passing.
- **Nothing in this repository is training data for anything.** The project does
  not collect, forward or process any data from the people who run it.

## Questions

Open an issue. If you think this policy is wrong, or that a specific change in
here shows a problem with how it was written, say so — that is a useful bug
report, not an insult.
