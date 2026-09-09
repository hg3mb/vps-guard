# Security model

## Goals

VPS Guard is designed around four operator questions:

1. Can I change SSH/firewall settings without turning a mistake into permanent lockout?
2. What is the host actually exposing, including Docker-published ports?
3. What changed since I last accepted this server as trusted?
4. Can the tool tell the difference between “no issue found” and “could not inspect it”?

## Safe Change guarantees

For supported access-critical operations VPS Guard creates a root-owned snapshot, records transaction state, and arms a persistent systemd rollback before making the risky change. A successful commit requires post-change verification plus either evidence of a different SSH login session or an explicit console confirmation path.

The transaction state machine uses locking so commit, manual rollback and timer rollback cannot safely be treated as unrelated shell commands. Transaction records, not the `current` pointer, are authoritative; orphan active records are rediscovered and ambiguous multiple-active state fails closed. Safety-critical state transitions use atomic replacement plus a persistence barrier. Commit is two-phase (`pending -> commit_pending -> timer verified cancelled -> committed`). If the final durable commit seal fails after timer cancellation, VPS Guard restores the previous active state and attempts to re-arm rollback protection instead of silently accepting an unprotected commit. Failure states continue blocking new risky transactions until resolved.

Rollback state transitions use the same fail-closed idea: if the persistence barrier for a transition fails, the previous visible state is restored where possible so a later manual/automatic rollback can retry instead of being stuck in a synthetic `rolling_back` state.

### What Safe Change cannot guarantee

- provider outage, broken storage/init system or an unreachable root filesystem can prevent rollback;
- it cannot restore a provider security group, cloud firewall, NAT or routing change;
- simultaneous configuration management outside VPS Guard may be overwritten by a legitimate rollback snapshot;
- a provider console/rescue mode remains the final recovery mechanism.

## SSH configuration

VPS Guard owns an early `sshd_config.d` fragment (`00-vps-guard.conf`) because OpenSSH generally uses the first obtained value for a keyword. It validates syntax and checks effective configuration rather than assuming that writing a file means the requested policy won.

Password-field state is not presented as proof that an SSH account itself is unusable. Public-key access, shell/account state and password authentication are separate concepts.

## Exposure semantics

Exposure Analyzer combines host listeners and Docker published-port metadata. Risk is based on service type, bind scope, source and selected server profile.

A wildcard/public bind is a **host exposure indicator**, not proof that the Internet can reach it. Provider firewalls, security groups, routing, NAT and arbitrary nftables/iptables policy remain outside what host inspection can prove.

Docker published ports are not marked safe merely because a simple UFW status looks restrictive. Docker packet-filtering behavior is treated as a separate trust boundary.

## Baseline and Drift

Baselines are local trusted snapshots. They avoid SSH private keys and authorized-key contents; authorized keys are represented by path/count/hash metadata. Snapshot integrity verifies expected contents **and** the expected file set.

Every collector also records coverage. If a collector becomes unavailable, Drift reports loss of visibility rather than interpreting an empty result as “nothing changed.”

`drift accept` promotes the already-reviewed snapshot from a specific report instead of silently collecting a new state after the review point.

## Watch

Watch runs Exposure + Drift locally on a systemd timer. Notification hooks are opt-in and must satisfy ownership/permission checks. Notification fingerprints are stored only after a hook actually succeeds so transient failures can retry.

Watch service hardening is designed to keep home directories readable for SSH-key inspection but not writable.

## Incident privacy

Incident collection defaults to process names rather than full command lines because argv frequently contains secrets. Full command lines require an explicit opt-in flag. SSH private keys and authorized-key contents are not copied. The resulting archive is root-only and contains an internal SHA256 manifest.

## External integrations

Remote scripts are external trust dependencies. VPS Guard does not hide that fact or vendor differently licensed projects into its MIT codebase. Checked staging and human confirmation reduce accidental execution risk, but cannot prove that a dynamic upstream script is benign. Optional non-root integrations execute with a minimal `env -i` environment, and privileged 1Panel staging also avoids inheriting unrelated administrator-shell tokens/secrets.

## Installer / uninstaller

The installer validates and lexically normalizes destinations, rejects dangerous paths and symbolic links in existing ancestor components (not just at the leaf), rejects unrelated command-entry links/files, requires root-owned critical directories during root installation, stages a program copy, performs syntax/version smoke checks, and retains a previous program version for explicit rollback. Rollback points must remain inside the root-owned install-backup namespace and may not escape through symlinked stamp directories. Program rollback does not roll back server SSH/UFW state.

The uninstaller refuses to remove VPS Guard while a Safe Change transaction is unresolved. State is preserved by default; permanent purge requires explicit confirmation and guarded paths.

## Recovery recommendation

Keep at least one provider-side recovery option available for access-control changes: web/serial console, rescue mode or a recent snapshot.
