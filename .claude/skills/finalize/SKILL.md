---
name: finalize
description: >-
  Get the session's changes ready to commit: run the polish skill over them,
  check that everything the change implies was actually updated — justfile,
  README, docs, and comments elsewhere that describe the changed behavior —
  review what the change exposes and recommend security tightening, then propose
  a one-line commit message. Use this whenever the user says finalize, wrap up,
  or asks to get the changes ready to commit, for a security once-over, or for a
  commit message. Proposes only — never stages, commits, or pushes anything.
---

# Finalize

## Steps

**1. Run the `polish` skill.**

Run it in full, even if it ran earlier in the session — any edit made since then
has had no pass over it, and that is exactly the work most likely to need one.

**2. Check that everything the change implies was actually updated.**

Where `polish` looks inward at the changed files, this looks outward at what else
should have changed with them: `justfile` recipes, `README.md`, files under
`docs/`, and comments elsewhere in the codebase that describe behavior which has
since moved.

These are easy to leave behind precisely because nothing fails when you do. The
code works, the playbook runs, and the documentation quietly becomes wrong — which
is worse than no documentation, because it's still trusted.

Work outward from the diff: for each change, ask what else claims to describe it,
and verify the claim is still true.

Check `docs/configuration.md` specifically. Every field the change adds to or
renames in `inventory.yml` or `group_vars/` has to appear there. Those files are
gitignored, so that document is the only record of their shape — a field missing
from it is a field a fresh clone has no way to know it needs, and the omission
surfaces as an undefined-variable error with nothing to explain it. This is the
sub-check that gets skipped, because the playbook runs fine on the machine where
the value already exists.

Write each field in bracket notation — `<HOSTNAME>`, `<IP>`, `<PORT>`,
`<true|false>` — never a real value. Keep literals literal where the value is
part of the shape rather than site-specific (`protocol: tcp`, `node_only: true`).

**3. Reconsider what the change exposes.**

Getting something working and getting it working safely are different problems,
and the first is usually solved under pressure. Loosening something to make
progress — opening a port, disabling verification, running as root, widening a
permission — is a normal part of debugging. It is also the least likely thing to
be tightened afterward, because nothing breaks when it isn't.

So read the diff a second time asking only one question: what can now reach, read,
or do something it couldn't before?

*Secrets.* Real values, keys, tokens, or passwords in files that get committed.
Secrets passed on a command line, written into logs, or landing in a
world-readable file. Anything that should come from `pass` or `bao` but is inline
instead.

*Reach.* New listening ports, UFW rules, `LoadBalancer` services, ingress routes,
NFS exports, or mounts. Check each is scoped to the LAN rather than to everything,
and that whatever became reachable requires authentication to use.

*Privilege.* Containers running as root or `privileged: true`, added capabilities,
host networking or hostPath mounts, `become: true` on tasks that don't need it,
files or directories given broader modes than the job requires.

*Trust.* TLS verification disabled, certificate checks skipped, unpinned images,
downloads whose integrity isn't verified, default credentials left in place.

*Residue with consequences.* The port opened to test connectivity, the check
disabled to isolate a problem, the permission widened to rule something out. These
outlive the session that needed them.

Report these as recommendations with reasoning rather than applying them.
Tightening security can break a working deployment, and which risks are worth
carrying in a homelab is the user's call.

**4. Propose a one-line commit message.**

Read the polished diff and describe what the change accomplishes, not which files
moved. Match the style of the existing history rather than imposing a convention:

```sh
git log --oneline -15
```

One line, no body. Print it in a code block so it can be copied. Hand it over and
stop there — this skill proposes the message, the user does the committing.
