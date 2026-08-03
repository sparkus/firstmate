# Harness skill discovery verification

Audience: maintainer verification.

This record supports the shared project-skill layout: `.agents/skills/` is the single canonical tree, and harness-native paths are symlinks to it (`.claude/skills`, `.codex/skills`, `.grok/skills`).
It records what each harness actually resolved on the versions below.
Task chronology stays in private reports or PR evidence.

Verified 2026-08-03 in the isolated firstmate worktree at
`/Users/agwerschky/.no-mistakes/worktrees/e661563b090a/01KZ4B0458NGJFN2BJ5QTM3VFN`
at commit `5939a39fbf2e52a6fe8e22a56d42cfdc2c8a65b0`.

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

Relevant output for the new skill, after confirming that neither it nor `firstmate-coding-guidelines` existed under `~/.grok/skills`:

```json
{
  "skill": {
    "name": "ticket-queue-discipline",
    "source": {
      "type": "project",
      "path": "/Users/agwerschky/.no-mistakes/worktrees/e661563b090a/01KZ4B0458NGJFN2BJ5QTM3VFN/.grok/skills/ticket-queue-discipline/SKILL.md"
    },
    "userInvocable": false
  }
}
```

Findings:

- Project discovery works.
- Documented and observed project roots include `.grok/skills/`, `.agents/skills/`, and `.claude/skills/` (Claude compat).
- Grok does **not** treat project `.codex/skills/` as a skill root (probe skill there never appeared).
- With only the canonical `.agents/skills` tree present (before harness symlinks), every firstmate internal skill resolved as `source.type=project` with path under `.../firstmate/.agents/skills/<name>/SKILL.md`.
- After adding `.grok/skills -> ../.agents/skills`, the same skills resolve once (name-deduped) with path under `.../firstmate/.grok/skills/<name>/SKILL.md`.
- `firstmate-coding-guidelines` and `ticket-queue-discipline` were both absent from `~/.grok/skills`, so their observed `source.type=project` results did not come from user-level copies.
- User-level skills still come from `~/.grok/skills/` (and optional Claude user compat paths).

### Codex

Commands:

```sh
codex debug prompt-input "x"
# parse the model-visible ## Skills / ### Skill roots section
```

Relevant model-visible output:

```text
- `r0` = `/Users/agwerschky/.no-mistakes/worktrees/e661563b090a/01KZ4B0458NGJFN2BJ5QTM3VFN/.agents/skills`
- ticket-queue-discipline: Agent-only judgment for tracker-backed ticket work. Load before claiming, dispatching, closing, or auditing tickets in a project tracker so readiness, claims, and close reasons sta (file: r0/ticket-queue-discipline/SKILL.md)
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
claude -p --output-format stream-json --verbose --no-session-persistence \
  --permission-mode dontAsk --tools Skill \
  --debug-file /var/folders/bd/ky17fvwx45353ky4s2bg8ys80000gn/T/no-mistakes-evidence/01KZ4B0458NGJFN2BJ5QTM3VFN/claude-skill-debug.log \
  --system-prompt 'Use the Skill tool when instructed. Do not use any other tool.' \
  'Load the project skill ticket-queue-discipline. Then reply only: LOADED ticket-queue-discipline.'
rg 'Loading skills from:|SkillTool returning' \
  /var/folders/bd/ky17fvwx45353ky4s2bg8ys80000gn/T/no-mistakes-evidence/01KZ4B0458NGJFN2BJ5QTM3VFN/claude-skill-debug.log
```

Findings:

- Claude's debug log names the project skill root as this worktree's `.claude/skills` path.
- The agent invoked `Skill` with `{"skill":"ticket-queue-discipline"}`.
- The runtime returned `Launching skill: ticket-queue-discipline`, logged `SkillTool returning 2 newMessages for skill ticket-queue-discipline`, and the agent replied `LOADED ticket-queue-discipline.` with `subtype=success` and `is_error=false`.
- This is a live load of the new skill in the feature worktree, not an inference from the symlink alone.
- `.claude/skills -> ../.agents/skills` resolves that runtime root to the same canonical body used by Codex and Grok.
- CI and CONTRIBUTING assert `[ "$(readlink .claude/skills)" = "../.agents/skills" ]` (and the same check for `.codex/skills` and `.grok/skills` after this branch).
- These filesystem and CI checks support the wiring evidence but do not substitute for the runtime load observation above.

## Symlinks, worktrees, and clone

The target commit records all three harness paths as git symlinks with the same link-target blob:

```sh
git ls-files -s .claude/skills .codex/skills .grok/skills
```

```text
120000 2b7a412b8fa0fb7e985b0793321bd4e698f2b6cd 0	.claude/skills
120000 2b7a412b8fa0fb7e985b0793321bd4e698f2b6cd 0	.codex/skills
120000 2b7a412b8fa0fb7e985b0793321bd4e698f2b6cd 0	.grok/skills
```

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
