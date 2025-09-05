#!/usr/bin/env bash
# Rady School of Management – macOS SMB Printer Installer (bash)
# Server: rsm-print.ad.ucsd.edu (Windows Server 2016)
# Printers:
#   • rsm-2s111-xerox-mac — 2nd Floor South Wing - Help Desk area
#   • rsm-2w107-xerox-mac — 2nd Floor West Wing - Grand Student Lounge
# Model: Xerox AltaLink C8230 (prefer vendor PPD; fallback Generic PS)
# Default: single-sided (no duplex); duplex & stapling available if supported
#
# One-liner (CRLF-safe):
# /bin/bash -c "$(
#   curl -fsSL https://raw.githubusercontent.com/tgynl/printer-installations/main/printers-students-macos.sh | tr -d '\r'
# )"

set -eu
(set -o pipefail) 2>/dev/null || true

### --- Configuration --- ###
SERVER="rsm-print.ad.ucsd.edu"

# Printer 1
Q1_NAME="rsm-2s111-xerox-mac"
Q1_DESC="Xerox AltaLink C8230 — Help Desk"
Q1_LOC="2nd Floor South Wing - Help Desk area"

# Printer 2
Q2_NAME="rsm-2w107-xerox-mac"
Q2_DESC="Xerox AltaLink C8230 — Grand Student Lounge"
Q2_LOC="2nd Floor West Wing - Grand Student Lounge"

# Xerox PPD paths to try (common installs)
XEROX_PPD_CANDIDATES=(
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8230.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8230.gz"
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8200 Series.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8200 Series.gz"
)

# Generic PostScript fallback built into CUPS
GENERIC_PPD="drv:///sample.drv/generic.ppd"

# Logging (writeable on macOS; falls back to ~/Library/Logs if needed)
LOGFILE="/Library/Logs/rsm-printers.log"
QUIET=0

### --- Helpers --- ###
need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo -v
    # keep sudo alive during run
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
  fi
}

setup_logfile() {
  # Try system log dir first; fall back to user log dir if needed
  if ! /usr/bin/sudo /usr/bin/install -d -m 755 -o root -g wheel "$(dirname "$LOGFILE")" 2>/dev/null; then
    LOGFILE="$HOME/Library/Logs/rsm-printers.log"
    /bin/mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
  fi
  if [[ "$LOGFILE" == /Library/Logs/* ]]; then
    /usr/bin/sudo /usr/bin/touch "$LOGFILE" 2>/dev/null || true
    /usr/bin/sudo /bin/chmod 644 "$LOGFILE" 2>/dev/null || true
  else
    /usr/bin/touch "$LOGFILE" 2>/dev/null || true
    /bin/chmod 644 "$LOGFILE" 2>/dev/null || true
  fi
}

log() {
  [ "$QUIET" -eq 0 ] && echo "$*"
  if [ -n "${LOGFILE:-}" ]; then
    printf "%s %s\n" "$(date '+%F %T')" "$*" | /usr/bin/sudo /usr/bin/tee -a "$LOGFILE" >/dev/null 2>&1 || true
  fi
}

elog() {
  echo "$*" >&2
  if [ -n "${LOGFILE:-}" ]; then
    printf "%s ERROR %s\n" "$(date '+%F %T')" "$*" | /usr/bin/sudo /usr/bin/tee -a "$LOGFILE" >/dev/null 2>&1 || true
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

assert_macos_tools() {
  for c in lpadmin lpoptions cupsenable cupsaccept; do
    if ! have_cmd "$c"; then
      elog "Error: '$c' not found. CUPS is required on macOS."
      exit 1
    fi
  done
}

pick_xerox_ppd() {
  local p
  for p in "${XEROX_PPD_CANDIDATES[@]}"; do
    if [ -f "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

ppd_for_model_or_generic() {
  if PPD="$(pick_xerox_ppd)"; then
    echo "$PPD"
  else
    echo "$GENERIC_PPD"
  fi
}

# Set an option only if the PPD exposes it
set_ppd_option_if_supported() {
  local printer="$1" key="$2" value="$3"
  if lpoptions -p "$printer" -l | awk -F: '{print $1}' | grep -qx "$key"; then
    lpadmin -p "$printer" -o "$key=$value" || true
  fi
}

# Default to single-sided (Simplex)
set_default_simplex() {
  local printer="$1"
  local line choices
  if line="$(lpoptions -p "$printer" -l | grep '^Duplex/')" 2>/dev/null; then
    choices="$(echo "$line" | sed -E 's/^[^:]+:[[:space:]]*//')"
    echo "$choices" | grep -qw None    && { lpadmin -p "$printer" -o Duplex=None; return; }
    echo "$choices" | grep -qw Off     && { lpadmin -p "$printer" -o Duplex=Off; return; }
    echo "$choices" | grep -qw Simplex && { lpadmin -p "$printer" -o Duplex=Simplex; return; }
  fi
  set_ppd_option_if_supported "$printer" "Duplex" "None"
}

# Expose duplex/stapling features (names vary by PPD). DO NOT turn them on by default.
expose_feature_flags() {
  local printer="$1"
  # Duplex hardware flags
  for kv in "Duplexer=True" "Duplexer=Installed" "OptionDuplex=Installed" "DuplexUnit=Installed" "InstalledDuplex=True" "Duplex=None"; do
    set_ppd_option_if_supported "$printer" "${kv%%=*}" "${kv#*=}"
  done
  # Stapling/finisher flags
  for kv in "Stapler=Installed" "Finisher=Installed" "FinisherInstalled=True" "StapleUnit=Installed" "Staple=None"; do
    set_ppd_option_if_supported "$printer" "${kv%%=*}" "${kv#*=}"
  done
}

# Run a command with errexit disabled; return its status
run_safely() {
  set +e
  "$@"
  local rc=$?
  set -e
  return "$rc"
}

add_printer() {
  local name="$1" share="$2" desc="$3" loc="$4"
  local ppd ok=1
  ppd="$(ppd_for_model_or_generic)"

  log "Installing $name (PPD: $ppd)"

  run_safely lpadmin -x "$name" 2>/dev/null || true
  run_safely lpadmin -p "$name" -E -v "smb://$SERVER/$share" -D "$desc" -L "$loc" -m "$ppd" || ok=0
  run_safely cupsaccept "$name" || ok=0
  run_safely cupsenable "$name" || ok=0
  run_safely expose_feature_flags "$name" || ok=0
  run_safely set_default_simplex "$name" || ok=0

  if [ "$ok" -eq 1 ]; then
    log "✅  $name installed (Location: $loc)"
    return 0
  else
    elog "❌  $name failed to install (Location: $loc)"
    return 1
  fi
}

main() {
  need_sudo
  setup_logfile
  assert_macos_tools

  add_printer "$Q1_NAME" "$Q1_NAME" "$Q1_DESC" "$Q1_LOC" || true
  add_printer "$Q2_NAME" "$Q2_NAME" "$Q2_DESC" "$Q2_LOC" || true

  log ""
  log "All done! Default is single-sided."
  log "Users can choose 2-sided & stapling in app dialogs when supported by the driver."
  log "Logs: $LOGFILE"
}

main "$@"
