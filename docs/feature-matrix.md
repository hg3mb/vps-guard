# Feature matrix

VPS Guard v0.4.0 aims to cover the practical baseline of a daily VPS toolbox while keeping security-critical behavior explicit and inspectable.

| Area | v0.4.0 | Safety / usability model |
| --- | --- | --- |
| Beginner dashboard / setup guide | Implemented | Readable next-step guidance; no blind one-click hardening |
| Doctor | Implemented | Distinguishes healthy, risky and **incomplete/unverified** checks |
| SSH hardening | Implemented | `00-vps-guard.conf`, `sshd -t` + effective-config verification, Safe Change rollback |
| GitHub SSH key import | Implemented | HTTPS fetch, format validation, de-duplication, backup, custom home support |
| UFW | Implemented | Detects/protects active SSH port, protocol validation, Safe Change on access-critical apply |
| Fail2Ban | Implemented | Own `jail.d` fragment, config test, lifecycle-aware rollback, unban/log helpers |
| Users / sudo | Implemented | Bootstrap flow, current-admin protections, password-state wording avoids false SSH claims |
| Docker / Compose | Implemented | Docker CE repository workflow, APT simulation/removal guard, explicit docker-group warning |
| 1Panel | Implemented | Checked HTTPS download, HTML rejection, checksum/preview, second confirmation, sanitized execution environment |
| BBR / Swap | Implemented | Isolated state, atomic writes where practical, rollback and path validation |
| Automatic security updates | Implemented | `unattended-upgrades`, explicit no-auto-reboot default |
| Upgrade planning | Implemented | APT simulation; highlights kernel/OpenSSH/Docker/held packages/reboot |
| Network / route | Implemented | Native summary, speed and route tools; target option-injection guard |
| YABS | Optional integration | External code is not vendored; checked HTTPS staging, minimal environment, non-root execution |
| RegionRestrictionCheck | Optional integration | External AGPL project remains outside the MIT codebase |
| Safe Change Engine 3.0 | Implemented | Authoritative transaction records, single-active invariant, durable/two-phase commit, persistent rollback, second-session/console proof, history |
| Exposure Analyzer 3.0 | Implemented | Host listeners + Docker published ports + UFW context + profile + explainable risk |
| Server profiles | Implemented | `general`, `web`, `docker-web`, `database`, `proxy`, `custom` |
| Baseline integrity | Implemented | Content hashes + file-set integrity + collection-completeness metadata |
| Semantic Drift | Implemented | Added/removed exposure, keys, sudo/users/services and collection coverage with severity |
| Watch 2.0 | Implemented | Local scheduled Exposure + Drift, severity threshold, fingerprint de-duplication, secure hook boundary |
| Incident bundle | Implemented | Read-only evidence; command lines opt-in; root-only archive + SHA256SUMS |
| Installer upgrade / program rollback | Implemented | Staged validation, root-owned runtime dirs, path/symlink/foreign-link protection, trusted backup namespace; separate from server config rollback |
| CI | Implemented | Debian 12/13 + Ubuntu 22.04/24.04 regression matrix, ShellCheck, release archive self-test |
| Cloud firewall correlation | Not claimed | Host cannot infer provider security groups/NAT reliably without a provider connector |
| Fleet management | Not yet | Single-host correctness remains the priority |

## Design rule

A feature is not considered complete merely because a command exists. Security-sensitive features should have a clear failure model, verification step, rollback story where practical, and regression coverage.
