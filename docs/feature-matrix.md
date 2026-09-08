# Feature matrix

VPS Guard aims to be useful as a daily VPS toolbox **without turning into a collection of opaque remote scripts**.

| Area | v0.3.0 status | Safety approach |
| --- | --- | --- |
| Beginner menu / dashboard | Implemented | Readable grouped menu; CLI remains scriptable |
| SSH hardening | Implemented | Safe Change, pre/post verify, optional password disable only with detected admin key |
| GitHub SSH key import | Implemented | HTTPS fetch, validates key format, de-duplicates, backs up existing file |
| UFW | Implemented | Preserves detected SSH port, Safe Change on initial apply, refuses deny/delete of current SSH port |
| Fail2Ban | Implemented | Isolated jail.d fragment, config test, rollback, banned/unban/log helpers |
| Users / sudo | Implemented | protects root/current session; no default login password |
| Docker | Implemented | distro package install, list/ports, explicit warning before docker-group access |
| 1Panel | Implemented | staged official-script download, HTML rejection, SHA-256 + preview + second confirmation |
| BBR / Swap | Implemented | isolated config/state and rollback |
| Network / route | Implemented | native curl/mtr/traceroute workflow |
| Media checks | Basic | reachability only; does not claim full regional unlock |
| Safe Change history | Implemented | root-owned transaction state and event history |
| Exposure risk explanation | Implemented | listeners + UFW + Docker + service hints + reasons |
| Baseline / Drift | Implemented | local trusted snapshot, privacy-aware hashes, persistent reports |
| Daily Watch | Implemented | local systemd timer, no automatic upload |
| Incident bundle | Implemented | read-only local evidence bundle; excludes secret key contents |
| Cloud firewall correlation | Planned | provider APIs/plugins needed; host cannot infer this reliably |
| Full streaming region unlock matrix | Planned / optional | should remain an optional diagnostic rather than core security logic |
| Notification channels | Planned | webhook/email/Telegram adapters, opt-in only |
| Multi-host fleet view | Planned | keep single-host CLI stable first |
