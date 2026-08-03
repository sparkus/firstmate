# Harness skill discovery verification

Audience: maintainer verification.

This record supports the shared project-skill layout: `.agents/skills/` is the single canonical tree, and harness-native paths are symlinks to it (`.claude/skills`, `.codex/skills`, `.grok/skills`).
It records what each harness actually resolved on the versions below.
Task chronology stays in private reports or PR evidence.

Verified 2026-08-03 in a linked git worktree of firstmate at
`/Users/agwerschky/.treehouse/firstmate-87f082/1/firstmate`
(`git rev-parse --show-toplevel` equals that path; `git-common-dir` points at the primary repo `.git`).

## Versions

| Harness | Binary | Version |
| --- | --- | --- |
| claude | `/Users/agwerschky/.local/bin/claude` | 2.1.220 (Claude Code) |
| codex | `/Users/agwerschky/.local/bin/codex` | codex-cli 0.146.0-alpha.9.2 |
| grok | `/Users/agwerschky/.local/bin/grok` | grok 0.2.118 (1e1687c1cf6a) [stable] |

## Repo layout under test

- Canonical tree: real directory `.agents/skills/<name>/SKILL.md` (no copy of skill bodies).
- Claude: existing tracked symlink `.claude/skills -> ../.agents/skills`.
- Codex and Grok: tracked symlinks `.codex/skills -> ../.agents/skills` and `.grok/skills -> ../.agents/skills` (added on this branch; same relative target as Claude).

## What each harness resolved

### Grok

Commands:

```sh
grok inspect --json
# plus disposable probe repos under /tmp with distinct skills in
# .agents/skills, .grok/skills, .claude/skills, and .codex/skills
```

Findings:

- Project discovery works.
- Documented and observed project roots include `.grok/skills/`, `.agents/skills/`, and `.claude/skills/` (Claude compat).
- Grok does **not** treat project `.codex/skills/` as a skill root (probe skill there never appeared).
- With only the canonical `.agents/skills` tree present (before harness symlinks), every firstmate internal skill resolved as `source.type=project` with path under `.../firstmate/.agents/skills/<name>/SKILL.md`.
- After adding `.grok/skills -> ../.agents/skills`, the same skills resolve once (name-deduped) with path under `.../firstmate/.grok/skills/<name>/SKILL.md`.
- User-level skills still come from `~/.grok/skills/` (and optional Claude user compat paths).

### Codex

Commands:

```sh
codex debug prompt-input "x"
# parse the model-visible ## Skills / ### Skill roots section
```

Findings:

- Project discovery works for **both** `$REPO/.agents/skills` and `$REPO/.codex/skills` when they are distinct real directories (both appeared as separate skill roots; probe skills under each loaded).
- Official Codex docs also document walking `.agents/skills` from CWD up to the repo root (and user/admin/system locations).
- With only the real `.agents/skills` tree, every firstmate internal skill (all 18 pre-change names, then 19 including `ticket-queue-discipline`) appeared under skill root `.../firstmate/.agents/skills`.
- When `.codex/skills` is a symlink to `.agents/skills`, Codex lists a single project root at the resolved `.agents/skills` path and does **not** double-list the same skill.
- User-level skills come from `~/.codex/skills` (and related plugin/system roots).

### Claude

Commands:

```sh
readlink .claude/skills   # ../.agents/skills
test -f .claude/skills/afk/SKILL.md
git ls-files -s .claude/skills   # mode 120000 (symlink)
```

Findings:

- The supervising Claude session at `/Users/agwerschky/git/firstmate` loaded five project skills from the repository path during this task session: `ask-user-authority`, `secondmate-provisioning`, `stuck-crewmate-recovery`, `bootstrap-diagnostics`, and `harness-adapters`.
- Each invocation returned the skill body.
- Each skill resolves through `.claude/skills -> ../.agents/skills` to `.agents/skills/<name>/SKILL.md`, as confirmed by `readlink -f`.
- This is a live load observation, not an inference from the symlink alone.
- `ticket-queue-discipline` itself has not been loaded by a Claude session because it exists only on the feature branch and is not yet in the main home.
- Claude project-skill resolution is observed for existing internal skills through the same symlink the new skill uses, and `ticket-queue-discipline` inherits that path.
- A post-merge Claude load of `ticket-queue-discipline` is the remaining confirmation and must be performed after merge.
- Claude project discovery is wired through `.claude/skills`, which is the long-standing tracked symlink to `../.agents/skills`.
- In this linked worktree the symlink resolves and skill files are readable through it.
- CI and CONTRIBUTING assert `[ "$(readlink .claude/skills)" = "../.agents/skills" ]` (and the same check for `.codex/skills` and `.grok/skills` after this branch).
- These filesystem and CI checks support the wiring evidence but do not substitute for the runtime load observation above.

## Symlinks, worktrees, and clone

Separate disposable git repo probe (not firstmate content):

```sh
# after git add/commit of .agents/skills plus
# .claude/skills, .codex/skills, .grok/skills each -> ../.agents/skills
git clone <probe> <clone>
git worktree add <wt> HEAD
# in both clone and worktree: readlink and test -f <harness>/skills/x/SKILL.md
```

All three symlinks survived clone and linked worktree checkout and resolved to readable `SKILL.md` files when `core.symlinks` is enabled (default on this host).

## Contract that follows

1. Authors edit only `.agents/skills/`; never copy skill bodies into harness directories.
2. Harness-native paths stay symlinks to that tree so clone, worktree, and checkout stay one source of truth.
3. Do not invent a project path a harness does not scan; Grok's project `.codex/skills` is not a discovery root, while Codex does scan project `.codex/skills` when present.
4. Re-verify this record when a harness version changes skill-root behavior.
