# Security policy

## Supported versions

Only the latest release gets security fixes. Use Settings > Check for Updates to stay current.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**.

Include what you found, the Portside version (Settings sidebar), your macOS version, and steps to reproduce. This is a one-person project; expect a first reply within about 7 days.

## Scope

The parts most worth a look are the updater (`UpdateChecker.swift`, which downloads and swaps the app), the agent hooks (`AgentHooks.swift`, which edit files in `~/.claude` and `~/.codex`), and the AI Usage widget (which reads a keychain token after you agree). What Portside reads, writes, and sends is listed in the README under "Privacy and permissions".
