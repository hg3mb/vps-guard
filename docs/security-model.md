# Security Model

## Goals

VPS Guard tries to reduce three common VPS administration risks:

1. losing SSH access after a firewall/SSH change;
2. not knowing which services are actually listening on externally reachable interfaces;
3. missing unexpected configuration changes after initial hardening.

## Safe Change Engine guarantees

For supported SSH/UFW operations, VPS Guard snapshots relevant state and arms a root-owned systemd rollback timer **before** applying the change. The transaction becomes permanent only after `vpsg commit`.

The rollback script is stored below `/var/lib/vps-guard`, which is root-only by default. The timer invokes that local script directly and does not depend on the initiating SSH shell.

### Limitations

- A provider outage, disk corruption, broken init system or loss of root filesystem access can prevent rollback.
- UFW rollback restores VPS Guard's captured UFW configuration but cannot restore an external cloud firewall/security group.
- The current SSH transaction snapshots the VPS Guard SSH fragment. It is designed around changes made by VPS Guard, not arbitrary simultaneous edits by another administrator.
- Concurrent configuration management during a pending transaction can be overwritten by rollback. Only one pending Safe Change transaction is allowed at a time.

## Exposure Analyzer semantics

`wildcard` means a service listens on all local interfaces (`0.0.0.0`, `::` or `*`). `DOCKER-PUB` means Docker reports a published host port.

These are **potential exposure indicators**, not proof of Internet reachability. Cloud security groups, provider firewalls, NAT, routing and lower-level packet filters may still block traffic.

## Baseline privacy

The baseline deliberately avoids copying SSH authorized-key contents. It records file paths, line counts and SHA-256 hashes. Sudoers and cron files are also represented by hashes where practical.

Baseline data can still reveal usernames, service names, ports and container metadata, so `/var/lib/vps-guard` should remain root-only and should not be published.

## Recovery recommendation

Always keep at least one provider-side recovery option available when changing remote access controls: web console, serial console, rescue mode or a recent snapshot.
