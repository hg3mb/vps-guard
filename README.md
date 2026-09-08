# VPS Guard

A safety-first, beginner-friendly VPS hardening and operations toolkit for Debian and Ubuntu.

VPS Guard is built around three questions traditional one-click scripts often leave unanswered:

1. **What if an SSH/firewall change locks me out?**
2. **What is actually exposed on this server, including Docker-published ports?**
3. **What changed after I last confirmed the server was in a trusted state?**

Current release: **v0.3.0**

> VPS Guard is early-stage software. Keep provider console/rescue access available when changing remote access controls.

## Core differentiators

### Safe Change Engine 2.0

Risky SSH/UFW changes are transactional. VPS Guard performs pre-checks, snapshots state, arms a persistent systemd rollback timer, applies the change, verifies it, and refuses to make it permanent until the administrator commits it.

```bash
sudo vpsg ssh apply --yes
sudo vpsg firewall apply --yes
vpsg safe status
sudo vpsg commit
vpsg safe history
```

If access is lost and no commit happens, the server restores the previous configuration automatically. Transaction history, event logs, post-apply validation and commit-time verification are included.

### Exposure Analyzer 2.0

```bash
vpsg exposure scan
vpsg exposure explain 6379
vpsg exposure json
```

It correlates listeners, bind scope, UFW, Docker-published ports and common service types, then assigns explainable risk levels and recommendations. It distinguishes host-level exposure indicators from proven Internet reachability because cloud security groups, NAT and upstream firewalls remain outside the host.

### Baseline & Drift 2.0

```bash
sudo vpsg baseline create
sudo vpsg drift scan
vpsg drift history
```

Tracks listeners, Docker ports/containers, users, sudo access, authorized-key hashes/counts, SSH policy, firewall state, enabled services, cron and selected sysctls. Drift output explains why each changed area matters and stores local audit reports.

## Practical VPS management

```text
SSH / GitHub SSH key import     ✓
UFW firewall management         ✓
Fail2Ban                        ✓
User and sudo management        ✓
Docker / Compose                ✓
1Panel integration              ✓
BBR / Swap                      ✓
Network speed / route tools     ✓
Media reachability probes       ✓
Risk-aware APT upgrade plan     ✓
Daily security Watch            ✓
Read-only incident collection   ✓
```

Start the beginner menu with:

```bash
vpsg
```

## Examples

```bash
# Dashboard and security checks
vpsg status
vpsg doctor
vpsg exposure scan

# Safer SSH hardening
sudo vpsg ssh apply --disable-password --root-key-only --yes
vpsg safe status
sudo vpsg commit

# Users and GitHub keys
sudo vpsg users add deploy --sudo
sudo vpsg ssh import-github octocat --user deploy

# Firewall / Fail2Ban
sudo vpsg firewall apply --yes
sudo vpsg firewall web
sudo vpsg fail2ban apply --yes

# Docker / 1Panel
sudo vpsg docker apply --yes
vpsg docker ports
sudo vpsg panel install

# Network tools
vpsg network summary
vpsg network speed 25
vpsg network route 1.1.1.1
vpsg network media

# Continuous local checks
sudo vpsg baseline create
sudo vpsg watch enable
```

## Install

Download a release, inspect/verify it, extract it, then:

```bash
sudo bash install.sh
vpsg --version
vpsg doctor
```

The installer intentionally works even if executable mode bits were lost by a ZIP download or web upload. The runtime router also invokes built-in modules through Bash rather than relying on source-tree executable bits.

## Supported systems

- Debian 12/13
- Ubuntu 22.04/24.04
- systemd

## Security principles

- preserve current SSH access before firewall enforcement;
- use automatic rollback for access-critical changes;
- validate before and after high-risk changes;
- avoid `curl | bash` for the built-in 1Panel workflow;
- do not store SSH private keys or copy authorized-key contents into baselines;
- separate host-level exposure indicators from provider-level reachability;
- keep Watch and incident data local by default.

See [docs/security-model.md](docs/security-model.md).

## Development

```bash
bash tests/run.sh
shellcheck -x -S error bin/vpsg core/*.sh modules/builtin/*/module.sh install.sh uninstall.sh
```

See [docs/feature-matrix.md](docs/feature-matrix.md), [docs/roadmap.md](docs/roadmap.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Chinese documentation

[README.zh-CN.md](README.zh-CN.md)

## License

MIT
