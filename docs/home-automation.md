# Home Automation Notes

Working notes on the home-automation stack: what we've deployed, why each piece
is needed, and how the Thread/Matter networking fits together. The platform and
radio infrastructure are up and the first Matter-over-Thread device is
commissioned and controllable from Home Assistant; treat this as a running log of
the current state rather than a finished reference.

Everything here is deployed via GitOps by two playbooks:
`service/home-assistant.yml` (the controller) and `service/thread.yml` (the radio
and Matter infrastructure), both relative to `playbooks/nodes/`. No real
addresses appear below; `<zone>` stands in for the internal DNS zone.

## What we've deployed

| Component | Role |
|-----------|------|
| **Home Assistant** | The automation controller and dashboard — the thing a user actually interacts with. |
| **OpenThread Border Router (OTBR)** | Bridges the Thread mesh network to the LAN and drives the USB radio. |
| **ZBT-2 USB radio** | The physical Thread radio hardware (Home Assistant Connect ZBT-2). |
| **Matter server** | Commissions and controls Matter-over-Thread devices on Home Assistant's behalf. |
| **generic-device-plugin** | Hands the USB radio to the OTBR pod safely, without a privileged container. |

## Why each component is needed

### Home Assistant
The hub. It holds the dashboards, automations, and device state, and it's the
single UI/app surface for the whole system. It does **not** talk to radios or
devices directly — it delegates to OTBR and the Matter server (below) over the
network. Everything else in this stack exists to give Home Assistant a path to
physical devices.

### OpenThread Border Router (OTBR)
Thread devices live on their own low-power IPv6 mesh; nothing on the LAN can
reach them directly. OTBR is the **router between the two networks**. It drives
the USB radio over a serial link, creates the mesh-side network interface, and
routes IPv6 between the Thread mesh and the LAN. Without it, the Thread mesh is
an island.

### ZBT-2 USB radio
OTBR is software; it needs a radio to actually transmit on the 802.15.4 Thread
band. The ZBT-2 is that radio. It must be **flashed with OpenThread RCP
firmware** first — it ships with Zigbee firmware, and nothing in the cluster can
reflash it, so this is a one-time out-of-band prerequisite. As an RCP ("radio
co-processor") it's a dumb radio: all the Thread stack logic runs in OTBR, and
the ZBT-2 just does the RF.

### Matter server
Matter is the application-layer protocol devices actually speak;
Thread/OTBR only provide the IPv6 transport underneath. The Matter server is
what **commissions** (onboards) devices and issues commands to them, exposing a
websocket API that Home Assistant's Matter integration drives. We use the
Matter.js Open Home Foundation server specifically because it coexists with OTBR
on mDNS (see below); the older Python matter-server does not.

### generic-device-plugin
This one is about *how* we give OTBR its radio, not a functional feature.
Kubernetes has no equivalent of Docker's `devices:` mapping, so the naive way to
pass a serial device into a pod is `hostPath` + `privileged` — which grants all
capabilities, all host devices, and disables seccomp. Instead, the device plugin
advertises the USB radio and the TUN device to the kubelet as **allocatable
resources**, and the OTBR pod requests them like any other resource. That lets
OTBR run **unprivileged** with only the three capabilities it genuinely uses
(`NET_ADMIN`, `NET_RAW`, `IPC_LOCK`) instead of full privilege. This follows the
homelab's least-privilege policy for workloads.

## How the Thread/Matter networking works

The key idea: **Home Assistant never touches the radio or the devices directly.**
It manages two in-cluster services, and those services do the low-level work.

```
Home Assistant
   ├─ (OTBR integration, REST)      → OTBR ── serial ── ZBT-2 radio ))) Thread mesh (IPv6)
   └─ (Matter integration, websocket) → Matter server ─┐
                                                        └─ device traffic routed
                                                           as ordinary IPv6 through
                                                           OTBR onto the Thread mesh
```

Step by step:

1. **Home Assistant → OTBR (REST).** Home Assistant manages the border router
   (form/inspect the Thread network) through OTBR's REST API. This is control of
   the *network*, not the devices.
2. **OTBR → ZBT-2 → Thread mesh.** OTBR drives the ZBT-2 over serial to create
   the mesh interface and route IPv6 between the Thread mesh and the LAN. From
   the LAN's point of view, Thread devices become reachable IPv6 hosts.
3. **Home Assistant → Matter server (websocket).** To onboard or command an
   actual device, Home Assistant calls the Matter server over its websocket API.
4. **Matter server → device.** The Matter server speaks Matter to the device.
   That traffic is just IPv6, and it **transits OTBR** onto the Thread mesh like
   any other routed packet. Matter is the language; Thread/OTBR is the road it
   travels on.

## Commissioning a new Matter-over-Thread device

A factory-new Thread device has no network credentials yet, so it has no IP and
can't be reached over the LAN or the mesh. First contact has to happen over
**Bluetooth (BLE)**: the commissioner talks to the device over BLE, hands it the
Thread network credentials, and only then does the device join the mesh and
switch to IPv6.

How that Bluetooth is supplied is set by the `matter_server_ble_mode` variable in
`service/thread.yml`, and there are two workflows. **Local** (the default) drives a
Bluetooth adapter on the radio host directly and is far simpler; **proxy** borrows
an off-cluster machine's Bluetooth and is the fallback for when the radio host has
no Bluetooth of its own. Either way, the device is **factory-reset** first and must
be **physically near** the Bluetooth radio for the handshake — a few feet — after
which it lives anywhere on the mesh.

### Method A — local adapter (`matter_server_ble_mode: local`)

The Matter server drives a Bluetooth adapter on the radio host itself (through the
host's BlueZ over D-Bus), so there is **no `/ble` proxy slot** and Home Assistant
is never involved. Commissioning is a pure dashboard operation:

1. **Factory-reset the device** and bring it next to the radio host's Bluetooth.
2. Open `https://matter-server.<zone>`, choose **Commission node**, and enter the
   device's pairing code (the 11-digit manual code on the device or its QR card).
3. Watch it run — BLE pairing → attestation → Thread join → operational discovery
   → complete — ending with the node listed and `available`. It then shows up in
   Home Assistant under Settings → Devices & Services → Matter.

No `uvx` bridge, no scaling Home Assistant down. The host-side setup this needs —
`bluez`, the BlueZ D-Bus policy, and the AppArmor profile — is applied by
`service/thread.yml` when the mode is `local`; see the "local Bluetooth" design
note below.

### Method B — BLE proxy (`matter_server_ble_mode: proxy`)

Use this only when the radio host has no Bluetooth of its own. The Matter server
exposes a single `/ble` websocket that a Bluetooth-equipped LAN machine bridges to,
which brings two frictions: you run a bridge process on that machine, and you must
take Home Assistant off the `/ble` slot first — it grabs the single slot on startup
with no radio behind it (a known HA regression), blocking the real bridge.

You need a **Linux machine with a working Bluetooth adapter**, on the LAN, close to
the device. (macOS can't be the bridge — it blocks third-party Matter BLE at the OS
level.)

1. **Free the `/ble` slot** — take Home Assistant off it (disable the ArgoCD
   self-heal first, or it scales straight back up):
   ```bash
   kubectl patch application home-assistant -n argocd --type merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   kubectl scale deploy/home-assistant -n home-assistant --replicas=0
   ```
2. **Start the bridge** on the nearby machine (`uvx` fetches Python 3.12 and the
   client; on Linux the host needs `bluez`):
   ```bash
   uvx --python 3.12 matter-ble-proxy --server wss://matter-server.<zone>/ble
   ```
   The bridge machine must trust the homelab CA for that name; if the client can't
   speak `wss://`, use the radio host directly — `ws://<radio-host-ip>:5580/ble`
   (that host port stays open).
3. **Commission** from `https://matter-server.<zone>` → **Commission node** →
   pairing code, exactly as in Method A.
4. **Restore Home Assistant** (re-enables self-heal and scales it back up):
   ```bash
   kubectl patch application home-assistant -n argocd --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```
5. **Stop the bridge** — Ctrl+C the `matter-ble-proxy`; it's only needed during
   commissioning.

### Gotchas (both methods)

- **Range matters more than you'd expect.** Keep the device within a **few feet**
  of the Bluetooth radio for the whole procedure — a weak link stalls or drops the
  pairing partway and the device rolls back. If the adapter is a Wi-Fi/Bluetooth
  combo card, confirm its antenna is connected: an antenna-less card fails with an
  unhelpful timeout even from across the room.
- **Failure is atomic.** A failed commission rolls the device all the way back —
  just **factory-reset and start over** (a rolled-back attempt may leave a stale
  entry that expires on its own).
- **After a mesh change**, the Matter server must already hold the current Thread
  dataset (it does once the mesh is formed); if the mesh was ever re-formed, re-sync
  the OTBR active dataset into the Matter server first, or the device joins the
  wrong network.

## Design decisions worth remembering

- **Least privilege over a privileged pod.** OTBR runs unprivileged via the
  device plugin (see above). The IPv6-forwarding sysctls a privileged OTBR would
  set as a side effect are instead applied persistently on the radio host, so we
  don't need privilege just for that.
- **Both OTBR and the Matter server are pinned to the radio host.** Only the node
  physically holding the ZBT-2 has a direct route to the Thread mesh — other
  nodes ignore the route-information options in the router advertisements by
  default. A per-host inventory flag marks the radio node (exactly one), the node
  is labeled, and both Deployments pin themselves there via `nodeSelector`. This
  survives moving the radio to a different node: reflag, and the workloads follow.
- **The radio host's LAN interface must keep its IPv6 link-local address.** OTBR
  sources its LAN Router Advertisements from that link-local, and border routing —
  and the SRP server that lets a joined device be discovered on the mesh — will
  not start without one. That interface is managed by systemd-networkd via
  `infrastructure/wol.yml`, so the link-local is preserved there specifically on
  the radio host, with only the Router-Advertisement *wait* disabled (which is
  what the boot-hang workaround in that playbook was actually guarding against).
  It is an easy cross-playbook coupling to miss: break the link-local in
  `wol.yml` and commissioning silently fails at operational discovery, with
  nothing wrong in the Thread manifests. This began as a runtime fix moved into
  the playbooks, so a radio-host reboot is still owed to confirm it survives one.
- **Local Bluetooth: capabilities stay dropped, but it needs two host grants.**
  In `local` BLE mode the Matter server reaches the host's Bluetooth adapter
  through **BlueZ over the system D-Bus socket** (`NOBLE_BINDINGS=dbus`, the host
  socket mounted in) rather than a raw HCI socket that would need
  `NET_ADMIN`/`NET_RAW` — so no added Linux capabilities. But two host-side pieces
  are required, and both fail silently-ish if missing:
  - **A custom AppArmor profile (not unconfined).** Kubernetes runs containers
    under the runtime's default AppArmor profile, containerd's equivalent of
    Docker's `docker-default`, which *blocks D-Bus method calls*:
    the container's first call (`Hello`) is denied and the server crashes with
    `write EPIPE`. Rather than dropping confinement entirely (`Unconfined`), local
    mode runs under a **custom profile that is `docker-default` verbatim plus one
    allow for D-Bus to `org.bluez`** — so every other restriction (the /proc,
    /sys, mount, and firmware denials) stays in force. `service/thread.yml`
    installs it (`matter-bluetooth.apparmor.j2`) into `/etc/apparmor.d/` on the
    radio host and loads it *before* the pod is applied; the pod references it via
    `appArmorProfile: Localhost`. Proxy mode keeps the runtime default. This is
    the privilege trade-off of local mode — one narrow D-Bus hole, not a dropped
    profile.
  - **A BlueZ D-Bus policy for the pod's uid.** BlueZ's shipped policy allows only
    root and the `bluetooth` group; the pod connects as uid 1000, so
    `service/thread.yml` installs a policy granting that uid access to `org.bluez`.
  Together these remove the `/ble` proxy slot — and with it the need to freeze
  Home Assistant to commission a device.
- **mDNS coexistence on one host.** OTBR and the Matter server both need mDNS on
  UDP 5353 on the same node — OTBR to publish the border-router service, the
  Matter server to discover devices. Two responders can only share that port if
  both set `SO_REUSEPORT`. That's why we build OTBR with the mDNSResponder
  backend and use the Matter.js server (whose sockets set `reuseAddr`); both are
  willing sharers. The stock OpenThread mDNS backend and the older Python
  matter-server each grab 5353 exclusively and cannot coexist.
- **Gateway exposure only for the Matter server's dashboard.** The Matter server
  has a commissioning dashboard, so it gets a **no-auth** HTTPRoute at
  `matter-server.<zone>` through the gateway — no
  ForwardAuth, since its clients (a browser dashboard and websockets) can't follow
  an SSO redirect, and the same port is already reachable on the host anyway. OTBR
  is not a browser UI, so its REST API gets no HTTPRoute. Both are still fronted by
  ClusterIP Services so Home Assistant reaches them by stable in-cluster DNS name —
  which keeps working even if the radio host changes. (With host networking, those
  Service names resolve to the current radio node's IP.)
- **Home Assistant is not behind SSO.** Its companion apps use bearer-token API
  calls that can't follow an SSO redirect, so it authenticates users itself;
  enable MFA in the Home Assistant profile. (Same rationale as the other
  bearer-token/API services in the cluster.)
- **Pod Security profiles are relaxed only where forced.** The cluster default is
  `restricted`, and both namespaces opt down from it by label. Home Assistant's
  official image runs as root, so its namespace uses the `baseline` profile
  (root allowed, but no privileged containers / host namespaces / hostPath). The
  Thread namespace uses `privileged` because host networking, `NET_ADMIN`, and
  the device plugin all exceed `baseline` — the label only *permits*; the actual
  pod specs still request the minimum they need.

## State that must not be lost

Three Longhorn PVCs hold everything the stack cannot regenerate:

| Volume | Holds | Cost of losing it |
|--------|-------|-------------------|
| Home Assistant `/config` | Configuration, integrations, and the SQLite recorder database | Full reconfiguration and loss of all history |
| Thread dataset | The Thread network's credentials and channel | The mesh has to be re-formed |
| Matter fabric | The fabric's commissioning credentials | **Every device has to be re-commissioned individually** |

The Matter fabric is the one to worry about. Re-commissioning is per-device and
physical — each device has to be reset and re-onboarded by hand — so this PVC
deserves attention before any storage migration or cluster rebuild.

## Rebuilding on a different radio host

Moving the radio to another node is mostly a matter of re-flagging it in
inventory, with one manual step that is easy to miss: **the OTBR image is built
on the radio host itself and consumed with `imagePullPolicy: Never`.** It is
built from OpenThread source with the `mDNSResponder` backend (see the mDNS note
above) and never pushed to a registry, so it exists only on the node that built
it. A newly flagged node has no such image and its OTBR pod will not start until
the image is built there too.

A few smaller details that follow from the same design:

- **Local BLE needs Bluetooth on the new host.** In `local` mode the Matter server
  drives a Bluetooth adapter on the radio host directly, so a newly flagged node
  must have one; a node without Bluetooth can only commission via `proxy` mode.
  The link-local, forwarding sysctls, D-Bus policy, and AppArmor profile all
  follow the `thread_radio_host` flag automatically — but the radio hardware does
  not, and neither does a reboot to confirm the boot-hang fix on the new host.
- **Home Assistant's `trusted_proxies`.** An initContainer seeds
  `configuration.yaml` on first boot with `trusted_proxies` set to the pod
  network CIDR, so requests forwarded by the Traefik gateway are accepted rather
  than rejected as coming from an untrusted proxy. Without it Home Assistant
  refuses proxied logins.
- **Device resources are named by the plugin, not by Kubernetes.** The
  generic-device-plugin advertises the radio and TUN device under its own
  vendor-prefixed resource names, which the OTBR pod requests by exactly those
  names. Renaming one side silently leaves the pod unschedulable, since an
  unmatched resource request just never gets satisfied.
