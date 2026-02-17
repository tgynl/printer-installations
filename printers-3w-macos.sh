#!/usr/bin/env bash
# Rady School of Management - macOS SMB Printer Installer (PhD printers)
# Server: rsm-print.ad.ucsd.edu
# Printers:
#   - rsm-3w111-hp-color / 3rd Floor / West / Faculty (HP Color LaserJet CP4025)
#   - rsm-3w111-xerox-bw-mac / 3rd Floor / West / Faculty (Xerox B8145)
# Behavior:
#   - Description equals printer name
#   - Auth prompts on first print (or immediately with --prompt-now)
#   - Duplex + stapling ENABLED (hardware flags), but NOT default (default stays single-sided)

set -eu
(set -o pipefail) 2>/dev/null || true

### --- Configuration --- ###
SERVER="rsm-print.ad.ucsd.edu"

# Printer 1 (Color)
P1_NAME="rsm-3w111-hp-color"
P1_LOC="3rd Floor / West / Faculty"

# Printer 2 (B/W)
P2_NAME="rsm-3w111-xerox-bw-mac"
P2_LOC="3rd Floor / West / Faculty"

echo "> Rady School of Management - macOS SMB Printer Installer (Faculty)"
echo "> Enter your Mac password. Cursor will NOT appear to move. Keep typing your password then press RETURN."

# PPD candidates
HP_PPD_CANDIDATES=(
  "/Library/Printers/PPDs/Contents/Resources/HP Color LaserJet CP4025.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/HP Color LaserJet CP4025.gz"
)
XEROX_PPD_CANDIDATES=(
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink B8145.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink B8145.gz"
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink B8100 Series.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink B8100 Series.gz"
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

pick_ppd_from_list() {
  local p
  for p in "$@"; do
    if [ -f "$p" ]; then
      echo "$p"; return 0
    fi
  done
  return 1
}

ppd_for_queue() {
  case "$1" in
    "$P1_NAME")
      if PPD="$(pick_ppd_from_list "${HP_PPD_CANDIDATES[@]}")"; then
        echo "$PPD"
      else
        echo "$GENERIC_PPD"
      fi
      ;;
    "$P2_NAME")
      if PPD="$(pick_ppd_from_list "${XEROX_PPD_CANDIDATES[@]}")"; then
        echo "$PPD"
      else
        echo "$GENERIC_PPD"
      fi
      ;;
    *)
      echo "$GENERIC_PPD"
      ;;
  esac
}

# Enable duplex & stapling without probing; ignore errors if an option doesn't exist
enable_features_no_probe() {
  local printer="$1"
  # Duplex hardware presence (some PPDs use Option1/Duplexer)
  lpadmin -p "$printer" -o Option1=True           >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o Duplexer=True          >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o Duplexer=Installed     >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o OptionDuplex=Installed >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o DuplexUnit=Installed   >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o InstalledDuplex=True   >/dev/null 2>&1 || true
  # Stapler/finisher presence (effective when the Xerox PPD exposes finisher options)
  lpadmin -p "$printer" -o Stapler=Installed        >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o Finisher=Installed       >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o FinisherInstalled=True   >/dev/null 2>&1 || true
  lpadmin -p "$printer" -o StapleUnit=Installed     >/dev/null 2>&1 || true
}

# Keep default as single-sided
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
  ppd="$(ppd_for_queue "$name")"

  echo
  echo "# Adding printer '$name' (share '$share') via SMB..."
  echo "# Using PPD: $ppd"

  # Remove any existing queue silently
  lpadmin -x "$name" 2>/dev/null || true

  # Description = printer name; require auth negotiation; optionally prefill username
  lpadmin -p "$name" -E -v "smb://$SERVER/$share" -D "$name" -L "$loc" -m "$ppd" \
    -o auth-info-required=negotiate \
    ${SUGGESTED_USER:+-o auth-info-username-default="$SUGGESTED_USER"} \
    2>/dev/null

  cupsaccept "$name"
  cupsenable "$name"

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

  add_printer "$P1_NAME" "$P1_NAME" "$P1_LOC"
  add_printer "$P2_NAME" "$P2_NAME" "$P2_LOC"

  echo
  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "• You should see macOS ask for your AD username/password now; it will save them in Keychain."
    echo "• Correct format to enter your AD username is ad\\username"
  else
    echo "• On your first print to each queue, macOS will prompt for AD credentials and save them in Keychain."
    echo "• Correct format to enter your AD username is ad\\username"
    echo ""
  fi
  echo "# Duplex is enabled (hardware present) but default remains single-sided."
  echo ""
}

main "$@"
