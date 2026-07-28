# When systemd, NFS, and Kubernetes Fight

This is the messiest corner of the cluster. Three subsystems — **systemd unit
ordering**, **NFS**, and **Kubernetes storage (kubelet + Longhorn/iSCSI)** — each
assume they own the boot, shutdown, and mount lifecycle. Individually each is
fine. Combined, they deadlock one another in ways that are hard to diagnose:
silent boot cycles, unkillable processes, journal corruption, and shutdowns that
hang until a timeout fires.

This document exists to make that complexity legible: what the tension is, the
concrete blockers we hit, the recurring shapes behind them, and the symptoms to
watch for. The fixes live in `infrastructure/nfs.yml`, `cluster/storage.yml`,
`cluster/kubernetes.yml` (paths relative to `playbooks/nodes/`), and the two
lifecycle scripts (`k8s-node-lifecycle.sh`, `k8s-suspend-hook.sh`). Several
guards in those files are marked **LOAD-BEARING** — this doc explains why.

Why both storage paths exist on the same host in the first place is covered in
[architecture.md](architecture.md).

## The core tension

Each subsystem has a reasonable-in-isolation assumption that becomes false once
the others are present:

- **systemd** resolves ordering *cycles* by **silently deleting jobs** from the
  transaction. It doesn't fail loudly — it drops whatever unit closes the loop,
  which is often the exact thing you needed (the NFS server, `iscsid.socket`,
  even `systemd-networkd`).
- **NFS** is network storage that systemd's generators still tend to treat like
  a local disk (`local-fs.target`), and whose clients block in **uninterruptible
  D-state** when the server is unreachable — a state that cannot be killed, even
  with SIGKILL.
- **Kubernetes / Longhorn** layers a *second* storage system (iSCSI block
  volumes served by on-node pods) on top of the same host. Its volumes are ext4
  filesystems on network targets, so tearing the target down out from under a
  writer corrupts the journal — and the writer is itself a pod that has to be
  stopped in the right order.

Two distinct storage paths coexist on every node, and both entangle with systemd
and kubelet:

| Path | What it is | Fails when… |
|------|-----------|-------------|
| **NFS** | An external NFS server mounted at a host path, also used for some ReadWriteMany PVs | The server is unreachable at boot → kubelet/mount hang in D-state |
| **Longhorn / iSCSI** | Replicated block volumes served by on-node Longhorn engine pods over iSCSI on loopback | The iSCSI target dies while ext4 is still mounted → journal abort, unkillable umount |

## Blockers we hit

### 1. systemd boot-ordering cycles caused by NFS in fstab

Putting the NFS mount in `/etc/fstab` with `x-systemd.automount` looks correct
but triggers the `fstab-generator`, which mis-places the automount in
`local-fs.target`. That single mistake spawns three different cycles:

- **Server node:** `nfs-server` → `nfs-mountd` → `local-fs.target` → the
  automount → (needs `nfs-server`). systemd breaks it by **dropping
  `nfs-mountd`**, so the NFS server never starts.
- **Client node:** an `After=network-online.target` drop-in contradicts the
  implicit `Before=local-fs.target` (from `DefaultDependencies=yes`). systemd
  breaks it by **dropping shared socket units — including `iscsid.socket`**, so
  Longhorn volumes can't attach. (NFS breaks Longhorn, on an unrelated node.)
- **Any node:** the automount synthesizes an edge to `lvm2-monitor`, which
  transitively reaches `systemd-networkd`, forming another cycle. systemd
  "resolves" it by deleting jobs — often `systemd-networkd.service` itself —
  producing **flaky boots** where networking only comes up via socket
  activation.

**Fix:** don't use fstab. Ship **explicit `.mount` + `.automount` unit files**
with `DefaultDependencies=no` and `WantedBy=remote-fs.target`, which keeps the
fstab-generator out of it entirely. The automount deliberately carries *no*
`After=network-online.target` (adding it re-opens the `lvm2-monitor` → networkd
cycle); network readiness is gated on the `.mount` unit instead. (Upstream
systemd bugs #17657 and #34164, unfixed as of 2026.)

Also masked: **`nfs-blkmap`**, which waits forever at boot for a pNFS session
that never exists under automount.

### 2. kubelet hanging on NFS at boot

kubelet re-mounts previously-active NFS PersistentVolumes directly at startup. If
the NFS server is unreachable then, kubelet enters **uninterruptible D-state** and
the node never finishes booting.

**Fix:** a kubelet drop-in orders it `After=` the NFS mount unit with **`Wants=`,
not `Requires=`** — so a missing server delays but doesn't block. The mount is
`soft` with a 15 s `TimeoutSec`; if the server is down, kubelet starts *without*
the NFS PVs and the automount retries on next access once the server returns.
`Requires=` here would convert a slow NFS server into a failed boot.

### 3. Longhorn/iSCSI vs the host's own iSCSI and multipath stack

Longhorn manages its iSCSI sessions itself, but the host's stock services want to
manage them too:

- **`iscsid` auto-reconnect race:** with the default `node.startup=automatic`,
  `iscsid` reconnects to Longhorn targets on boot/resume *before* the Longhorn
  engine for that volume is back. The kernel sees a dead target for the fresh
  `/dev/sdX` and **aborts the ext4 filesystem** ("shut down requested (2)",
  "device offline"). Fixed by a oneshot (`Before=iscsid.service`) that rewrites
  **Longhorn-owned** node records to `node.startup=manual` (scoped to the
  Longhorn IQN so real NAS/backup targets keep auto-login).
- **`multipathd` grabbing the device:** iSCSI volumes surface as `/dev/sd*`, and
  `multipathd` claims them before Longhorn can map them — again worst after
  resume. Fixed by blacklisting `sd*` in `multipath.conf`.

### 4. Tearing down iSCSI storage at shutdown/suspend (the dangerous part)

This is where the subtle, data-losing deadlocks live. The whole ordering in
`k8s-node-lifecycle.sh` and `k8s-suspend-hook.sh` exists to avoid them:

- **The unkillable umount (LOAD-BEARING guard).** An ext4 `umount` must flush the
  journal to its block device. If the iSCSI target is *already dead*, that umount
  blocks in **D-state and cannot be killed even by SIGKILL** — hanging the entire
  shutdown until `TimeoutStopSec` (~99 s), which then tears everything down
  abruptly and corrupts the journal anyway. Both scripts therefore **probe iSCSI
  reachability before ever calling umount**, and skip it if the session is
  already gone (the data was unreachable regardless). *Never remove this guard.*
- **Longhorn engine outliving its writers.** A workload pod's ext4 journal is
  served by an on-node Longhorn engine pod over loopback iSCSI. If the engine
  stops before the workload finishes flushing, you get "Aborting journal" /
  "potential data loss". Fixed with a **two-phase container stop**: workload
  containers first (while their iSCSI target is live), *then* sync, *then* logout,
  *then* the Longhorn/kube-system containers.
- **Drain-after-taint deadlock.** On graceful shutdown we **cordon and drain
  workload pods first**, and only *then* apply the NoExecute taint that evicts
  Longhorn's DaemonSet. Reversing it deadlocks: workload pods are stuck
  Terminating because Longhorn was evicted before they could unmount.
- **Suspend keeps bouncing awake (LOAD-BEARING).** On this hardware only fragile
  `s2idle` is available (no S3). Leaving docker/`iscsid`/system containers running
  across suspend makes background chatter bounce the machine out of sleep within
  seconds. The aggressive full teardown is the only thing that lets sleep hold —
  which is also *why* the production nightly cycle uses **full shutdown + Wake-on-LAN
  cold boot** instead of suspend.

### 5. The systemd oneshot ExecStop trap

The graceful-shutdown service is `Type=oneshot` with the drain logic in
`ExecStop`. systemd only runs `ExecStop` **after `ExecStart` has completed**. The
startup path uncordons the node, which retries until the API server is reachable —
if that ran in the foreground and you shut down mid-retry, `ExecStart` never
finishes, so **`ExecStop` (the drain) never fires**. Fix: `ExecStart` **forks its
boot tasks into the background** and returns in under a second, keeping `ExecStop`
always eligible.

## The recurring shapes

Almost every blocker above is one of four patterns. Recognizing the shape is
faster than re-deriving each case:

1. **Silent cycle resolution.** systemd doesn't reject an ordering loop — it
   deletes a job to break it, often the one you depended on. *Symptom:* a unit
   you configured simply isn't running, with no error. *Defense:*
   `DefaultDependencies=no` and explicit targets to avoid generator-induced
   edges.
2. **Uninterruptible D-state on dead network storage.** Any I/O (mount, umount,
   sync, `ls`) against an unreachable NFS/iSCSI endpoint can hang unkillably and
   stall whatever holds it. *Defense:* probe reachability *before* touching the
   storage; use `soft` mounts and timeouts everywhere.
3. **Two managers, one resource.** `iscsid` vs Longhorn, `multipathd` vs
   Longhorn — two things racing to own the same block device/session. *Defense:*
   scope one out (`node.startup=manual` for Longhorn IQNs, blacklist `sd*`).
4. **Circular teardown.** The writer depends on the very storage/service being
   torn down (workload → Longhorn engine → iSCSI target). *Defense:* explicit
   phase ordering so the dependency outlives its dependents.

## What to look out for

Symptoms and their likely cause:

| Symptom (dmesg / behavior) | Likely cause |
|----------------------------|--------------|
| `EXT4-fs ... Aborting journal`, `shut down requested (2)`, "potential data loss" after boot/resume | iSCSI target torn down under a live ext4 mount — teardown ordering or `iscsid` reconnect race |
| Node hangs at shutdown, then units SIGKILL'd ~99 s later | umount on a dead iSCSI target in D-state; reachability guard missing/bypassed |
| kubelet stuck, node never finishes booting | NFS server unreachable and kubelet ordered `Requires=` (not `Wants=`) or mount not `soft` |
| `nfs-server` won't start, `nfs-mountd` missing | fstab automount cycle dropped `nfs-mountd` |
| Longhorn volumes won't attach; `iscsid.socket` absent | client-node fstab/network-online cycle dropped `iscsid.socket` |
| Flaky boots, `systemd-networkd` only up via socket activation | automount → `lvm2-monitor` → networkd cycle |
| Boot hangs on `nfs-blkmap` | pNFS blkmap waiting for a session that never exists under automount |
| Suspend enters then exits within seconds, no wake event | docker/iscsid/system containers left running across `s2idle` |

**Rules of thumb when working in this area:**

- Treat every **LOAD-BEARING** comment as a scar from a real incident — don't
  "simplify" the teardown ordering or drop the reachability guards.
- Never assume a systemd ordering change is safe because it "should" work — check
  for an induced cycle (`systemd-analyze verify`, and look for jobs being
  deleted).
- Prefer `Wants=`/`soft`/timeouts over `Requires=`/hard mounts anywhere network
  storage is involved, so a dead endpoint degrades instead of deadlocks.
- The suspend path is kept for manual testing only; the **nightly production
  path is full shutdown + WoL**, because it sidesteps most resume-time races
  entirely.
