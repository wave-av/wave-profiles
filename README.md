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
  - name: wave-ndi-in
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
