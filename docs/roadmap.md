# Roadmap

## 0.2.x — harden the three core differentiators

- Safe Change integration tests on Debian/Ubuntu VMs
- nftables-aware exposure correlation
- systemd timer cleanup and transaction history command
- richer Docker Compose port attribution
- baseline exclusions and user-defined policy profiles

## 0.3 — policy-aware operations

- `vpsg profile web|docker|database|proxy`
- expected-port allowlist and drift policy
- risk-aware APT upgrade planning
- reboot-required and post-upgrade service verification

## 0.4 — incident collection

- read-only incident bundle
- failed-login, process, socket, cron and service evidence
- redaction modes
- SHA-256 manifest

The project intentionally prioritizes safety and explainability over adding large numbers of one-click installers.
