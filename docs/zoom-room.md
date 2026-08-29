# zoom-room — Pi 5 Zoom kiosk endpoint

Provisioning profile: [`../zoom-room.yaml`](../zoom-room.yaml). Support files: [`../zoom-room/`](../zoom-room/).

Verdict date: 2026-08-29. The Pi this profile targets is currently powered
off. Nothing here has been proven live on the device; everything that
depends on physical hardware is listed in [UNPROVEN](#unproven). Every other
claim carries a citation inline.

## Why not Zoom Rooms

Zoom Rooms controller software ships for Windows x86-64, macOS, and Zoom's
certified appliance hardware. There is no Raspberry Pi / aarch64 Linux build
(verified by the research lane that preceded this profile). The Raspberry
Pi 5 also has no hardware video encoder, so it could not encode a Zoom Rooms
outbound stream even if the software existed. Instead, this profile joins
the meeting as a regular **participant** via the
[Zoom Meeting SDK for Web](https://developers.zoom.us/docs/meeting-sdk/web/)
(`@zoom/meetingsdk ^6.2.0`, Component View) running inside Chromium under a
`labwc` Wayland kiosk session on Raspberry Pi OS. Chromium decodes and
encodes in software, which is the binding constraint on camera and capture
resolution.

## Module status (wave-modules)

Checked against `wave-av/wave-modules` `origin/main` on 2026-08-29
(`git show origin/main:MODULE-CATALOG.md`, `git ls-tree origin/main`):

| Module | In `MODULE-CATALOG.md` | Implementation dir in repo | Profile status |
|---|---|---|---|
| `wave-usb-cam-in` | yes (Video Input, "Capture from USB UVC cameras") | **no** | `catalogued-unimplemented`, `required_for_kiosk: false` |
| `wave-hdmi-in` | yes (Video Input, "Capture via Magewell/generic USB") | **no** | `catalogued-unimplemented`, `required_for_kiosk: false` |
| `wave-companion` | yes | yes (`wave-companion/`) | `implemented` |
| `wave-prometheus` | yes | yes (`wave-prometheus/`) | `implemented` |

The two unimplemented modules are declared so the profile is complete when
they land and so the device names they will consume (`/dev/wave-cam`,
`/dev/wave-content`) are fixed now by udev. The kiosk does not depend on
them: Chromium enumerates both UVC devices directly through `getUserMedia`,
so the meeting gets camera and content without either module.

## Wiring diagram

```
                      ┌─────────────────────────────────────┐
                      │          Raspberry Pi 5              │
                      │   (Raspberry Pi OS Bookworm, labwc)  │
                      │                                      │
  BirdDog X1  ──USB-C─┤ USB 3.0 port A  (RP1 xHCI #0)        │
  (people camera,     │   /dev/wave-cam  (udev symlink)      │
   UVC; powered by    │        │                             │
   own DC PSU or PoE) │        ├──► wave-usb-cam-in (v4l2)   │  ← catalogued, unimplemented
                      │        │                             │
  Magewell USB        │        │                             │
  Capture HDMI  ──USB─┤ USB 3.0 port B  (RP1 xHCI #1)        │
  4K Plus             │   /dev/wave-content (udev symlink)   │
  (wired content,     │        │                             │
   bus-powered ~1.4A) │        ├──► wave-hdmi-in (v4l2)      │  ← catalogued, unimplemented
                      │        │                             │
                      │        ▼  getUserMedia (both UVC)    │
                      │  Chromium --kiosk  (lwrespawn)       │
                      │    ← systemd --user unit             │
                      │    ← ~/.config/labwc/autostart       │
                      │  Zoom Meeting SDK for Web, Component │
                      │  View, page at $ROOM_URL             │
                      │  (~/.config/wave/zoom-room.env 0600) │
                      │        │                             │
                      │  HDMI out ───────────────────────────┼──► Room display
                      │                                      │
                      │  USB-C in ◄── 27W/5A official PSU    │
                      │  (config.txt usb_max_current_enable=1│
                      │   → 1.6 A downstream USB budget)     │
                      └─────────────────────────────────────┘
```

USB topology: the Pi 5's RP1 I/O controller has "two identical USB3.0 xHCI
Host Controllers ... Each controller has two downstream ports, implemented
with one USB2.0 PHY and one USB3.0 PHY ... every downstream port has
independent and uncontended bandwidth" (RP1 Peripherals datasheet,
RP-008370-DS, Chapter 5 "USB"; summary on p.1: "Two independent XHCI
controllers are each connected to a single USB 3.0 PHY, and a single USB 2.0
PHY"). Put the camera in one USB 3.0 port and the capture card in the other
so the two highest-bandwidth devices are on different controllers. This is a
physical cabling rule, not something the profile can enforce in software.

## Power budget

Sources: Raspberry Pi documentation, `computers/raspberry-pi/power-supplies.adoc`
(<https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#power-supply>);
Magewell product page (<https://www.magewell.com/products/usb-capture-hdmi-4k-plus>);
BirdDog X1 overview (<https://birddog.tv/x1-overview/>).

- Raspberry Pi 5 table row: recommended PSU current 5.0 A, "Maximum total
  USB peripheral current draw: 1.6A (600mA if using a 3A power supply)".
- Doc note, verbatim: "The Raspberry Pi 5 provides 1.6A of power to
  downstream USB peripherals when connected to a power supply capable of 5A
  at +5V (25W). When connected to any other compatible power supply, the
  Raspberry Pi 5 restricts downstream USB devices to 600mA of power."
  The retail part that meets this is the official 27W USB-C Power Supply
  (`power.psu_required`).
- `usb_max_current_enable=1` in `config.txt` is the switch for the 1.6 A
  budget; the firmware reports which limit it applied via
  `vcgencmd get_config usb_max_current_enable` (same doc page, "PMIC"
  section: "usb_max_current_enable:: Whether the current limiter was set to
  high or low"). The profile's `usb_current_limit_high` health check reads
  exactly that. **Only set it with the 27W/5A PSU** — with a 3 A supply the
  firmware falls back to 600 mA and a 1.4 A capture card will brown out.
- Magewell USB Capture HDMI 4K Plus: "USB 3.0, compatible with USB 2.0",
  "Support capture resolutions up to 3840x2160p30 or 1920x1080p90". The
  ~1.4 A draw is from the task brief's research verdict; the vendor page
  does not state current draw (UNPROVEN item 6).
- BirdDog X1: "X1 and X1 Ultra can be powered in several ways via the
  included DC power supply or PoE. With under 15W PoE requirement ..." and
  "feature USB-C for connecting directly to Zoom, Teams, and most apps that
  support a USB UVC input." The camera is externally powered, so it does
  not draw from the Pi's 1.6 A budget. Budget: Magewell ~1.4 A + X1 ~0 A
  leaves ~0.2 A headroom under 1.6 A.

## Kiosk provisioning

All install steps are also in the header comment of each file under
`zoom-room/`.

1. `config.txt`: add `usb_max_current_enable=1` to `/boot/firmware/config.txt`
   (27W/5A PSU only, see above).
2. udev: `sudo cp zoom-room/99-wave-zoom-room.rules /etc/udev/rules.d/`,
   fill in the PLACEHOLDER product IDs (see
   [USB device identification](#usb-device-identification)), then
   `sudo udevadm control --reload-rules && sudo udevadm trigger`.
3. env file, **as the kiosk user, no `sudo`**: `install -d -m 0700
   ~/.config/wave && install -m 0600 zoom-room/zoom-room.env.example
   ~/.config/wave/zoom-room.env`, then edit `ROOM_URL`. The unit in step 4
   is a systemd **--user** unit, so its `EnvironmentFile` is opened by the
   kiosk user's own manager: the file must be owned by that user. It is
   deliberately not under `/etc/wave` — a root-owned mode-0600 file there
   is unreadable to a user manager, so the kiosk would start with no
   `ROOM_URL` and loop. The unit references it as
   `%h/.config/wave/zoom-room.env` (`%h` = the unit owner's home,
   systemd.unit(5) "Specifiers"). The populated file is gitignored
   (`.gitignore`: `zoom-room/zoom-room.env`, `zoom-room.env`,
   `!zoom-room/zoom-room.env.example`) and lives only on the device.
4. systemd --user unit: `mkdir -p ~/.config/systemd/user && cp
   zoom-room/wave-zoom-room-kiosk.service ~/.config/systemd/user/ &&
   systemctl --user daemon-reload`. Do **not** `enable` it; it has no
   `[Install]` section on purpose (an enabled unit would start before the
   compositor exists and loop until `WAYLAND_DISPLAY` was imported).
5. labwc autostart: `mkdir -p ~/.config/labwc && cp zoom-room/labwc-autostart
   ~/.config/labwc/autostart`. This is the file the official Raspberry Pi
   kiosk tutorial edits
   (<https://www.raspberrypi.com/tutorials/how-to-use-a-raspberry-pi-in-kiosk-mode/>,
   "Set up kiosk mode": `.config/labwc/autostart`). The tutorial's chromium
   line is `chromium https://raspberrypi.com https://time.is/London --kiosk
   --noerrdialogs --disable-infobars --no-first-run
   --enable-features=OverlayScrollbar --start-maximized`; the unit uses the
   same flags verbatim with `${ROOM_URL}` in place of the two URLs, and
   adds nothing else.
6. Respawn: the unit's `ExecStart` wraps chromium in `/usr/bin/lwrespawn`.
   `lwrespawn` is not on the tutorial page; it is the labwc autostart
   respawn helper shipped with Raspberry Pi OS's desktop, and the official
   `raspberrypi/rpi-image-gen` kiosk layer uses it in exactly this position:
   `/usr/bin/lwrespawn /usr/local/bin/cm5-jig-browser "$IGconf_jigdesktop_url" &`
   written into `$home/.config/labwc/autostart`
   (<https://github.com/raspberrypi/rpi-image-gen/blob/master/contrib/src/cm5-programming-jig/layer/cm5-jig-desktop.yaml>,
   line 165 on `master` as of 2026-08-29). Restart=on-failure on the unit is
   the second layer.
7. Screen blanking off: on Raspberry Pi OS Bookworm and Trixie,
   `raspi-config`'s Display Options > Screen Blanking (`do_blanking`) works
   on the labwc autostart file: `LABWCAST_FILE="$HOMEDIR/.config/labwc/autostart"`,
   enabling appends `swayidle -w timeout 600 'wlopm --off \*' resume 'wlopm --on \*' &`
   and disabling runs `sed -i '/swayidle/d' $LABWCAST_FILE`
   (`RPi-Distro/raspi-config`, `bookworm` branch, lines 30, 587, 593; the
   `trixie` branch has the same logic at 30, 552, 558; the `master` branch
   still carries the X11 `xorg.conf.d/10-blanking.conf` version and does not
   apply to labwc). `zoom-room/labwc-autostart` contains no `swayidle` line,
   which is the disabled state; `sudo raspi-config nonint do_blanking 1`
   is the equivalent command.
8. Health: `bash zoom-room/healthcheck.sh` runs every entry in
   `health.checks` (udev symlinks, env-file mode 600 + owned by the
   running user, unit active, chromium
   process, DRM connector `connected`, `vcgencmd get_config
   usb_max_current_enable`). Exit 0 only when all pass.

## USB device identification

`zoom-room/99-wave-zoom-room.rules` matches `SUBSYSTEM=="video4linux"` +
`ATTRS{idVendor}`/`ATTRS{idProduct}` + `ATTR{index}=="0"` and creates
`/dev/wave-cam` (BirdDog X1) and `/dev/wave-content` (Magewell).

| Device | Vendor ID | Source | Product ID |
|---|---|---|---|
| BirdDog X1 | `3605` "BirdDog Technology Ltd" | <https://the-sz.com/products/usbid/index.php?v=0x3605> (single source; `linux-usb.org` `usb.ids` has no BirdDog entry) | `PLACEHOLDER_BIRDDOG_PID` |
| Magewell USB Capture HDMI 4K Plus | `2935` "Nanjing Magewell Electronics Co., Ltd." | <https://the-sz.com/products/usbid/index.php?v=0x2935>; `linux-media@vger.kernel.org` and `linux-uvc-devel` lsusb reports of other Magewell USB Capture models as `2935:0001` / `2935:0004` | `PLACEHOLDER_MAGEWELL_PID` |

Fill-in step on the device, one unit connected at a time:

```console
$ lsusb                                             # note "ID vvvv:pppp"
$ lsusb -d vvvv:pppp -v | grep -A2 bInterfaceClass  # expect "14 Video"
$ sudo sed -i 's/PLACEHOLDER_BIRDDOG_PID/pppp/'  /etc/udev/rules.d/99-wave-zoom-room.rules
$ sudo sed -i 's/PLACEHOLDER_MAGEWELL_PID/pppp/' /etc/udev/rules.d/99-wave-zoom-room.rules
$ sudo udevadm control --reload-rules && sudo udevadm trigger
$ ls -l /dev/wave-cam /dev/wave-content
$ v4l2-ctl --list-devices                           # confirm index 0 is the capture node
```

Then copy the real IDs back into `zoom-room.yaml` (`udev.symlinks`) and
this file, flip `verified: true`, and open a PR.

## Security notes

- `ROOM_URL` is the only secret-adjacent value. It is read by the kiosk
  user's systemd --user manager from
  `EnvironmentFile=%h/.config/wave/zoom-room.env` (owned by the kiosk user,
  mode 0600, directory mode 0700) and expanded as a single argv element;
  there is no shell in the launch path, so the URL is never re-parsed as a
  command line. The kiosk user is the trust boundary: anything running as
  that user (including the kiosk Chromium itself) can read the file, which
  is the same boundary the unit already runs inside.
- The example file contains `ROOM_URL=https://example.invalid/zoom-room/CHANGEME`
  only. The `.example` suffix and `CHANGEME` token are both on the repo's
  `.gitleaks.toml` allowlist, and `content-policy.sh` ignores
  `.env.example` files, so the tracked copy does not trip the public-repo
  gates. A populated `zoom-room.env` would be caught by both `.gitignore`
  and the committed-dotenv rule.

## UNPROVEN

Everything below requires the physical device (currently powered off) and
has not been run or observed live:

1. **BirdDog X1 product ID** — no public source; placeholder in
   `zoom-room/99-wave-zoom-room.rules` and `zoom-room.yaml`. The vendor ID
   `3605` is from a single USB-ID database mirror and must be confirmed by
   `lsusb` at the same time.
2. **Magewell USB Capture HDMI 4K Plus product ID** (vendor ID `2935` has
   two independent sources; the SKU's PID has none) — placeholder in both
   files.
3. **`ATTR{index}=="0"` targets the capture node** for each device; UVC
   devices can expose capture + metadata nodes. Needs `v4l2-ctl
   --list-devices` on hardware.
4. **Whether Raspberry Pi OS's labwc session already imports
   `WAYLAND_DISPLAY`/`DISPLAY` into the systemd --user manager** — the
   autostart file imports them regardless; whether that is redundant is
   unverified. Likewise whether the session emits
   `graphical-session.target` (not relied on).
5. **`/usr/bin/lwrespawn` present on the target image** — it is used by the
   official rpi-image-gen kiosk layer and seen by third-party kiosk
   projects as `/bin/sh /usr/bin/lwrespawn /usr/bin/wf-panel-pi`, but
   which apt package ships it and that it exists on this Pi's image is
   unverified. Fallback if absent: drop the `lwrespawn` prefix and rely on
   `Restart=on-failure`.
6. **Magewell current draw (~1.4 A)** — from the task brief's research
   verdict; the vendor page does not publish a figure. The 0.2 A headroom
   claim depends on it.
7. **End-to-end kiosk boot**: labwc session → autostart → systemd --user
   unit → Chromium load → Zoom Meeting SDK join → camera and content from
   both UVC devices reaching the meeting. None of this has run on hardware.
8. **`zoom-room/healthcheck.sh` on hardware** — `bash -n` and `shellcheck`
   clean on the Mac; never executed against real `/dev/wave-*`,
   `systemctl --user`, `/sys/class/drm/*/status`, or `vcgencmd` output.
10. **`%h` expansion in `EnvironmentFile=` on the target image** —
   systemd.unit(5) documents `%h` for user units, and Raspberry Pi OS
   Bookworm ships systemd 252, but `systemctl --user show
   wave-zoom-room-kiosk -p EnvironmentFiles` has not been run on the Pi to
   confirm the resolved path.
9. **Chromium under labwc with the tutorial's flag set only** — the tutorial
   proves those flags on Raspberry Pi OS; whether `getUserMedia` picks the
   BirdDog and Magewell by label inside the Zoom SDK page, and whether
   Chromium's software encode keeps up with the X1 at 1080p, is unverified.

## Local validation performed (this lane, on the Mac)

Recorded in the PR body. In short: `python3 -c "import yaml; ..."` on all
six profiles, `gitleaks detect --no-git` with the repo's `.gitleaks.toml`,
`scripts/public-repo-guard/content-policy.sh`, `bash -n` + `shellcheck` on
`zoom-room/healthcheck.sh`, and a `.gitignore` diff review (env-file rule
only).
