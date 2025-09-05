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
# Enable pipefail where supported (older bash 3.2 is fine)
(set -o pipefail) 2>/dev/null || true

### --- Configuration --- ###
SERVER="rsm-print.ad.ucsd.edu"

# Printer 1
Q1_NAME="rsm-2s111-xerox-mac"
Q1_LOC="2nd Floor South Wing - Help Desk area"

# Printer 2
Q2_NAME="rsm-2w107-xerox-mac"
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

### --- Helpers --- ###
need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo -v
    # keep sudo alive during run
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

assert_macos_tools() {
  for c in lpadmin lpoptions cupsenable cupsaccept; do
    if ! have_cmd "$c"; then
      echo "Error: '$c' not found. CUPS is required on macOS." >&2
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

set_ppd_option_if_supported() {
  local printer="$1" key="$2" value="$3"
  if lpoptions -p "$printer" -l | awk -F: '{print $1}' | grep -qx "$key"; then
    lpadmin -p "$printer" -o "$key=$value" || true
  fi
}

set_default_simplex() {
  local printer="$1"
  local line choices
  if line="$(lpoptions -p "$printer" -l | grep '^Duplex/')" 2>/dev/null; then
    choices="$(echo "$line" | sed -E 's/^[^:]+:[[:space:]]*//')"
    echo "$choices" | grep -qw None    && { lpadmin -p "$printer" -o Duplex=None;    return; }
    echo "$choices" | grep -qw Off     && { lpadmin -p "$printer" -o Duplex=Off;     return; }
    echo "$choices" | grep -qw Simplex && { lpadmin -p "$printer" -o Duplex=Simplex; return; }
  fi
  set_ppd_option_if_supported "$printer" "Duplex" "None"
}

expose_feature_flags() {
  local printer="$1"
  for kv in "Duplexer=True" "Duplexer=Installed" "OptionDuplex=Installed" "DuplexUnit=Installed" "InstalledDuplex=True" "Duplex=None"; do
    set_ppd_option_if_supported "$printer" "${kv%%=*}" "${kv#*=}"
  done
  for kv in "Stapler=Installed" "Finisher=Installed" "FinisherInstalled=True" "StapleUnit=Installed" "Staple=None"; do
    set_ppd_option_if_supported "$printer" "${kv%%=*}" "${kv#*=}"
  done
}

add_printer() {
  local name="$1" share="$2" loc="$3"
  local ppd
  ppd="$(ppd_for_model_or_generic)"

  echo "==> Adding printer '$name' (share '$share') via SMB..."
  echo "    Using PPD: $ppd"

  lpadmin -x "$name" 2>/dev/null || true
  lpadmin \
    -p "$name" \
    -E \
    -v "smb://$SERVER/$share" \
    -D "$name" \       # description same as printer name
    -L "$loc" \
    -m "$ppd"

  cupsaccept "$name"
  cupsenable "$name"
  expose_feature_flags "$name"
  set_default_simplex "$name"

  echo "✔ Installed '$name' at $loc"
}

main() {
  need_sudo
  assert_macos_tools

  add_printer "$Q1_NAME" "$Q1_NAME" "$Q1_LOC"
  add_printer "$Q2_NAME" "$Q2_NAME" "$Q2_LOC"

  echo
  echo "All done!"
  echo "• Default is single-sided. Users can choose 2-sided & stapling in app dialogs if supported by the driver."
  echo "• If Xerox drivers are not installed, Generic PostScript PPD is used as fallback."
}

main "$@"
