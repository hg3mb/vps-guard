# VPS Guard

Safety-first VPS hardening and operations toolkit for Debian and Ubuntu.

VPS Guard is built around a simple idea: **a security tool should not lock you out of the server it is trying to protect**. Instead of only providing one-click setup actions, it adds transactional rollback, real exposure analysis, and configuration drift detection.

> Current version: **0.2.0**. Test on a VPS with a provider console/snapshot before production use.

## Why VPS Guard

Traditional VPS scripts are good at changing configuration. VPS Guard focuses on what happens **before and after** those changes:

- **Safe Change Engine** — SSH and UFW changes automatically create a rollback transaction. If you lose access and do not confirm the change, a persistent systemd timer restores the previous state.
- **Exposure Analyzer** — shows listening sockets, bind scope, UFW status, owning processes, and Docker-published ports in one view.
- **Baseline & Drift** — records a trusted security baseline and later detects changes to ports, SSH keys, sudo access, firewall state, services, containers, cron jobs, SSH policy, and selected sysctls.
- Modular SSH, UFW, Fail2Ban, BBR, Swap, Docker and system-management modules.

## Safe Change Engine

Normal SSH/UFW `apply` commands are protected automatically:

```bash
sudo vpsg ssh apply --yes
sudo vpsg firewall apply --yes
```

VPS Guard will:

1. snapshot the relevant configuration;
2. create a rollback transaction;
3. arm a persistent systemd rollback timer;
4. apply and verify the change;
5. wait for you to confirm from a second SSH session.

Example:

```text
Safe Change started: rollback in 180 seconds unless committed.
Transaction: 20260908-142530-a12f

Open a new SSH session and verify access.
Then run:
  sudo vpsg commit 20260908-142530-a12f
```

Useful commands:

```bash
vpsg safe status
sudo vpsg commit
sudo vpsg safe rollback

# Custom rollback window, 30–1800 seconds
sudo vpsg safe firewall apply --timeout 300 --yes
```

The rollback timer uses an absolute systemd calendar deadline with `Persistent=true`, so the safety action is independent of the SSH shell that started it and can still fire after a reboot if the deadline was missed.

## Exposure Analyzer

```bash
vpsg exposure scan
vpsg exposure explain 3306
vpsg exposure json
```

Example output:

```text
PORT    PROTO BIND                   SCOPE      FIREWALL      CLASS        OWNER / DOCKER
22      tcp   0.0.0.0                wildcard   allow         NET-FACING   sshd
443     tcp   0.0.0.0                wildcard   allow         DOCKER-PUB   docker-proxy | proxy@0.0.0.0->443/tcp
5432    tcp   127.0.0.1              loopback   default       LOCAL        postgres
```

`NET-FACING` and `DOCKER-PUB` mean the service is bound to an externally reachable interface. VPS Guard deliberately does **not** claim that a port is definitely reachable from the public Internet because provider security groups, upstream firewalls, NAT, nftables and routing can still block it.

## Baseline & Drift

Create a trusted baseline after you finish configuring the server:

```bash
sudo vpsg baseline create
```

Later:

```bash
sudo vpsg drift scan
```

Tracked areas include:

- listening TCP/UDP sockets;
- Docker published ports and running container state;
- root and normal login-capable users;
- sudo-group membership and sudoers file hashes;
- `authorized_keys` file hashes and key counts (keys themselves are not copied into the baseline);
- effective SSH security settings;
- UFW/nftables firewall state;
- enabled systemd services;
- cron file hashes;
- selected network/security sysctls.

After reviewing a legitimate change, accept the current state as the new baseline:

```bash
sudo vpsg baseline create default --force
```

For CI/monitoring integration, `--strict` returns exit code `3` when drift is detected:

```bash
sudo vpsg drift scan default --strict
```

## Other modules

```bash
vpsg status
vpsg doctor
vpsg module list

vpsg ssh plan
vpsg firewall plan
sudo vpsg fail2ban apply --yes
sudo vpsg bbr apply --yes
sudo vpsg swap apply --yes
sudo vpsg docker apply --yes
```

## Supported systems

- Debian 12/13
- Ubuntu 22.04/24.04
- systemd
- root or sudo for operations that need privileged state

## Install

From a checked-out release/source tree:

```bash
sudo ./install.sh
vpsg --version
vpsg doctor
```

VPS Guard intentionally does not require a `curl | bash` installation path. Download a release, verify its checksum, then install it locally.

## Project layout

```text
bin/vpsg                     CLI and interactive menu
core/common.sh               logging, confirmation, backups
core/platform.sh             OS and SSH port detection
core/router.sh               module discovery and routing
core/transaction.sh          Safe Change transaction engine
core/inspect.sh              normalized host inspection primitives
modules/builtin/exposure/    Exposure Analyzer
modules/builtin/baseline/    trusted snapshot creation
modules/builtin/drift/       baseline comparison and risk reporting
modules/builtin/ssh/         SSH hardening
modules/builtin/firewall/    UFW hardening
modules/builtin/*            other built-in modules
tests/run.sh                 smoke and regression tests
docs/                        architecture and security model
```

## Security model

Read [docs/security-model.md](docs/security-model.md) before relying on VPS Guard for production access controls. Important design rules include:

- preserve current SSH access before enforcing firewall changes;
- make risky changes transactional;
- verify configuration before service reload;
- store project state with restrictive permissions;
- do not store SSH private keys or copy authorized-key contents into baselines;
- report uncertainty instead of claiming provider-level public reachability.

## Development

```bash
./tests/run.sh
shellcheck -x bin/vpsg core/*.sh modules/builtin/*/module.sh install.sh uninstall.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/architecture.md](docs/architecture.md).

## Roadmap

See [docs/roadmap.md](docs/roadmap.md).

## Chinese documentation

See [README.zh-CN.md](README.zh-CN.md).

## License

MIT
