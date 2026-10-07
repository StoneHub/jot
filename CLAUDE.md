# Jot

Read [AGENTS.md](AGENTS.md) for project agreements, including how to ship: merge fixes and features once a Mac run of `local-pr-check` passes. Monroe tests end to end when he updates.

In a cloud session, read [docs/CLOUD-WORK.md](docs/CLOUD-WORK.md). The Swift package requires Apple SDKs, and installing Swift on Linux does not make it buildable. Run the portable checks, open the PR with the Mac test list, and leave the merge to a Mac session.

For local app work, use `scripts/build-install.py` and preserve capture and history. A cloud task does not install the app or change shell configuration.
