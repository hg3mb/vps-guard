# Contributing

Contributions are welcome, especially reproducible fixes and tests for Debian/Ubuntu VPS environments.

Before opening a pull request:

```bash
./tests/run.sh
shellcheck -x bin/vpsg core/*.sh modules/builtin/*/module.sh install.sh uninstall.sh
```

For security-sensitive changes, include:

- the failure mode being prevented;
- what is backed up;
- how rollback works;
- how the change is verified;
- the Debian/Ubuntu versions tested.

Do not add remote `curl | bash` execution paths to privileged operations without a separate design discussion.
