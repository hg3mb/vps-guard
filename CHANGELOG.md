# Changelog

## 0.2.0

### Added

- Safe Change Engine for SSH and UFW with automatic rollback deadlines
- persistent systemd rollback timer and explicit `vpsg commit`
- `vpsg safe status` and manual safe rollback
- Exposure Analyzer for sockets, UFW and Docker published ports
- security baseline creation
- configuration drift detection with risk classes and `--strict`
- English and Chinese project documentation

### Changed

- direct CLI `ssh apply` and `firewall apply` now enter Safe Change automatically
- `doctor` checks prerequisites for Exposure and Safe Change

## 0.1.0

- Initial modular VPS hardening MVP
