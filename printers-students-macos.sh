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
#
# Flags:
#   --prompt-now          Send a test page after install to trigger the macOS auth dialog immediately
#   --username <name>     Prefill a suggested username for the dialog (e.g., NETID or AD\\NETID)
#
# Notes:
#   - This script does NOT collect or store passwords. The macOS print dialog will prompt and save to Keychain.
#   - If Macs get a Kerberos ticket (kinit), printing may not prompt.

set -eu
(set -o pipefail) 2>/dev/null || true

### --- Configuration --- ###
SERVER="rsm-print.ad.ucsd.edu"

# Printer 1
Q1_NAME="rsm-2s111-xerox-mac"
Q1_LOC="2nd Floor South Wing - Help Desk area"

# Printer 2
Q2_NAME="rsm-2w107-xerox-mac"
Q2_LOC="2nd Floor West Wing - Grand Student Lounge"

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
  for c in lpadmin lpoptions cupsenable cupsaccept lpstat lp; do
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

set_ppd_option_if_supported() {
  local printer="$1" key="$2" value="$3"
  if lpoptions -p "$printer" -l | awk -F: '{print $1}' | grep -qx "$key"; then
    lpadmin -p "$printer" -o "$key=$value" || true
  fi
}

set_default_simplex() {
  local printer="$1" line choices
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
  # Duplex hardware
  set_ppd_option_if_supported "$printer" "Duplexer" "True"
  set_ppd_option_if_supported "$printer" "Duplexer" "Installed"
  set_ppd_option_if_supported "$printer" "OptionDuplex" "Installed"
  set_ppd_option_if_supported "$printer" "DuplexUnit" "Installed"
  set_ppd_option_if_supported "$printer" "InstalledDuplex" "True"
  # Keep default single-sided
  set_ppd_option_if_supported "$printer" "Duplex" "None"
  # Stapler/Finisher
  set_ppd_option_if_supported "$printer" "Stapler" "Installed"
  set_ppd_option_if_supported "$printer" "Finisher" "Installed"
  set_ppd_option_if_supported "$printer" "FinisherInstalled" "True"
  set_ppd_option_if_supported "$printer" "StapleUnit" "Installed"
  # Default no stapling
  set_ppd_option_if_supported "$printer" "Staple" "None"
}

send_auth_probe() {
  # Sending a tiny print triggers the auth dialog so the user can enter AD creds now.
  # Prefer the built-in CUPS test page if present; else send a short text.
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

  # Description equals the queue name; require auth negotiation so macOS prompts/saves creds
  # Optionally prefill a suggested username for convenience (no password handled here)
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
  expose_feature_flags "$name"
  set_default_simplex "$name"

  echo "✔ Installed '$name' at $loc"

  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "   → Sending a test page to '$name' to trigger the authentication prompt…"
    send_auth_probe "$name"
  fi
}

main() {
  need_sudo
  assert_macos_tools

  add_printer "$Q1_NAME" "$Q1_NAME" "$Q1_LOC"
  add_printer "$Q2_NAME" "$Q2_NAME" "$Q2_LOC"

  echo
  echo "All done!"
  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "• You should see a macOS authentication prompt. Enter your AD username and password; they’ll be saved to Keychain."
  else
    echo "• On your first print to each queue, macOS will prompt for AD credentials and save them to Keychain."
    echo "  (Tip: re-run with --prompt-now to trigger the prompt immediately.)"
  fi
  echo "• Default is single-sided; choose 2-sided & stapling in app dialogs if supported."
  echo "• If Xerox drivers aren’t installed, Generic PostScript PPD is used."
}

main "$@"
