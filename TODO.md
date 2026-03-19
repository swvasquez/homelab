# TODO

- **Traefik as Gateway API controller** — Traefik is used instead of Cilium's built-in Gateway API
  controller because Cilium does not support ForwardAuth middleware. Traefik's `kubernetesCRD`
  provider enables the `Middleware` CRD required for Authentik ForwardAuth. If Cilium adds native
  ForwardAuth support in a future release, Traefik can be removed and all HTTPRoutes migrated back
  to a Cilium-managed Gateway.

- **AMD GPU Operator** The existing nodes use Ryzen AI APUs (integrated graphics), not AMD Instinct data center GPUs. The Kubernetes AMD GPU Operator only supports AMD Instinct accelerators (MI100 through MI355X). Revisit installation of the AMD GPU Operator (or any of its constituent compnents) once supported.
- 