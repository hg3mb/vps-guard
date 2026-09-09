# Architecture

VPS Guard is a Bash-first, single-host VPS operations tool built around a small set of shared safety primitives.

## Layers

- `bin/vpsg` — CLI, dashboard, doctor and beginner menu.
- `core/common.sh` — runtime paths, logging, confirmation, atomic/safe filesystem helpers.
- `core/platform.sh` — Debian/Ubuntu and SSH management-port discovery.
- `core/router.sh` — validated module discovery and Bash-based invocation.
- `core/inspect.sh` — normalized read-only host inspection shared by Exposure/Baseline/Drift.
- `core/transaction.sh` — Safe Change state machine, locks, rollback timers, verification and history.
- `modules/builtin/*` — operational modules with narrow ownership of their configuration/state.
- `tests/*` — regression, security-property and installer lifecycle tests.

## Safe Change state machine

Access-critical SSH and initial firewall changes use one fail-closed transaction model:

```text
precheck
  -> durable preparing record
  -> snapshot
  -> rollback program + current cache
  -> persistent rollback timer armed
  -> apply
  -> post-apply verification
  -> pending
     -> commit verification (new SSH login or explicit provider console)
        -> commit_pending
        -> verify rollback timer is actually cancelled
        -> committed
     -> manual rollback
     -> automatic rollback on timeout
```

`transactions/*/state` records are the source of truth. `transactions/current` is only a convenience pointer: if it disappears, an orphan active transaction is rediscovered; if multiple active records exist, VPS Guard fails closed instead of guessing.

Safety-critical state writes use atomic rename plus a persistence barrier (`sync -f`). A pre-apply failure becomes terminal `prepare_failed`; `apply_failed`, `commit_pending`, `rolling_back` and `rollback_failed` remain active/fail-closed states. Commit uses two phases so rollback remains valid until timer cancellation has been verified; if the final durable `committed` seal fails, the previous active phase is restored and rollback is re-armed when possible. Same-name systemd rollback units are modified only when ownership markers match the exact transaction.

Only one access-critical transaction may be active. Transaction IDs are validated before use as filesystem or systemd identifiers. Program-version rollback (`install.sh --rollback`) is deliberately separate from Safe Change configuration rollback.

## Inspection pipeline

Read-only security features share canonical inspection data instead of each parsing the host independently:

```text
Linux listeners ─┐
Docker publishes ├─> normalized exposure records ─> Exposure Analyzer
UFW context      ┤                                  ├> Baseline snapshot
SSH/users/etc.   ┘                                  ├> semantic Drift
                                                     └> Watch / Doctor
```

Docker publication is a first-class source, not inferred only from `docker-proxy` processes. If Docker exists but the caller cannot query the daemon, the scan records that visibility is incomplete.

## Baseline model

A baseline stores normalized security state plus collection metadata. Integrity covers both:

1. the contents of expected snapshot files; and
2. the expected file set itself.

This prevents a successful checksum verification from being confused with a complete scan. Collector failures are recorded as `incomplete(...)` and surfaced by Drift/Doctor.

## External-tool boundary

YABS, RegionRestrictionCheck and 1Panel are integrations, not vendored components. The built-in workflow uses HTTPS-only redirects, stages the remote script, rejects obvious HTML/error responses, validates Bash syntax where applicable, displays source/checksum/preview, requires explicit confirmation, and executes downloaded code with an intentionally minimal environment so unrelated shell secrets are not inherited. Different upstream licenses remain outside the VPS Guard MIT source tree.

## Persistence

Default runtime ownership:

- `/var/lib/vps-guard` — root-owned state, transactions, baselines and reports
- `/etc/vps-guard` — user policy/profile configuration
- `/var/log/vps-guard` — local logs
- `/usr/lib/vps-guard` + `/usr/local/bin/vpsg` — installed program and command entrypoint

Deletion and install destinations pass lexical path normalization, dangerous-root guards and existing-ancestor symlink checks before destructive operations.
