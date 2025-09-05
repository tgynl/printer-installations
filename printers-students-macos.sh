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
  if [ -n "${LOGFIL]()
