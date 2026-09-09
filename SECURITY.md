# Security Policy

VPS Guard changes privileged VPS configuration, so security reports are treated as high priority.

## Reporting

Do **not** open a public issue for vulnerabilities that could reasonably cause:

- remote code execution;
- privilege escalation;
- credential/key disclosure;
- destructive filesystem operations;
- administrator lockout or failed automatic recovery;
- unsafe execution of third-party code;
- false-clean security results caused by incomplete inspection.

Use GitHub private vulnerability reporting if it is enabled for the repository. If no private channel is available, open a minimal public issue asking for a private contact path without publishing exploit details.

Include the affected version, operating system, exact command, expected behavior, actual behavior and the smallest safe reproduction possible. Remove IPs, usernames and other sensitive operational details where they are not required.

## Supported versions

Security fixes target the latest release. Older releases may receive guidance to upgrade rather than backported fixes while the project remains pre-1.0.

## Secrets

Never attach private keys, API tokens, passwords, cookies, full provider credentials or unredacted production incident bundles to an issue.
