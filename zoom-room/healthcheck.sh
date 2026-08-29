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

# Same path the --user unit reads (EnvironmentFile=%h/.config/wave/zoom-room.env).
ENV_FILE="${WAVE_ZOOM_ROOM_ENV:-${HOME}/.config/wave/zoom-room.env}"
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

# file_mode — the env file must exist, be exactly 0600, AND be owned by the
# kiosk user running this script: the --user unit reads it as that user, so
# a root-owned copy (the old /etc/wave layout) is unreadable and fails the
# check even at mode 600.
if [[ -f "$ENV_FILE" ]]; then
  mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo '?')"
  owner="$(stat -c '%U' "$ENV_FILE" 2>/dev/null || stat -f '%Su' "$ENV_FILE" 2>/dev/null || echo '?')"
  me="$(id -un)"
  if [[ "$mode" == "600" && "$owner" == "$me" ]]; then
    report env_file_locked_down ok "$ENV_FILE mode $mode owner $owner"
  elif [[ "$mode" != "600" ]]; then
    report env_file_locked_down FAIL "$ENV_FILE mode $mode (expected 600: chmod 600 $ENV_FILE)"
  else
    report env_file_locked_down FAIL "$ENV_FILE owned by $owner, expected $me (the --user unit cannot read it: chown $me $ENV_FILE)"
  fi
else
  report env_file_locked_down FAIL "$ENV_FILE missing (install from zoom-room.env.example as $(id -un), not root)"
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
