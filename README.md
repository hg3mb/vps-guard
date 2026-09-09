# VPS Guard

[![CI](https://github.com/hg3mb/vps-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/hg3mb/vps-guard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/hg3mb/vps-guard)](https://github.com/hg3mb/vps-guard/releases/latest)
[![License](https://img.shields.io/github/license/hg3mb/vps-guard)](LICENSE)


**Safety-first VPS hardening and operations for Debian and Ubuntu.**

VPS Guard is designed for people who want a VPS toolbox that is easy to use **without turning security-critical changes into blind one-click actions**.

It focuses on four questions:

1. **What if an SSH/firewall change locks me out?**
2. **What is actually exposed, including Docker-published ports?**
3. **What changed after I last trusted this server?**
4. **Did a check find nothing, or was the check incomplete?**

Current release: **v0.4.0** · [Repository](https://github.com/hg3mb/vps-guard) · [Latest release](https://github.com/hg3mb/vps-guard/releases/latest)

> VPS Guard is still an early-stage project. Keep provider console/rescue access available when changing remote-access controls.

## Why VPS Guard

Traditional VPS scripts are good at *doing things*. VPS Guard also tries to make risky changes reversible, security findings explainable, and later changes auditable.

### Safe Change Engine 3.0

SSH and access-critical UFW changes use a transaction rather than a fire-and-forget script:

```text
precheck
  -> snapshot
  -> arm persistent rollback
  -> apply
  -> verify
  -> reconnect / console confirmation
  -> commit

No commit before timeout -> automatic rollback
```

```bash
sudo vpsg ssh apply --disable-password --yes
vpsg safe status
sudo vpsg commit
vpsg safe history
```

Key properties:

- one active access-critical transaction at a time;
- root-owned transaction state and history;
- persistent systemd rollback independent of the initiating SSH shell;
- SSH syntax **and effective-policy** verification;
- commit rejects the same SSH login session unless console confirmation is explicitly used;
- manual rollback and deadline extension;
- unresolved failure states continue blocking new risky changes.

### Exposure Analyzer 3.0

```bash
sudo vpsg exposure scan
vpsg exposure explain 6379
vpsg exposure profile set web
vpsg exposure json
```

Exposure Analyzer combines:

- Linux TCP/UDP listeners;
- bind scope (`loopback`, private/CGNAT, specific public address, wildcard);
- Docker published ports from structured Docker metadata;
- UFW context;
- common service types and container ports;
- server profile expectations.

It reports explainable `CRITICAL/HIGH/MEDIUM/LOW/INFO` findings instead of a magic security score.

If Docker is installed but the current user cannot inspect the daemon, VPS Guard marks the scan **incomplete** rather than claiming no Docker exposure exists.

### Baseline & Semantic Drift 3.0

```bash
sudo vpsg baseline create
sudo vpsg baseline verify
sudo vpsg drift scan
vpsg drift history
sudo vpsg drift accept <report-id>
```

The baseline tracks security-relevant state such as listeners, Docker publications, users, sudo access, authorized-key hashes/counts, SSH effective policy, firewall state, enabled services, cron metadata and selected sysctls.

Drift turns changes into operator-oriented events, for example:

```text
CRITICAL  + Docker API published publicly
HIGH      + authorized_keys changed
HIGH      + sudo access changed
MEDIUM    + new login-capable user
MEDIUM    + inspection coverage became incomplete
INFO      - a previous listener disappeared
```

Snapshot integrity covers both file contents and the expected file set. Collector failures are recorded explicitly, so “not found” is not confused with “not inspected.”

## Beginner workflow

Start with:

```bash
vpsg
```

or:

```bash
vpsg setup guide
```

Recommended order:

```text
Doctor / Exposure
  -> choose server profile
  -> create a second admin + SSH key
  -> Fail2Ban + automatic security updates
  -> Safe Change SSH/UFW
  -> create Baseline
  -> enable Watch
```

There is intentionally no “press Enter to rewrite the whole server” mode.

## Practical VPS toolbox

| Area | Commands / behavior |
| --- | --- |
| System health | `vpsg status`, `vpsg doctor` |
| SSH | hardening, port-aware migration, GitHub key import |
| Firewall | UFW status/apply/allow/deny/web helpers with SSH-port protection |
| Fail2Ban | isolated jail fragment, status, banned IPs, unban, logs |
| Users | users/sudo state, bootstrap admin flow, lock/unlock/delete protections |
| Docker | Docker CE install, containers, published ports, docker-group warning |
| 1Panel | checked official installer staging instead of blind pipe-to-shell |
| Updates | APT simulation, kernel/OpenSSH/Docker risk hints, unattended-upgrades |
| Network | public IP/DNS, speed, route, media reachability |
| Optional diagnostics | checked YABS / RegionRestrictionCheck integration |
| Kernel / memory | BBR, managed swap |
| Watch | scheduled local Exposure + Drift with optional secure hook |
| Incident response | privacy-aware read-only evidence bundle + SHA256 manifest |

## Examples

```bash
# Read-only first
vpsg doctor
sudo vpsg exposure scan

# Create a second administrator from GitHub keys
sudo vpsg users bootstrap deploy octocat

# Safer SSH hardening
sudo vpsg ssh apply --disable-password --yes
# Open a NEW SSH login, then:
sudo vpsg commit

# Baseline and later drift
sudo vpsg baseline create
sudo vpsg drift scan

# Daily local monitoring
sudo vpsg watch enable
vpsg watch status
```

## Install

### From a release archive

Download the [latest GitHub Release](https://github.com/hg3mb/vps-guard/releases/latest), optionally verify it with the published `SHA256SUMS`, extract it, then:

```bash
cd vps-guard-0.4.0
sudo bash install.sh
vpsg --version
vpsg doctor
```

### From Git

```bash
git clone https://github.com/hg3mb/vps-guard.git
cd vps-guard
sudo bash install.sh
vpsg doctor
```

Using `bash install.sh` is intentional: ZIP downloads and browser uploads may lose Unix executable mode bits.

Upgrade uses the same installer. The previous **program version** can be restored with:

```bash
sudo bash install.sh --rollback
```

Program rollback is deliberately separate from SSH/UFW Safe Change rollback.

## Supported systems

CI regression targets:

- Debian 12
- Debian 13
- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- systemd-based VPS environments

Real-provider compatibility still depends on networking, images and provider customizations; reports are welcome.

## Security principles

- preserve a known management path before access-control enforcement;
- make dangerous remote-access changes reversible by default;
- verify **effective state**, not only generated config files;
- never treat incomplete visibility as a clean result;
- keep Docker publication separate from simplistic UFW assumptions;
- avoid storing SSH private keys or authorized-key contents in baselines;
- stage and inspect external scripts instead of silently piping them into a root shell;
- keep Watch and incident data local unless the operator explicitly configures an output.

See [Security model](docs/security-model.md) and [SECURITY.md](SECURITY.md).

## Tests and release engineering

```bash
bash tests/run.sh
bash scripts/build-release.sh ./dist --self-test
```

The current regression suite contains **114 tests**. CI additionally runs a Debian/Ubuntu matrix, ShellCheck, and release-archive self-tests.

## Documentation

- [Architecture](docs/architecture.md)
- [Security model](docs/security-model.md)
- [Feature matrix](docs/feature-matrix.md)
- [Roadmap](docs/roadmap.md)
- [Contributing](CONTRIBUTING.md)
- [中文说明](README.zh-CN.md)

## Scope / limitations

VPS Guard does not replace provider security groups, backups, rescue consoles, IDS/EDR, or a full proof of arbitrary nftables/iptables policy. Host exposure is not the same thing as proven Internet reachability.

## License

MIT. Third-party tools remain under their own upstream licenses and are not vendored into the VPS Guard MIT source tree.
