# Architecture

VPS Guard is a Bash-first modular VPS operations tool.

## Layers

- `bin/vpsg` — CLI, dashboard and beginner menu.
- `core/common.sh` — logging, confirmation, backups and runtime paths.
- `core/platform.sh` — Debian/Ubuntu and SSH-port discovery.
- `core/router.sh` — module discovery; invokes modules through Bash so ZIP/web uploads do not depend on executable bits.
- `core/transaction.sh` — Safe Change transactions, timers, verification, commit/rollback and history.
- `core/inspect.sh` — normalized read-only host inspection used by Exposure/Baseline/Drift.
- `modules/builtin/*` — independent operational modules.

## High-risk path

SSH and initial UFW enforcement are routed through Safe Change by default:

```text
precheck -> snapshot -> schedule rollback -> apply -> verify -> pending -> commit/automatic rollback
```

Only one pending access-critical transaction is allowed at a time.

## Read-only security path

```text
inspect primitives
   ├── Exposure Analyzer -> risk/reason/recommendation
   ├── Baseline -> trusted snapshot
   ├── Drift -> comparison + persistent report
   ├── Watch -> scheduled Exposure + Drift
   └── Incident -> evidence bundle
```

## Trust boundaries

The project distinguishes built-in code from external tools. For example, 1Panel is not vendored or silently executed: VPS Guard downloads the current official installer to a temporary file, rejects obvious HTML/error pages, displays a SHA-256 and preview, then asks for a second confirmation.
