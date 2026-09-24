# Changelog

Append-only record of intentional project changes and their verification. Linux
operating/build instructions live in `linux/README.md`; macOS sources are separate.

## Linux native port — work in progress

- Authorized scope: add a Qt-based Linux desktop edition without changing the
  existing Swift/macOS implementation; preserve the raw MindNode JSON format.
- Remote scope: isolated CPU-only build/test container and a dedicated Strata
  build directory on Smartation, reached only via `ssh smartation`. No GPU,
  model, gateway, or existing service configuration changes.
- Packaging target: x86_64 Debian package built on Ubuntu 24.04, plus a portable
  tar archive. Publish only after unit, interaction, package-install, and actual
  X11 GUI startup checks. Live third-party AI calls require user credentials and
  are not represented by HTTP fixture tests.
