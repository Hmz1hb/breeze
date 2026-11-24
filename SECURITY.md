# Security policy

Breeze ships a root LaunchDaemon (`BreezeHelper`) that writes to the SMC, a Unix-socket protocol between the app and that helper, and a cleanup engine that moves files to the Trash. Bugs in these areas can be serious, so please report them privately.

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on this repository. Do not open a public issue or pull request.

Please include:

- the affected version or commit,
- your Mac model and macOS version,
- steps to reproduce, and what an attacker gains (for example, an unprivileged process controlling the helper, fans held at an unsafe speed, or files removed without approval).

You should get a reply within 7 days. Fixes are released as soon as practical, and you will be credited unless you prefer not to be.

## Supported versions

Only the latest release receives security fixes.

## In scope

- Helper client authentication (audit token, signing identifier, team checks)
- Anything that stops Breeze from restoring Apple automatic fan control
- The helper wire protocol (`Command` / `Reply`)
- Cleanup removing or exposing data the user did not approve
- The BreezeMCP server and the Cleanup Assistant bridge files
