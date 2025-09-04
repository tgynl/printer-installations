#!/usr/bin/env bash
# Rady School of Management Student Printer Installation Script for macOS
# Installs two Xerox AltaLink C8200 SMB printers on macOS with duplex ON,
# stapling enabled (if available), and per-queue location metadata.
# Usage: curl -fsSL "https://raw.githubusercontent.com/tgynl/printer-installations/main/printers-students-macos.sh" | sudo bash

set -euo pipefail

SERVER="rsm-print.ad.ucsd.edu"
declare -a QUEUES=(
  "rsm-2s111-xerox-mac"
  "rsm-2w107-xerox-mac"
)

# Human-friendly names and Locations
declare -A DISPLAY_NAME=(
  ["rsm-2s111-xerox-mac"]="RSM 2S111 Xerox (Mac)"
  ["rsm-2w107-xerox-mac"]="RSM 2W107 Xerox (Mac)"
)
declare -A LOCATIONS=(
  ["rsm-2s111-xerox-mac"]="2nd Floor South Wing - Help Desk area"
  ["rsm-2w107-xerox-mac"]="2nd Floor West Wing - Grand Student Lounge"
)

ensure_cups() {
  echo "Ensuring CUPS is enabled and running..."
  sudo launchctl enable system/org.cups.cupsd >/dev/null 2>&1 || true
  sudo launchctl start  system/org.cups.cupsd >/dev/null 2>&1 || true
}

# Prefer using the installed Xerox model definition over a raw PPD file
find_xerox_c8200_model() {
  # Example lpinfo line:
  # xerox/Xerox AltaLink C8230.gz "Xerox AltaLink C8230"
  local cand
  cand="$(lpinfo -m 2>/dev/null | grep -i 'xerox' | grep -i 'altalink' | grep -Ei 'c82[0-9]{2}' | head -n1 || true)"
  if [[ -n "$cand" ]]; then
    echo "$cand" | awk '{print $1}'
    return 0
  fi
  return 1
}

find_generic_ps_ppd() {
  local candidates=(
    "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/PrintCore.framework/Resources/Generic.ppd"
    "/System/Library/Printers/PPDs/Contents/Resources/Generic.ppd"
  )
  for c in "${candidates[@]}"; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

add_printer_base() {
  local queue="$1"
  local uri="smb://${SERVER}/${queue}"
  local disp="${DISPLAY_NAME[$queue]:-$queue}"
  local loc="${LOCATIONS[$queue]:-}"

  # Remove existing queue if present
  sudo lpadmin -x "$queue" >/dev/null 2>&1 || true

  local model
  if model="$(find_xerox_c8200_model)"; then
    echo "Adding ${queue} with model '${model}' ..."
    sudo lpadmin -p "$queue" -E -v "$uri" -m "$model"
  else
    echo "Xerox model not found; falling back to Generic PostScript..."
    local gppd
    gppd="$(find_generic_ps_ppd)" || { echo "No suitable PPD found."; exit 1; }
    sudo lpadmin -p "$queue" -E -v "$uri" -P "$gppd"
  fi

  # Set Display Name (-D) and Location (-L)
  sudo lpadmin -p "$queue" -D "$disp"
  [[ -n "$loc" ]] && sudo lpadmin -p "$queue" -L "$loc"

  # Require auth (good for AD/Kerberos joined Macs)
  sudo lpadmin -p "$queue" -o auth-info-required=negotiate

  # Enable queue and accept jobs
  sudo cupsenable "$queue"
  sudo cupsaccept "$queue"
}

# Enable duplex and stapling defaults (detects available options)
tune_duplex_and_stapling() {
  local queue="$1"

  # Duplex: use standard CUPS PPD option if present
  # Common values: None | DuplexNoTumble (long-edge) | DuplexTumble (short-edge)
  if lpoptions -p "$queue" -l 2>/dev/null | grep -q '^Duplex/'; then
    echo "Setting duplex (long-edge) on for $queue..."
    sudo lpadmin -p "$queue" -o Duplex=DuplexNoTumble
  else
    echo "Duplex option not found for $queue (driver may not expose it)."
  fi

  # Stapling: probe for common Xerox/PPD keys and pick a sensible default
  local opts
  opts="$(lpoptions -p "$queue" -l 2>/dev/null || true)"

  # Try several likely option names in order of commonality
  local key value=""
  declare -a CANDIDATES=(
    "StapleLocation"   # values: None, SingleLeft, UpperLeft, TwoLeft, etc.
    "XRXStaple"        # Xerox-specific: Off/On or location variants
    "Stapling"         # Generic On/Off
    "Staple"           # Generic
    "Finishing"        # May include stapling among other finishings
  )

  for key in "${CANDIDATES[@]}"; do
    if echo "$opts" | grep -q "^${key}/"; then
      # Extract available values (after the colon)
      local line values
      line="$(echo "$opts" | grep "^${key}/" | head -n1)"
      values="$(echo "$line" | sed 's/.*: //')"

      # Prefer single-staple upper/left if present; else any non-none/on value
      for candidate in SingleLeft UpperLeft Left TopLeft StapleTopLeft OneStaple DualLeft On Enabled; do
        if echo "$values" | grep -Eiq "(^|\s)\*?${candidate}(\s|$)"; then
          value="$candidate"
          break
        fi
      done
      if [[ -z "$value" ]]; then
        value="$(echo "$values" | tr ' ' '\n' | grep -viE '(^$|none|off|disabled)' | sed 's/^\*//' | head -n1 || true)"
      fi
      if [[ -n "$value" ]]; then
        echo "Enabling stapling on $queue via ${key}=${value}"
        sudo lpadmin -p "$queue" -o "${key}=${value}"
        return 0
      fi
    fi
  done

  echo "Stapling option not detected for $queue (finisher may be absent or driver hides it)."
  return 0
}

main() {
  ensure_cups
  for q in "${QUEUES[@]}"; do
    add_printer_base "$q"
    tune_duplex_and_stapling "$q"
  done

  echo
  echo "Installed printers:"
  lpstat -p
  echo
  echo "Tip: set default -> sudo lpadmin -d ${QUEUES[0]}"
}

main "$@"
