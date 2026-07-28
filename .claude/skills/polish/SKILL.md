---
name: polish
description: >-
  Clean up the changes made so far in this session: strip the residue left by
  debugging and prototyping so only the settled solution remains, add comments
  capturing the non-obvious details and reasons nobody will remember later, fix
  grammar and spelling, and make the files consistent with each other in
  structure, terminology, and documentation. Use this whenever the user asks to
  polish, clean up, tidy, or take a pass over the changes, and offer it after a
  long or messy stretch of work — especially after debugging, where dead ends
  and scratch edits pile up invisibly. Covers the session's changes by default,
  or whatever files the user names instead — "polish the playbooks", "clean up
  the whole cluster directory".
---

# Polish

## Why this exists

Working code and finished code are different things. Getting something working
means trying approaches that don't pan out, adding temporary instrumentation, and
leaving half the reasoning in your head instead of the file. None of that residue
announces itself afterward — it looks like part of the solution.

Polish is the pass that separates the two: keep what the settled solution needs,
remove what only the journey needed, and write down what was learned along the
way before it evaporates.

## Scope and approach

By default, the uncommitted changes — tracked modifications plus untracked files.

```sh
git status --porcelain
git diff HEAD
```

A clean tree usually means the work was committed mid-session rather than that
there is nothing to do. Fall back to recent history, and use what you know of this
session to decide where the work starts:

```sh
git log --oneline -20
git diff <commit-before-the-group>..HEAD
```

The session is what identifies the group, not the history — commit messages alone
won't tell you which ones belong to the work you were just doing. If the session
doesn't give you that, ask rather than guessing at a range. Edits then land as new
uncommitted changes on top, which is the reviewable outcome anyway.

Stay inside that set. A file you didn't touch this session is out of scope even if
it breaks the same rules — say what you noticed and ask, rather than widening the
diff. Unrelated edits bury the work they're mixed into and make it harder to
review.

Widening is the user's call, and they make it explicitly: when they name a scope —
a file, a directory, "all the playbooks" — that becomes the scope and the
changed-file default no longer applies.

Re-read `CLAUDE.md` from disk before starting. It defines what correct looks like
here, and the copy loaded at session start goes stale — the user edits that file
precisely when they notice a standard they want enforced.

Make the changes directly and report afterward rather than presenting a list and
waiting. Ask first in only two cases: cluster resources you didn't install
yourself, and anything where you genuinely can't tell whether the current state is
deliberate.

## What to do

### 1. Keep only what the settled solution needs

Remove what accumulated while getting there: superseded attempts, commented-out
code kept "just in case," debug output, verbosity or timeouts bumped for
troubleshooting and never restored, tasks that no longer do anything, variables
and files nothing references anymore, comments describing an approach that was
later abandoned.

The test is whether a reader coming to this fresh would need it to understand or
run the solution. If it only makes sense as a record of how you got here, it goes.

Cluster resources installed while debugging come out too — images, Helm releases,
manifests. Ask first about anything you didn't install yourself: what looks like
debris may be load-bearing, and that is expensive to get wrong.

### 2. Write down what won't be remembered

Sweep for the notes `CLAUDE.md` calls for that aren't there. Reasoning decays
fast: it lives in the session that produced it and is gone once the session ends,
so this is the last cheap moment to capture it.

### 3. Fix grammar and spelling

Comments, task names, documentation, variable names. Fix these directly —
they're unambiguous and don't need discussion.

### 4. Make the files consistent with each other

For each changed file, find its closest existing sibling — a playbook in the same
category, a template of the same kind — and compare against it point by point
rather than reading for a general impression. A general impression is what let
the drift through in the first place.

Drift toward the conventions of nothing in particular happens under time pressure
and is invisible from inside the session that caused it.

## Report

Close with a short summary grouped by reason:

```
## Polished

**Removed** — <what, from where>
**Documented** — <file>: <what now has a reason attached>
**Language** — <what was fixed>
**Consistency** — <file>: <what it was aligned to>

**Needs your call**
- <anything left untouched, and why>
```

Drop empty sections. If nothing needed changing, say so in a sentence rather than
producing an empty report.
