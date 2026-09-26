# Changelog

Append-only record of intentional project changes and their verification. Linux
operating/build instructions live in `linux/README.md`; macOS sources are separate.

## 2026-09-26 — Interaction fixes and brace annotations

- Undo/redo rebuilt as a per-action snapshot stack: each discrete edit is one
  step, inline typing coalesces into one step per editing session, and new
  edits clear the redo stack. The old mechanism could collapse many steps into
  one jump back to the initial document.
- Toolbar undo/redo use universally available SF Symbol names so the buttons
  render on current systems.
- Canvas stability during drags: the scrollable inset is again derived from
  the minimum zoom factor, fixing the mid-drag autoscroll clamp that made the
  whole canvas jump; drop hit-testing only considers stationary cards.
- Drop zones now reserve insertion space only below the hovered card (bottom
  quarter inserts after; everything else drops inside). The upper insertion
  zone was removed per product decision.
- Multi-selection drag: pressing a node inside an existing ⌘-selection keeps
  the selection and moves every selected branch (with subtrees) in one undo
  step; a plain click still collapses to the pressed node. Multi-delete is a
  single undo step.
- Brace annotations: select ≥2 nodes and use the toolbar 标注 button to draw a
  right-facing brace with an editable label; exported text appends
  `（备注：…）` to member lines. Documents save as `{root, annotations}` while
  bare-root legacy files still open (Linux reader updated likewise).
- Verification: full smoke suite (8 binaries, 41 PASS groups), swift build
  clean, Linux model tests 14/14 (2 suites require pytest/Qt and are skipped
  on this host).

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
