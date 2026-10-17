# Parallel-agent conventions

Multiple agents (loop builders + ad-hoc sessions) share this clone.
Git itself is fine — every incident so far has been agents sharing
mutable state. Rules below are ordered by blast radius.

## 0. Diagnose before touching

Before editing anything in a checkout, run:

```bash
git worktree list          # who lives where
git branch --show-current  # whose branch is this tree on
git status --short         # is there live, uncommitted work
```

If the tree has uncommitted changes you did not make, it is OCCUPIED:
do your work elsewhere. No exceptions, no "quick fix while I'm here".

## 1. One worktree per writer — including ad-hoc sessions

`builder-run.sh` already does this for loop work (`worktree +
branch per issue, "work ONLY inside this worktree"`). Ad-hoc sessions
must do the same instead of working in the main checkout or another
agent's tree:

```bash
git fetch origin
git worktree add ~/Repos/worktrees/agent-<n>-<slug> -b agent-<n>-<slug> origin/main
```

Remove your worktree when done (`git worktree remove <path>`).
Never `checkout` another branch inside someone's tree, never edit files
outside your own worktree.

## 2. Branch per workstream, cut from origin/main

- Never commit on `main`, and never commit on another agent's branch.
- Push your branch regularly — a pushed branch is backup + visibility;
  an unpushed one exists only in one worktree.
- Commit WIP frequently, even broken (`git commit -m "wip: …"`).
  History can be rewritten; work swept away by someone else's reset
  cannot. Long-lived uncommitted changes are a conflict accruing
  interest — 37 staged files is how merges go bad.

## 3. `git stash` is banned in shared clones

Stash is clone-global mutable state with no owner. One `git stash`
sweeps every writer's tracked work into a single entry (this has
happened: feature code + another session's tests vanished into one
`stash@{0}`). What to do instead:

- Preserve work → WIP commit on your own branch (see rule 2).
- Move work aside → commit it, then `git revert`/`reset` your own
  branch only — never touch another tree's state.
- Snapshots of a whole tree → commit (even on a `snapshot/` branch),
  never stash.

## 4. Merge in isolation, verify, then publish

- Merge into `main` from a throwaway worktree on `main`
  (`git worktree add /tmp/opencode/merge-<topic> main`), never inside
  someone's live tree. Fast-forward when possible; resolve conflicts
  there.
- Exception: the loop's `merge.sh` merges fully-gated agent PRs server-side
  (`gh pr merge --merge`) with no local checkout at all — that is the ONLY
  automated path to `main`. Loop builders still never merge anything
  themselves (see `builder-run.sh` rule 5).
- Verify the result before it becomes shared truth: server
  `pytest tests/`, `flutter analyze`, and note pre-existing breakage
  explicitly rather than shipping it silently.
- Pushing `main` moves every other agent's base — say so in your
  report. Remote branch cleanup (`git push origin --delete …`) only
  for branches you own.
- Never write `fix(es|ed) #N` / `close(s|d) #N` / `resolve(s|d) #N` in a
  commit message unless the commit actually resolves that issue:
  GitHub auto-closes the issue when the push lands on `main`. Process
  commits once silently closed #29 and #32 this way ("fixes #29 stall"
  meant the stall, not the issue). Reference without closing via
  `refs #N` / `see #N`.
- Uncommitted work is unmergeable by definition. If a branch's
  checkout still holds WIP, merge the commits and leave the WIP for
  its owner — do not commit it for them, do not pop/apply stashes
  that mix multiple writers' work (cherry-pick per-owner instead).

## 5. The rest still applies

Data guardianship (`data-guard.sh`, mass-delete guards, backups),
never-wipe-device-data, and the UX-walk rule all hold across every
worktree. A merge that touches persisted models must satisfy the
guardian the same as any direct change.
