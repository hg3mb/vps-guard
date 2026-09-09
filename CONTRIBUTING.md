# Contributing

Contributions are welcome, especially reproducible fixes and tests from real Debian/Ubuntu VPS environments.

## Before opening a pull request

```bash
bash tests/run.sh
bash scripts/build-release.sh ./dist --self-test
```

If ShellCheck is available:

```bash
find bin core modules scripts tests -type f \( -name '*.sh' -o -name 'vpsg' \) -print0 \
  | xargs -0 shellcheck -x
shellcheck -x install.sh uninstall.sh
```

## Security-sensitive changes

A PR that modifies SSH, firewall, privilege, installer, persistent root services, transaction state or destructive filesystem behavior should explain:

- the operational problem;
- the failure mode being prevented;
- the trust boundary;
- what state is changed;
- what is snapshotted/backed up;
- how failure is detected;
- how rollback/cleanup works;
- how the final effective state is verified;
- what regression test prevents the bug from returning.

Prefer fixing the violated invariant or shared primitive over adding a local exception. For example, unsafe paths belong in the common path guard, not in five different callers.

## External projects

Do not vendor differently licensed tools or add opaque privileged `curl | bash` paths merely for convenience. External integrations should keep source/license ownership clear and use an inspectable staging/confirmation boundary.

## Compatibility reports

Useful reports include:

- Debian/Ubuntu release;
- VPS/cloud provider and virtualization type when relevant;
- whether the image had provider-specific SSH/firewall/Docker customization;
- exact VPS Guard command;
- sanitized output/error;
- whether provider console/rescue access was available.

Never include private keys, access tokens, passwords or production secrets.
