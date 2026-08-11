---
paths:
  - "**/*.yml"
  - "**/*.yaml"
  - "playbooks/*/*/templates/*.j2"
---

# YAML conventions

- Use `true` and `false`, not `yes` and `no`.
- Quote only where the quotes do work: separating a string from another type,
  escaping a YAML-reserved construct, containing special characters, or wrapping
  Jinja templating.
- Prefer single quotes; use double only when escaping requires them. Single quotes
  are literal, so a double-quoted value signals that escaping is happening.
- These are defaults. Where following them makes a value harder to read, take the
  clearer option rather than restructuring the value to fit.

`yamllint`'s `quoted-strings` rule enforces this and is deliberately left off: it
reports 400+ findings across the existing playbooks. Don't enable it outside a
dedicated cleanup pass — and note that adding a `.yamllint` replaces
ansible-lint's bundled defaults rather than extending them.
