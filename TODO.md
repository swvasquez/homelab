# TODO

- **Traefik as Gateway API controller** — Traefik is used instead of Cilium's built-in Gateway API
  controller because Cilium does not support ForwardAuth middleware. Traefik's `kubernetesCRD`
  provider enables the `Middleware` CRD required for Authentik ForwardAuth. If Cilium adds native
  ForwardAuth support in a future release, Traefik can be removed and all HTTPRoutes migrated back
  to a Cilium-managed Gateway.

- **AMD GPU Operator** The existing nodes use Ryzen AI APUs (integrated graphics), not AMD Instinct data center GPUs. The Kubernetes AMD GPU Operator only supports AMD Instinct accelerators (MI100 through MI355X). Revisit installation of the AMD GPU Operator (or any of its constituent compnents) once supported.

- **CA-backed TLS issuer** — cert-manager currently uses a `selfSigned` ClusterIssuer, meaning each
  certificate is self-signed individually with no common CA. This prevents pods from trusting internal
  HTTPS endpoints (e.g. Immich calling Authentik for OIDC). The workaround is `NODE_TLS_REJECT_UNAUTHORIZED=0`
  in the Immich server. The proper fix is to create a self-signed CA Certificate in cert-manager, create
  a CA-backed Issuer that signs with it, re-issue the wildcard cert via that issuer, and mount the CA cert
  into any pod that makes internal HTTPS calls (setting `NODE_EXTRA_CA_CERTS` for Node.js services).