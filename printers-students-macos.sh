#!/usr/bin/env bash

# Server: rsm-print.ad.ucsd.edu
# Printers:
#   • rsm-2s111-xerox-mac — 2nd Floor South Wing - Help Desk area
#   • rsm-2w107-xerox-mac — 2nd Floor West Wing - Grand Student Lounge
# Model: Xerox AltaLink C8230 (prefer vendor PPD; fallback Generic PS)
# Behavior:
#   - Description equals printer name
#   - Auth prompts on first print (or immediately with --prompt-now)
#   - Duplex + stapling ENABLED (hardware flags set), but NOT default (default stays single-sided)
echo
echo "Rady School of Management – macOS SMB Printer Installer (bash)"
echo

set -eu
(set -o pipefail) 2>/dev/null || true

### --- Configuration --- ###
SERVER="rsm-print.ad.ucsd.edu"

# Printer 1
Q1_NAME="rsm-2s111-xerox-mac"
Q1_LOC="2nd Floor South Wing - Help Desk area"

# Printer 2
Q2_NAME="rsm-2w107-xerox-mac"
Q2_LOC="2nd Floor West Wing - Grad Student Lounge"

# Xerox PPD candidates (prefer vendor; fallback Generic PS)
XEROX_PPD_CANDIDATES=(
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8230.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8230.gz"
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8200 Series.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8200 Series.gz"
)
GENERIC_PPD="drv:///sample.drv/generic.ppd"

PROMPT_NOW=0
SUGGESTED_USER=""

### --- Args --- ###
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt-now) PROMPT_NOW=1 ;;
    --username) shift; SUGGESTED_USER="${1:-}";;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift || true
done

### --- Helpers --- ###
need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo -v
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

assert_macos_tools() {
  for c in lpadmin cupsenable cupsaccept lpstat lp; do
    if ! have_cmd "$c"; then
      echo "Error: missing '$c' (CUPS tools required)." >&2
      exit 1
    fi
  done
}

pick_xerox_ppd() {
  local p
  for p in "${XEROX_PPD_CANDIDATES[@]}"; do
    if [ -f "$p" ]; then
      echo "$p"; return 0
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

# Enable duplex & stapling without probing; ignore errors if an option doesn't exist in the PPD
enable_features_no_probe() {
  local printer="$1"
  # Duplex hardware presence
  lpadmin -p "$printer" -o Duplexer=True           >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o Duplexer=Installed      >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o OptionDuplex=Installed  >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o DuplexUnit=Installed    >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o InstalledDuplex=True    >/dev/null 2>&1 || true
  # Stapler/finisher presence
  lpadmin -p "$printer" -o Stapler=Installed       >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o Finisher=Installed      >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o FinisherInstalled=True  >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o StapleUnit=Installed    >/dev/null 2>&1 || true
}

# Keep default as single-sided (don’t enable duplex by default)
set_default_simplex_no_probe() {
  local printer="$1"
  lpadmin -p "$printer" -o Duplex=None >/dev/null 2>&1 || true
}

send_auth_probe() {
  local printer="$1"
  local test_pdf="/System/Library/Printers/Libraries/PrintJobMgr.framework/Versions/A/Resources/TestPage.pdf"
  if [ -f "$test_pdf" ]; then
    lp -d "$printer" "$test_pdf" >/dev/null 2>&1 || true
  else
    printf "Authentication probe\n" | lp -d "$printer" >/dev/null 2>&1 || true
  fi
}

add_printer() {
  local name="$1" share="$2" loc="$3"
  local ppd
  ppd="$(ppd_for_model_or_generic)"

  echo "==> Adding printer '$name' (share '$share') via SMB..."
  echo "    Using PPD: $ppd"

  # Remove any existing queue silently
  lpadmin -x "$name" 2>/dev/null || true

  # Description = printer name; require auth negotiation; optionally prefill username
  if [ -n "$SUGGESTED_USER" ]; then
    lpadmin -p "$name" -E -v "smb://$SERVER/$share" -D "$name" -L "$loc" -m "$ppd" \
      -o auth-info-required=negotiate \
      -o auth-info-username-default="$SUGGESTED_USER"
  else
    lpadmin -p "$name" -E -v "smb://$SERVER/$share" -D "$name" -L "$loc" -m "$ppd" \
      -o auth-info-required=negotiate
  fi

  cupsaccept "$name"
  cupsenable "$name"

  # Enable duplex & stapling hardware (not default)
  enable_features_no_probe "$name"
  set_default_simplex_no_probe "$name"

  echo "✔ Installed '$name' at $loc"

  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "   → Sending a test page to trigger the authentication prompt for '$name'…"
    send_auth_probe "$name"
  fi
}

main() {
  need_sudo
  assert_macos_tools

  add_printer "$Q1_NAME" "$Q1_NAME" "$Q1_LOC"
  add_printer "$Q2_NAME" "$Q2_NAME" "$Q2_LOC"

  echo
  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "• You should see macOS ask for your AD username/password now; it will save them in Keychain."
  else
    echo "• On your first print to each queue, macOS will prompt for AD credentials and save them to Keychain."
    echo "  (Tip: re-run with --prompt-now to trigger the prompt immediately.)"
  fi
  echo "• Duplex and stapling are enabled (if supported by the driver), but single-sided is the default."
}

main "$@"
