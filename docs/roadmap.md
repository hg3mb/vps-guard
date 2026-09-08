# Roadmap

## v0.3.x — reliability and usability

- Real VPS compatibility fixes from Debian 12/13 and Ubuntu 22.04/24.04 reports
- ShellCheck warning cleanup without hiding blocking errors
- nftables-aware exposure correlation
- richer Docker Compose service attribution
- more integration tests for Safe Change timer lifecycle
- installer update/rollback command

## v0.4 — policy and notifications

- `vpsg profile web|docker|database|proxy|minimal`
- expected public-port policy and reduced false positives
- Watch notification adapters: generic webhook first, then optional email/Telegram
- maintenance windows and baseline exclusions
- explicit reboot-safe upgrade workflow

## v0.5 — deeper diagnostics

- provider/cloud firewall connectors where credentials are explicitly configured
- richer route/ASN diagnostics
- optional third-party benchmark adapters with pinned source/version display
- incident bundle redaction modes
- signed release/checksum workflow

## Non-goals

VPS Guard will not maximize feature count by silently piping arbitrary Internet scripts into root shells. Convenience features should preserve inspectability, rollback where practical, and clear trust boundaries.
