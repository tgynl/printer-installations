#!/usr/bin/env bash
# Rady School of Management Student Printer Installation Script for macOS
# Installs two SMB-shared Xerox printers on macOS using CUPS (lpadmin).
# - Server: rsm-print.ad.ucsd.edu (Windows Server 2016)
# - Printers: rsm-2s111-xerox-mac (Help Desk), rsm-2w107-xerox-mac (Grand Student Lounge))
# - Model: Xerox AltaLink C8230 (use vendor PPD if present; otherwise Generic PS)
# - Features: Expose duplex + stapling if supported by the installed PPD
# - Default: single-sided (no duplex)
## Usage (one‑liner):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tgynl/printer-installations/main/install-macos-smb.sh)"
#
# • macOS with CUPS (10.13+). Tested with macOS 12+ APIs.
# • If you later install official Xerox drivers, re-run this script to auto‑switch to the better PPD.
set -euo pipefail

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

# Xerox PPD candidates (add more if your package installs to a different filename)
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
  if [[ $(id -u) -ne 0 ]]; then
    sudo -v
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
  for p in "${XEROX_PPD_CANDIDATES[@]}"; do
    if [[ -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

ppd_for_model_or_generic() {
  if PPD=$(pick_xerox_ppd); then
    echo "$PPD"
  else
    echo "$GENERIC_PPD"
  fi
}

set_ppd_option_if_supported() {
  local printer="$1" key="$2" value="$3"
  if lpoptions -p "$printer" -l | awk -F":" '{print $1}' | grep -qx "$key"; then
    lpadmin -p "$printer" -o "$key=$value" || true
  fi
}

set_default_simplex() {
  local printer="$1"
  local line
  if line=$(lpoptions -p "$printer" -l | grep '^Duplex/'); then
    local choices
    choices=$(echo "$line" | sed -E 's/^[^:]+:\s*//')
    if echo "$choices" | grep -qw None;   then lpadmin -p "$printer" -o Duplex=None   || true; return; fi
    if echo "$choices" | grep -qw Off;    then lpadmin -p "$printer" -o Duplex=Off    || true; return; fi
    if echo "$choices" | grep -qw Simplex;then lpadmin -p "$printer" -o Duplex=Simplex|| true; return; fi
  fi
  set_ppd_option_if_supported "$printer" "Duplex" "None"
}

expose_feature_flags() {
  local printer="$1"
  for kv in \
    'Duplexer=True' \
    'Duplexer=Installed' \
    'OptionDuplex=Installed' \
    'DuplexUnit=Installed' \
    'InstalledDuplex=True' \
    'Duplex=None'
  do
    set_ppd_option_if_supported "$printer" "${kv%%=*}" "${kv#*=}"
  done

  for kv in \
    'Stapler=Installed' \
    'Finisher=Installed' \
    'FinisherInstalled=Truefor kv in \
    'Stapler=Installed' \
    'Finisher=Installed' \
    'FinisherInstalled=True' \
    'StapleUnit=Installed' \
    'Staple=None'
  do
    set_ppd_option_if_supported "$printer" "${kv%%=*}" "${kv#*=}"
  donefor_model_or_generic)

  echo "\n==> Adding printer '$name' (share '$share') via SMB..."
  echo "    Using PPD: $ppd"

  lpadmin -x "$name" 2>/dev/null || true
  lpadmin \
    -p "$name" \
    -E \
    -v "smb://$SERVER/$share" \
    -D "$desc" \
    -L "$loc" \
    -m "$ppd"

  cupsaccept "$name"
  cupsenable "$name"

  expose_feature_flags "$name"
  set_default_simplex "$name"

  echo "    ✔ Installed '$name' ($desc) at $loc"
}

main() {
  need_sudo
  assert_macos_tools

  add_printer "$Q1_NAME" "$Q1_NAME" "$Q1_DESC" "$Q1_LOC"
  add_printer "$Q2_NAME" "$Q2_NAME" "$Q2_DESC" "$Q2_LOC"

  echo "\nAll done!"
  echo "• Default is single-sided. Users can choose 2‑sided and stapling in app dialogs if supported by the driver."
  echo "• If Xerox drivers are not installed, a Generic PostScript PPD is used as fallback."
}

main "$@"
