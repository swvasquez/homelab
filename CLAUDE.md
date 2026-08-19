## Dependencies and installation

- Install from trusted, official sources; pin images to explicit tags (never `latest`).
- Use the latest stable version, and research online to confirm it has no known
  security issues.

## Documenting decisions in playbooks

The homelab installs many tools not designed to work together, so their
interactions are emergent and documented nowhere upstream. Each playbook should be
self-explanatory without cross-referencing others.

- Note why a non-obvious configuration or change was made — an obscure setting
  given an unusual value, an ordering that matters — and why something was
  deliberately *not* done or couldn't be (e.g. a conflict with another tool).
  Add these as you go, not only when asked.
- The test: if an agent couldn't recover the reason from a single tool's own docs,
  write it down. Err toward more.

## Writing docs and comments

Write for someone looking something up, not someone reading start to finish.

- State what something does, not what it guarantees or what it means. Prefer a
  fact I could verify over a characterization of it — "there are no SSH keys"
  rather than "the operator remains the only path to the nodes".
- Don't editorialize. Cut words that tell me how to regard a fact rather than
  adding one: "worth knowing", "importantly", "notably", "and nothing else",
  "exactly", "the real point is". If a sentence stays true after deleting a
  phrase, that phrase was doing rhetorical rather than technical work.
- No summarizing maxims. "A read-only role that cannot be shown to refuse
  something is not demonstrated" is prose performing, not informing.

## Debugging

- You can run commands on this machine directly — `kubectl`, Ansible, and `sudo`
  included. `sudo` raises an authentication prompt I'll deny if I don't want it.
- The service and DNS load balancers sit on the LAN, so `curl` cluster services
  directly by IP or DNS name rather than asking me to reach them.
- In the sandbox (`SANDBOX_VM_ID` is set), the deny rules `.sbx/config.py`
  computes cover the LAN and `*.homelab.internal`, and subtract the API server
  address only when I start it with `just sbx-up cluster`. `kubectl` can work
  there while the `curl` above does not. `kubectl auth can-i --list` tells the
  two modes apart: it prints the verbs the agent identity holds when the sandbox
  has access, and errors when it doesn't.
- The token in `.sbx/agent.kubeconfig` expires. Minting a new one is
  `just agent-kube-config`, which reads the admin kubeconfig on my machine, so
  ask me rather than reading an authentication error as a cluster fault.
- `playbooks/nodes/cluster/templates/agent-cluster-role.yml.j2` is the
  permission specification for that identity. Read it before concluding a
  `kubectl` command isn't permitted.
- Anything on the homelab nodes has to go through me. Give me one command at a
  time and wait for the output before proposing the next.
- If several commands aren't getting you what you need, stop and say you're not
  making progress rather than pressing on.
- A grep that finds nothing is not evidence that something is unused. Config keys
  are frequently consumed by a loop over their parent collection and never appear
  by name — search for the parent, then read how it's iterated, before concluding
  anything is dead. The same trap hides in `dict2items` loops, `with_items` over a
  variable, and templates that render a whole dictionary.
- Remove anything you installed to debug — images, Helm releases, manifests — once
  it has served its purpose. Ask before removing anything you didn't install.

## Following existing structure

- Look for precedent and match existing patterns rather than inventing your own —
  file organization, comments, and documentation alike.
- Use one term per concept, everywhere it appears: playbooks, variable names, task
  names, comments, and docs. Two names for one thing reads as two things.
- Use American spelling.

## Skills

Skills in `.claude/skills/` are procedures invoked on demand; this file is the
standing rules that apply always. Keep the standards here and have skills cite
them rather than restate them, so the two can't drift apart.

- Ask before creating a skill or changing an existing one.

## Scope

- Don't combine files or create new ones — tests especially — unless asked.
- Work through files one at a time when there are many. Loading everything at once
  trades depth for coverage — you end up with an impression of each file rather
  than having actually read it.
- Read-only git only. Never `git add`, `git commit`, `git push`, or anything else
  that changes repository state; staging and committing are mine.
- The repository root collects scratch files that aren't meant to be committed.
  The `.gitignore` allowlist is the test — anything it excludes is scratch. Don't
  read, clean up, or comment on those files unless I point at one.

## Communication

Be concise in concepts, not in word count. When several justifications could
support something, decide which one is load-bearing and explain that one properly
instead of listing them all briefly — the chosen reason needs room to land. The
same applies to options, caveats, and trade-offs. If the others matter
independently, say so in a sentence rather than giving each equal billing.

- If something I say is nonsensical or obviously wrong, ask me to clarify. Don't
  quietly reinterpret it as an adjacent concept and answer that instead.
