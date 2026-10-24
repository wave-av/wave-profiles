# wave-profiles

**WAVE profiles** are pre-built edge device configurations — each a single YAML file that declares the [wave-modules](https://github.com/wave-av/wave-modules) to run and their settings, so a device can be provisioned for a specific role.

## Profiles

| Profile | Target hardware | Use case |
|---------|-----------------|----------|
| [`ndi-decoder.yaml`](ndi-decoder.yaml) | RK3328 SBC / Raspberry Pi 5 | Receive NDI and display on HDMI |
| [`srt-gateway.yaml`](srt-gateway.yaml) | Raspberry Pi 5 | Receive SRT and output to HDMI |
| [`stream-deck-station.yaml`](stream-deck-station.yaml) | Raspberry Pi 5 | Companion + Stream Deck control surface |
| [`pebble-v1.yaml`](pebble-v1.yaml) | Pi Zero 2W | Voice assistant for live production |
| [`comms-node.yaml`](comms-node.yaml) | Pi 5 / Pi Zero 2W | Intercom + SIP bridge |

## Format

A profile declares a `name`, `description`, `target_hardware`, and a list of `modules` with per-module `config`. Example (`ndi-decoder.yaml`):

```yaml
name: ndi-decoder
description: Receive NDI stream and display on HDMI
target_hardware:
  - rk3328-sbc
  - raspberry-pi-5
modules:
  - name: wave-ndi-in <!-- # guard:allow functional node name in deployment profile -->
    config:
      auto_discover: true
      tally_enabled: true
  - name: wave-hdmi-out
    config:
      resolution: auto
      audio: passthrough
```

## Usage

Profiles are consumed by [wave-agent](https://github.com/wave-av/wave-agent), which reads the selected profile and installs/starts the listed [wave-modules](https://github.com/wave-av/wave-modules) on the device.

## Status

Early. These are the initial reference profiles; field names follow the module set in [wave-modules](https://github.com/wave-av/wave-modules).

## See also

- [wave-modules](https://github.com/wave-av/wave-modules) · [wave-agent](https://github.com/wave-av/wave-agent)
- [AGENTS.md](AGENTS.md) · [CHANGELOG.md](CHANGELOG.md)

## Links
- [wave.online](https://wave.online) · [Docs](https://docs.wave.online) · [Developer portal](https://dev.wave.online)

Operated by WAVE Online, LLC.
## Buildkite runbook

The content-policy step runs on the secrets queue. Its Buildkite
condition is exactly `build.branch == pipeline.default_branch && (build.source == "schedule" || build.source == "webhook" || build.source == "api" || build.source == "ui") && build.pull_request.id == null && build.tag == null`.
A schedule on any other branch does not schedule it, and neither does a
pull request or a tag. `.buildkite/scripts/check-secret-queue-fence.sh`
fails the build if that step, or any other step on a secrets queue or
with a `secrets:` key, loses the condition or adds more logic after it.

`guard-content-policy` refuses a build when the normalized repository
identities differ: it compares host/owner/name (lowercased, scheme and
`.git` suffix agnostic), so SSH-vs-HTTPS spellings of the same
repository proceed while any other mismatch \u2014 including malformed or
empty identities \u2014 refuses. Secrets-queue steps consume host
credentials, so refusal is fail-closed (exit 2).
Trusted re-run procedure for a fork PR: run the pipeline from the
trusted base ref (a base-branch build) — never by re-running the fork
build itself. A re-run of the fork build keeps fork metadata
(`BUILDKITE_PULL_REQUEST_REPO` still points at the fork), so the guard
still refuses it; only a build whose head is the trusted base proceeds.
The host withholds secret injection from any fork build, and a manual
approval gate is required before any trusted re-run. Never approve a
re-run that executes PR-head code with host credentials.
