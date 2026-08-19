# Kubernetes Cluster Authentication

This document explains how authentication works across the cluster: the identity
provider, the ways a service can integrate with it, and — importantly — the cases
where a service deliberately **bypasses** it because its clients cannot
authenticate through single sign-on.

Authentik is installed by `cluster/authentication.yml`; the proxy-level gating it
enables is wired up per-service by each service's own playbook. Playbook paths
are relative to `playbooks/nodes/`. Throughout, `<zone>` stands in for the
internal DNS zone and no real addresses are shown. Where each service sits on the
network — behind the shared gateway or on its own LAN IP — is covered in
[k8-cluster-network.md](k8-cluster-network.md).

## The identity provider — Authentik

Authentik is the cluster's central identity provider. It offers SSO over
OAuth2/OIDC, SAML, and LDAP, and backs the proxy-level authentication used by
most web UIs. It runs with a CloudNativePG PostgreSQL database and a Redis cache,
and its own startup credentials are generated on first run and stored through the
cluster secrets pipeline (OpenBao + External Secrets Operator).

Authentik's own web UI is exposed over HTTPS but is **not** gated by ForwardAuth —
it is the thing doing the authenticating, so gating it would be circular. Every
other protected surface routes its auth decision back to Authentik through one of
the models below.

A single **domain-level ForwardAuth provider** (covering the whole `*.<zone>`
space) is created in Authentik once. With that in place, any service in any
namespace can opt into proxy-level SSO simply by deploying its own Traefik
Middleware and route filter — no change to Authentik and no re-run of the
authentication playbook is needed to onboard a new service.

## Integration models

A service authenticates in one of three ways. The first two route through
Authentik; the third deliberately does not.

### Model A — Proxy-level gating (ForwardAuth)

The reverse proxy (Traefik) asks Authentik to authorize **every request** before
it reaches the backend, via a `forwardAuth` Middleware attached to the service's
route. The application itself needs no auth awareness at all.

Flow for a browser request:

```
Browser → Traefik → (ForwardAuth) → Authentik outpost
   ├─ no valid session  → redirect to the Authentik login page
   └─ valid session     → request proceeds to the backend, with identity
                          headers (X-authentik-username, -groups, -email,
                          -name, -uid) forwarded to the app
```

This is the default for web UIs that have weak or no native auth of their own —
the reverse proxy becomes the security boundary. Representative users: the
Traefik dashboard, the Hubble UI, and app UIs such as Firefly III, Jellyfin,
Open WebUI, and the Syncthing GUI. The OpenBao UI is a notable partial case: its
browser UI path is gated by ForwardAuth while its API path stays token-based and
ungated, because ESO and the CLI authenticate to the API with tokens, not a
browser session.

### Model B — Native OIDC / OAuth2 (app-level SSO)

The application has its **own** OIDC client and redirects users to Authentik to
log in, then manages its own session. Authentik generates the client ID and
secret; those are written into OpenBao and materialized into the app's namespace
by the External Secrets Operator.

Because Authentik holds one copy of the client secret and OpenBao holds another,
keeping the two sides aligned can require a reconciler. Vaultwarden is the worked
example: it logs users in against Authentik via OIDC, and a small scheduled
CronJob reconciles the OIDC client credentials between OpenBao and Authentik so a
rotation on either side heals automatically.

**Immich** stacks Model B underneath Model A: its route still carries the
ForwardAuth middleware, and behind that gate Immich runs its own OIDC login
against Authentik. It needs no reconciler because its playbook re-fetches the
client credentials from the Authentik API on every run, so the two sides cannot
drift.

### Model C — Bypass (the app's own auth is the boundary)

The service is **not** gated by Authentik at all. Its own built-in
authentication is the security boundary. This is not laziness — it is required
whenever a service's real clients cannot participate in a browser SSO flow (see
the next section).

## Why some services bypass Authentik

Both Authentik-backed models ultimately depend on a **browser following an HTTP
redirect** to the login page. That assumption holds for a human at a web UI. It
breaks for:

- **Native/mobile apps and API clients** that authenticate with a long-lived
  bearer token and speak to `/api/*` endpoints. They cannot follow a 302 to an
  SSO provider — they would receive the login HTML instead of their API
  response and fail.
- **Protocol clients** that only speak HTTP Basic, WebDAV, or a non-HTTP wire
  protocol, and have no notion of an interactive login redirect.

For these, putting a ForwardAuth gate in front would simply break the client.
Half-gating (gating the UI but exempting the `/api/*` paths the client needs)
would leave essentially the entire attack surface ungated anyway — so it buys no
security while adding complexity. The correct move is to let the application's
**own** authentication be the boundary and skip Authentik for that service.

The consequence: for a bypassed service, its native auth is doing the real work,
so it must be configured strongly — e.g. enabling multi-factor authentication in
the app, requiring a bearer token on every API call, or enforcing HTTP Basic with
a strong credential.

### Services that bypass Authentik

| Service | Client that forces the bypass | What secures it instead |
|---------|-------------------------------|-------------------------|
| **Home Assistant** | iOS/Android companion apps hit `/api/*` and the websocket with long-lived bearer tokens; they cannot follow an SSO redirect. | Home Assistant's built-in login; enable MFA in the user profile after onboarding. |
| **vLLM** | OpenAI-compatible API clients authenticate with a bearer token, not a browser session. | A bearer token required on every API request. |
| **Zotero (WebDAV)** | Zotero desktop/mobile clients only speak HTTP Basic and do not follow redirects. | Apache HTTP Basic auth against an htpasswd credential (bcrypt-hashed, delivered via OpenBao + ESO). |
| **Vaultwarden (native clients)** | The desktop/mobile/browser-extension Bitwarden clients call the Vaultwarden API directly rather than through the browser flow. | Vaultwarden's own account auth. (Its **web vault** UI still uses Model A + Model B; only the API path bypasses ForwardAuth.) |
| **Syncthing (sync protocol)** | The peer block-exchange/discovery protocol is not HTTP and has no login concept. | Syncthing's own device-ID/TLS peer authentication. (Its **GUI** still uses Model A.) |
| **Harbor (registry API)** | containerd pulls images over `/v2` and fetches a token from `/service`; it cannot follow a redirect to a login form and reports the returned HTML as a malformed manifest. | Harbor's own token issuer, which returns an anonymous pull token because the proxy cache projects are public. `hosts.toml` has no credentials field and the cluster's `imagePullSecrets` match on the registry named in the image reference rather than the mirror contacted, so no credential in the cluster reaches Harbor. These paths serve cached copies of images that are public upstream. (Its **web portal** uses Model A + Model B; only the registry paths bypass ForwardAuth.) |

The common thread: **the bypass is dictated by the client, not the service.** A
service is gated by Authentik when its users arrive through a browser that can be
redirected to log in; it is bypassed when its real clients can't be, and in that
case the service is responsible for authenticating them itself.
