# Architecture

VPS Guard uses a small Bash core and independently routed built-in modules.

## Layers

1. `bin/vpsg` — CLI UX, safe-routing policy and interactive menu.
2. `core/common.sh` — state directories, logs, confirmation and generic backups.
3. `core/platform.sh` — Debian/Ubuntu and SSH endpoint discovery.
4. `core/router.sh` — module discovery and dispatch.
5. `core/transaction.sh` — transaction snapshots, rollback scripts, timer arming, commit and manual rollback.
6. `core/inspect.sh` — normalized read-only observations used by Exposure and Baseline/Drift.
7. `modules/builtin/*` — feature implementations.

## High-risk command routing

`vpsg ssh apply` and `vpsg firewall apply` do not directly route to the module. The CLI first calls the Safe Change Engine, which snapshots state and arms the rollback timer. Only then is the module `apply` action dispatched.

This keeps the safety policy above individual modules and makes accidental direct unsafe use less likely through the supported CLI.

## Transaction state

Transactions live under:

```text
/var/lib/vps-guard/transactions/<id>/
```

Each transaction contains a restrictive-permission state file, a subsystem snapshot, a self-contained rollback script and a log. A corresponding one-shot systemd service/timer is created in `/etc/systemd/system` until the transaction is committed or manually rolled back.

## Inspection state

`core/inspect.sh` converts host state into stable TSV/text sections. Baselines store normalized observations, not a filesystem image. This makes drift reports understandable and reduces unnecessary collection of sensitive contents.
