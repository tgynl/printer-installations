#!/usr/bin/env bash
# Rady School of Management – macOS SMB Printer Installer
# Model target: Xerox AltaLink C8230 (prefer vendor PPD; fallback Generic PS)
# Requires: bash 3.2+, CUPS enabled (it is by default on macOS)
set -euo pipefail

### --- Configuration --- ###
SERVER="rsm-print.ad.ucsd.edu"

# Define queues to install: share name, friendly name (and description), location label, auth mode
# auth_mode: "prompt_later" (first-print prompt) or "prompt_now" (ask now & save to keychain)
PRINTERS=(
  "rsm-2s111-xerox-mac|rsm-2s111-xerox-mac|2nd Floor South – Help Desk|prompt_later"
  "rsm-2w107-xerox-mac|rsm-2w107-xerox-mac|2nd Floor West – Grand Student Lounge|prompt_later"
)

# Default options you want applied to all printers (edit as needed)
# NOTE: For Xerox C8230, duplex keyword is usually 'Duplex' with 'None' or 'DuplexNoTumble/DuplexTumble'.
# If Generic PS, 'sides=one-sided' works. We'll try both safely.
DEFAULT_OPTS=(
  "auth-info-required=negotiate"   # ensures AD prompt when needed
)

### --- Functions --- ###

msg() { printf "\n[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }

find_xerox_c8230_ppd() {
  local cand
  # Common vendor PPD locations
  while IFS= read -r cand; do
    [[ -n "$cand" ]] && { echo "$cand"; return 0; }
  done < <(ls -1 \
    "/Library/Printers/PPDs/Contents/Resources/"*Xerox*AltaLink*C8230*.gz 2>/dev/null || true)
  return 1
}

generic_ps_ppd() {
  # Prefer modern Generic PS location; fall back if needed
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
  # Apply generic defaults
  for opt in "${DEFAULT_OPTS[@]}"; do
    lpadmin -p "$q" -o "$opt" || true
  done

  # Try to force single-sided default across models
  # Xerox keyword attempt:
  lpadmin -p "$q" -o Duplex=None || true
  # CUPS generic keyword attempt:
  lpadmin -p "$q" -o sides=one-sided || true
}

ensure_keychain_entry() {
  local smb_host="$1" smb_share="$2" user="$3" pass="$4"
  # Save AD creds to the login keychain for the SMB path so the backend can use them
  # Protocol: smb, server: $smb_host, path: /$smb_share
  # If an entry exists, update it.
  if security find-internet-password -s "$smb_host" -r "smb " -a "$user" -p "/$smb_share" >/dev/null 2>&1; then
    security delete-internet-password -s "$smb_host" -r "smb " -a "$user" -p "/$smb_share" >/dev/null 2>&1 || true
  fi
  security add-internet-password -s "$smb_host" -r "smb " -a "$user" -p "/$smb_share" -w "$pass" >/dev/null
}

install_one() {
  local share="$1" qname="$2" location="$3" auth_mode="$4"

  msg "Installing: $qname (share: //$SERVER/$share, location: $location, auth: $auth_mode)"

  # Pick PPD
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

  # Build device URI (no embedded creds by default)
  local URI="smb://$SERVER/$share"

  # Create/replace queue, and make description = name
  # -D sets printer description; -L sets visible location string
  lpadmin -x "$qname" >/dev/null 2>&1 || true
  lpadmin -p "$qname" -E -v "$URI" -P "$PPD" -D "$qname" -L "$location"

  apply_safe_defaults "$qname"

  # Authentication handling
  case "$auth_mode" in
    prompt_later)
      # Nothing else needed; macOS will prompt on first print and store creds.
      ;;
    prompt_now)
      printf "Enter AD username for %s (format: ad\\username or username): " "$qname"
      read -r ADUSER
      printf "Enter AD password for %s: " "$qname"
      # shellcheck disable=SC2162
      read -rs ADPASS
      printf "\n"
      # Stash to keychain for the exact SMB resource so first job prints silently
      ensure_keychain_entry "$SERVER" "$share" "$ADUSER" "$ADPASS"
      ;;
    *)
      msg "Unknown auth_mode '$auth_mode'; leaving as prompt_later."
      ;;
  esac

  # Make this NOT the system default printer (change if you want)
  lpoptions -p "$qname" -o printer-is-shared=false || true

  msg "Installed: $qname"
}

main() {
  # Ensure CUPS is running
  launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true

  for row in "${PRINTERS[@]}"; do
    IFS="|" read -r share qname location auth_mode <<<"$row"
    install_one "$share" "$qname" "$location" "$auth_mode"
  done

  msg "All done."
}

main "$@"
