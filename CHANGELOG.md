# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `zoom-room.yaml`: Raspberry Pi 5 Zoom meeting kiosk profile — BirdDog X1
  (USB camera) + Magewell USB Capture HDMI 4K Plus (wired-content source),
  Chromium under a labwc kiosk session joining via the Zoom Meeting SDK for
  Web (the Pi cannot run Zoom Rooms itself; see `docs/zoom-room.md`). Ships
  udev device-naming rules, a labwc autostart file, a systemd --user kiosk
  service, an env-file example, and a health-check runner under
  `zoom-room/`. `wave-usb-cam-in` and `wave-hdmi-in` are declared as
  catalogued-but-unimplemented (in `MODULE-CATALOG.md`, no implementation
  in wave-modules yet); the BirdDog and Magewell USB product IDs are marked
  placeholders pending `lsusb` on the physical device (currently powered
  off). Nothing in this profile has run on hardware — see the UNPROVEN
  list in `docs/zoom-room.md`.

### Fixed

- `pr-agent` lane: fork-triggered `/` commands are now refused, and the AI
  call's budget fits inside its step. Three defects, one of them only visible
  once the first was fixed.

  The job-level `if:` refused forks on the `pull_request` arm and could not on
  `issue_comment` — fork status is absent from that payload, so there was never
  an expression to write. A `fork gate` step now asks the pulls endpoint and
  fails closed: only a literal `false` proceeds, so a 404, a rate limit or a
  deleted fork all skip. The lane runs no `actions/checkout`, so fork code was
  never executed and no exfiltration path existed; what this closes is the
  comment claiming forks were already skipped, which was true of one arm only.

  `CONFIG__AI_TIMEOUT` was 600s inside a 360s step, so the runner killed the
  step before pr-agent could reach its own timeout or fall back to a secondary
  model. Now 300s.

  Fixing the first exposed a third: `stamp attempt 2 end` runs under
  `if: always()`, so when attempt 2 never ran the verdict subtracted from zero
  and reported a 1787580408-second attempt as a confident TIMED OUT.

  Contributors on forks are affected: a maintainer's `/review` on a fork PR is
  now declined with a warning rather than silently running.
  (wave-av/wave-foundation-public#73)

### Changed
- `pebble-v1.yaml`: `wave-ai-assistant` model `claude-sonnet-4-6` → `claude-sonnet-5` (current sonnet-tier workhorse per wave-model-governance catalog SSOT, task #118).
