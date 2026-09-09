# Changelog

All notable changes to VPS Guard are documented here.

## 0.4.0

### Safe Change Engine 3.0

- Hardened the access-critical transaction state machine with locking, explicit failure states and guarded transaction identifiers.
- Added persistent rollback behavior independent of the initiating SSH shell.
- Added commit protection that rejects the same SSH login session unless an explicit console confirmation path is used.
- Added deadline extension, history, event logs and safer automatic/manual rollback coordination.
- Migrated the VPS Guard SSH drop-in to `00-vps-guard.conf` and verify effective OpenSSH policy instead of assuming a later drop-in overrides earlier values.
- Improved rollback lifecycle handling for SSH/UFW and systemd timer cleanup.
- Made transaction state writes restore the previous visible phase when a persistence barrier fails, so rollback remains retryable rather than becoming stranded in a half-transition.
- Re-arm rollback protection when the final durable commit seal cannot be persisted after timer cancellation.
- Refuse foreign/symlink collisions at VPS Guard-owned SSH configuration paths instead of overwriting them.

### Exposure Analyzer 3.0

- Unified host listeners and Docker published ports into one exposure model.
- Switched Docker publication inspection to structured Docker metadata and support multiple bindings per container port.
- Added bind-scope classification including loopback, private ranges, CGNAT, public-specific and wildcard binds.
- Added server profiles (`general`, `web`, `docker-web`, `database`, `proxy`, `custom`).
- Added container-port-aware service/risk classification (for example host `13306 -> container 3306`).
- Explicitly report incomplete Docker visibility instead of silently omitting container exposure.
- Avoid false safety conclusions from simplistic UFW state when Docker publication is involved.

### Baseline & Semantic Drift 3.0

- Added snapshot file-set integrity in addition to content hashes.
- Added collector-completeness metadata so failed inspection cannot be confused with an empty/clean result.
- Added semantic severity for added/removed listeners, Docker publications, SSH keys, sudo/users/services and collection coverage changes.
- Added reviewed-snapshot acceptance (`drift accept`) rather than recollecting state after review.
- Added legacy-schema guidance and stronger integrity verification.

### Daily operations and beginner UX

- Added/expanded beginner setup guide and doctor checks.
- Added user bootstrap flow with GitHub SSH keys and safer account-state wording.
- Reworked Docker CE installation around APT simulation, conflict analysis and a VPS Guard-owned repository configuration.
- Added automatic security update management with no-auto-reboot default.
- Added YABS and RegionRestrictionCheck as explicit, checked third-party integrations rather than vendored code.
- Improved Fail2Ban lifecycle-aware rollback, BBR state handling and managed Swap cleanup.
- Expanded 1Panel checked-installer workflow.

### Watch / incident response

- Hardened Watch systemd sandboxing and notification-hook ownership/permission checks.
- Added severity thresholds, stable notification fingerprints and retry behavior when notifications fail.
- Changed incident collection to exclude full process command lines by default and added archive integrity manifests.

### Installer / uninstaller / release engineering

- Reworked install/upgrade with staging, path validation, foreign-link protection, installed smoke checks and explicit program rollback.
- Extended privileged path validation to reject symbolic links in existing ancestor components, not only at the final path.
- Sanitized environments passed to downloaded third-party scripts so unrelated administrator-shell tokens are not inherited.
- Refuse symlink collisions at VPS Guard-owned Docker repository paths.
- Kept program rollback separate from Safe Change configuration rollback.
- Block uninstall while unresolved Safe Change transactions exist.
- Preserve state by default; purge requires explicit confirmation and dangerous-path protection.
- Added a 114-test regression suite covering safety properties, inspection semantics, external-code boundaries and installer lifecycle.
- Added Debian 12/13 and Ubuntu 22.04/24.04 CI regression matrix, ShellCheck and release-archive self-tests.
- Added release builder that creates ZIP/tar.gz, SHA256SUMS and can re-test extracted archives.

## 0.3.0

- Safe Change Engine 2.0: pre-checks, post-apply verification, commit verification, transaction history and event logs.
- Exposure Analyzer 2.0: risk levels, common service hints, Docker/UFW correlation, explanations and practical recommendations.
- Baseline & Drift 2.0: human-readable risk reasons and persistent drift reports.
- Added user/sudo management, Docker/1Panel/network tooling, Watch and incident collection.
- Fixed installed `/usr/local/bin/vpsg` symlink root resolution.

## 0.2.0

- Initial Safe Change Engine.
- Initial Exposure Analyzer.
- Initial Baseline & Drift.
