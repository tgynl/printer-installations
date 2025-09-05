#!/usr/bin/env bash
# Rady School of Management – macOS SMB Printer Installer
# Server: rsm-print.ad.ucsd.edu (Windows Print Server)
# Model target: Xerox AltaLink C8230 (prefer vendor PPD; fallback Generic PS)
# Behavior:
#   - Adds SMB printers with URI param ?encryption=no
#   - Printer name == description
#   - Auth modes:
#       * prompt_later → users get AD prompt on first print (saved to Keychain)
#       * prompt_now   → prompt during install; save creds to Keychain so first job prints
#   - Defaults to single-sided; keeps duplex/staple available if supported
set -euo pipefail
(set -o pipefail) 2>/dev/null || true

### --- Configuration --- ###
SERVER="rsm-print.ad.ucsd.edu"

# PRINTERS rows: "share_name|queue_name(=description)|location_label|auth_mode"
# auth_mode: "prompt_later" or "prompt_now"
PRINTERS=(
  "rsm-2s111-xerox-mac|rsm-2s111-xerox-mac|2nd Floor South – Help Desk|prompt_later"
  "rsm-2w107-xerox-mac|rsm-2w107-xerox-mac|2nd Floor West – Grand Student Lounge|prompt_later"
)

# Default options applied to all queues
DEFAULT_OPTS=(
  "auth-info-required=negotiate"   # triggers AD auth prompt when needed
)

### --- Helpers --- ###
msg() { printf "\n[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }

find_xerox_c8230_ppd() {
  local cand
  while IFS= read -r cand; do
    [[ -n "$cand" ]] && { echo "$cand"; return 0; }
  done < <(ls -1 "/Library/Printers/PPDs/Contents/Resources/"*Xerox*AltaLink*C8230*.gz 2>/dev/null || true)
  return 1
}

generic_ps_ppd() {
  if [[ -f "/Library/Printers/PPDs/Contents/Resources/Generic PostScript Printer.gz" ]]; then
    echo "/Library/Printers/PPDs/Contents/Resources/Generic PostScript Printer.gz"
  elif [[ -f "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/PrintCore.framework/Resources/Generic.ppd" ]]; then
    echo "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/PrintCore.framework/Resources/Generic.ppd"
  else
    echo ""
  fi
}

apply_safe_defaults() {
  local q="$1"
  for opt in "${DEFAULT_OPTS[@]}"; do
    lpadmin -p "$q" -o "$opt" || true
  done
  # Prefer single-sided by default; try both vendor & generic keywords
  lpadmin -p "$q" -o Duplex=None || true
  lpadmin -p "$q" -o sides=one-sided || true
}

ensure_keychain_entry() {
  local smb_host="$1" smb_share="$2" user="$3" pass="$4"
  # Use Internet password item for SMB with path "/$smb_share"
  if security find-internet-password -s "$smb_host" -r "smb " -a "$user" -p "/$smb_share" >/dev/null 2>&1; then
    security delete-internet-password -s "$smb_host" -r "smb " -a "$user" -p "/$smb_share" >/dev/null 2>&1 || true
  fi
  security add-internet-password -s "$smb_host" -r "smb " -a "$user" -p "/$smb_share" -w "$pass" >/dev/null
}

### --- Installer --- ###
install_one() {
  local share="$1" qname="$2" location="$3" auth_mode="$4"

  msg "Installing: $qname (//$SERVER/$share | $location | auth: $auth_mode)"

  # PPD selection
  local PPD=""
  if PPD="$(find_xerox_c8230_ppd)"; then
    msg "Using Xerox C8230 PPD: $PPD"
  else
    PPD="$(generic_ps_ppd)"
    if [[ -z "$PPD" ]]; then
      msg "ERROR: No suitable PPD found. Install Xerox drivers or ensure Generic PS PPD exists."
      return 1
    fi
    msg "Using Generic PS PPD: $PPD"
  fi

  # Device URI: disable SMB encryption explicitly
  local URI="smb://$SERVER/$share?encryption=no"

  # Recreate queue with name == description
  lpadmin -x "$qname" >/dev/null 2>&1 || true
  lpadmin -p "$qname" -E -v "$URI" -P "$PPD" -D "$qname" -L "$location"

  apply_safe_defaults "$qname"

  case "$auth_mode" in
    prompt_later)
      # Do nothing; CUPS/macOS will prompt on first print and offer to save to Keychain
      ;;
    prompt_now)
      printf "Enter AD username for %s (format: ad\\username or username): " "$qname"
      read -r ADUSER
      printf "Enter AD password for %s: " "$qname"
      read -rs ADPASS
      printf "\n"
      ensure_keychain_entry "$SERVER" "$share" "$ADUSER" "$ADPASS"
      ;;
    *)
      msg "Unknown auth_mode '$auth_mode'; defaulting to prompt_later."
      ;;
  esac

  # Do not share this printer from the Mac
  lpoptions -p "$qname" -o printer-is-shared=false || true

  msg "Installed: $qname"
}

main() {
  # Make sure CUPS is alive
  launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true

  for row in "${PRINTERS[@]}"; do
    IFS="|" read -r share qname location auth_mode <<<"$row"
    install_one "$share" "$qname" "$location" "$auth_mode"
  done

  msg "All done."
}

main "$@"
