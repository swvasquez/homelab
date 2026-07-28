---
paths:
  - "playbooks/*/*/*.yml"
  - "playbooks/*/*/templates/*.j2"
---

# Playbook conventions

- Open with a file header describing what the playbook does, organize the body into
  banner-headed sections, and document every input variable.
- Give every task a descriptive name and a fully qualified module name —
  `ansible.builtin.apt`, not `apt`.
- Prefer `ansible.builtin.*` over adding a Galaxy collection to `requirements.yml`.
  Reach for a collection only when the builtin approach is genuinely worse, and say
  why in the playbook.
- Use `become_exe: sudo.ws` whenever `become: true`.
- Install packages through a package manager, usable by all users rather than only
  the installing account.
- Pair any internet download with the task that removes the temporary file.
- Keep long content out of the playbook. Scripts, YAML, JSON, and config files go in
  a `.j2` file under the neighboring `templates/` directory, rendered with
  `ansible.builtin.template` — not inlined under `copy: content:` or in a shell
  heredoc.
- List all variables explicitly with dummy values, and reference the source rather
  than duplicating a value. Local network IPs come from `inventory.yml` or
  `group_vars`.
- Keep lines under 100 characters where practical (`just lint` allows 160).

After changing a playbook, update `README.md` and the `justfile` to match, then run
`just lint` last.

Banners are comment rules — `=` for the file header, `-` for sections within
`tasks:`, indented to match the tasks they introduce. The `justfile` uses a
different style; don't carry it over.

```yaml
# ==============================================================================
# Playbook: Deploy Zotero WebDAV Server via ArgoCD GitOps
# ==============================================================================

    # -------------------------------------------------------------------------
    # Namespace and service account
    # -------------------------------------------------------------------------
```

