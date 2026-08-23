# AGENTS.md

Guidance for the public `libfprint-vfs_proprietary-driver` fork.

## Required shared rules

@RULES.md

## Repository purpose

This repository integrates a legacy proprietary Validity driver with
`libfprint`, which is retained as a pinned submodule.

## Working rules

- Preserve all upstream license, copyright, and attribution material.
- Never commit proprietary binaries, vendor archives, biometric samples, or
  device-private data.
- Keep changes compatible with the pinned libfprint API and Meson build.
- Treat capture, IPC, parsing, and memory-handling changes as
  security-sensitive.
- Run the focused Meson build and CI checks for changed integration code.
- Do not publish unrelated upstream activity without explicit user consent.
- Use GitHub pull requests against `master`.
