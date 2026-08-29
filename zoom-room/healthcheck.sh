#!/usr/bin/env bash
# WAVE zoom-room — health-check runner for the `health.checks` list in
# ../zoom-room.yaml. One line per check, "ok" / "FAIL", exit 0 only when
# every check passes. Read-only: it never starts, stops, or reconfigures
# anything. Meant for `journalctl`-friendly cron/timer use on the Pi, or a
# one-shot after provisioning:
#
#   bash /opt/wave/profiles/zoom-room/healthcheck.sh
#
# UNPROVEN on hardware (the Pi is powered off as of 2026-08-29): the script
# is shellcheck-clean and each check degrades to FAIL when a tool is missing,
# but it has not been run against real /dev/wave-* nodes. See
# docs/zoom-room.md.
set -uo pipefail

ENV_FILE="${WAVE_ZOOM_ROOM_ENV:-/etc/wave/zoom-room.env}"
UNIT="wave-zoom-room-kiosk.service"
fail=0

report() { # report <name> <ok|FAIL> [detail]
  local name="$1" status="$2" detail="${3:-}"
  if [[ "$status" == "ok" ]]; then
    printf '%-24s ok   %s\n' "$name" "$detail"
  else
    printf '%-24s FAIL %s\n' "$name" "$detail"
    fail=1
  fi
}

# file_exists
for pair in "birddog_v4l2_node:/dev/wave-cam" "magewell_v4l2_node:/dev/wave-content"; do
  name="${pair%%:*}"; path="${pair#*:}"
  if [[ -e "$path" ]]; then
    report "$name" ok "$path -> $(readlink -f "$path" 2>/dev/null || echo '?')"
  else
    report "$name" FAIL "$path missing (udev rule not matched — fill in the PLACEHOLDER VID:PID, see 99-wave-zoom-room.rules)"
  fi
done

# file_mode — the env file must exist and be exactly 0600
if [[ -f "$ENV_FILE" ]]; then
  mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo '?')"
  if [[ "$mode" == "600" ]]; then
    report env_file_locked_down ok "$ENV_FILE mode $mode"
  else
    report env_file_locked_down FAIL "$ENV_FILE mode $mode (expected 600: sudo chmod 600 $ENV_FILE)"
  fi
else
  report env_file_locked_down FAIL "$ENV_FILE missing (install from zoom-room.env.example)"
fi

# systemd_user_active
if command -v systemctl >/dev/null 2>&1; then
  state="$(systemctl --user is-active "$UNIT" 2>/dev/null || true)"
  if [[ "$state" == "active" ]]; then
    report kiosk_unit_active ok "$UNIT $state"
  else
    report kiosk_unit_active FAIL "$UNIT ${state:-unknown} (journalctl --user -u $UNIT)"
  fi
else
  report kiosk_unit_active FAIL "systemctl not found"
fi

# process_alive
if pgrep -x chromium >/dev/null 2>&1 || pgrep -f '/usr/bin/chromium' >/dev/null 2>&1; then
  report chromium_process ok "pid $(pgrep -f '/usr/bin/chromium' | head -n1)"
else
  report chromium_process FAIL "no chromium process"
fi

# sysfs_glob_contains — any DRM connector reporting "connected"
connected=""
for s in /sys/class/drm/*/status; do
  [[ -r "$s" ]] || continue
  if [[ "$(cat "$s")" == "connected" ]]; then connected="$(basename "$(dirname "$s")")"; break; fi
done
if [[ -n "$connected" ]]; then
  report display_connected ok "$connected"
else
  report display_connected FAIL "no /sys/class/drm/*/status reads 'connected'"
fi

# command_output — firmware confirms the 1.6 A USB budget (27W/5A PSU present)
if command -v vcgencmd >/dev/null 2>&1; then
  out="$(vcgencmd get_config usb_max_current_enable 2>/dev/null || true)"
  if [[ "$out" == "usb_max_current_enable=1" ]]; then
    report usb_current_limit_high ok "$out"
  else
    report usb_current_limit_high FAIL "${out:-no output} (expect usb_max_current_enable=1: set it in config.txt AND use the 27W/5A PSU)"
  fi
else
  report usb_current_limit_high FAIL "vcgencmd not found"
fi

exit "$fail"
