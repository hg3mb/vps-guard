# Roadmap

The roadmap prioritizes **trustworthiness and operator clarity** over feature count.

## v0.4.x — real-world validation and polish

- Debian 12/13 and Ubuntu 22.04/24.04 provider/VPS compatibility reports
- resolve remaining non-blocking ShellCheck findings instead of suppressing them globally
- nftables-aware firewall context without pretending arbitrary rulesets are fully understood
- richer Docker Compose project/service attribution
- expand Safe Change failure injection from state-sync/timer/systemd ownership coverage to real disk-full, power-loss and service-reload laboratory tests
- doctor remediation text and machine-readable output
- documented recovery drills for SSH/UFW rollback

## v0.5 — notifications and policy

- built-in generic webhook adapter with secret-safe configuration
- optional Telegram/email adapters
- per-profile expected-exposure policy and user-defined allowed services
- maintenance windows and approved Drift exclusions with audit history
- reboot-aware upgrade workflow
- explicit baseline rotation and retention policy

## v0.6 — deeper diagnostics

- optional provider/cloud firewall connectors where credentials are explicitly configured
- route/ASN diagnostics
- incident redaction profiles
- signed release/checksum workflow
- optional machine-readable reports suitable for external monitoring

## Longer term

- plugin API for narrowly scoped third-party integrations
- fleet/federated view only after the single-host state and transaction model is proven stable
- packaging for common distributions if it can preserve rollback and upgrade guarantees

## Non-goals

VPS Guard will not become a menu of opaque root-level `curl | bash` shortcuts. It will not claim Internet reachability from host state alone, silently weaken SSH to make an operation succeed, or invent a security score whose meaning cannot be explained.
