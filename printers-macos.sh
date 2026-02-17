#!/usr/bin/env bash
# Rady School of Management - macOS SMB Printer Installer (All Locations)
# Server: rsm-print.ad.ucsd.edu
#
# Usage:
#   ./install-printers.sh [--prompt-now] [--username <ad_username>]
#
# Printer groups:
#   1) Students     – 2nd Floor / South (Help Desk) + 2nd Floor / West (Grad Lounge)
#   2) 3rd Floor S  – 3rd Floor / South
#   3) 4th Floor S  – 4th Floor / South
#   4) 5th Floor W  – 5th Floor / West
#   5) PhD          – 3rd Floor / North (HP Color + Xerox B/W)
#   6) All          – Install every printer above

set -eu
(set -o pipefail) 2>/dev/null || true

### ── Shared config ──────────────────────────────────────────── ###
SERVER="rsm-print.ad.ucsd.edu"
GENERIC_PPD="drv:///sample.drv/generic.ppd"

XEROX_C8200_PPDS=(
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8200 Series.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8200 Series.gz"
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8230.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8230.gz"
)
HP_CP4025_PPDS=(
  "/Library/Printers/PPDs/Contents/Resources/HP Color LaserJet CP4025.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/HP Color LaserJet CP4025.gz"
)
XEROX_B8145_PPDS=(
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink B8145.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink B8145.gz"
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink B8100 Series.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink B8100 Series.gz"
)

PROMPT_NOW=0
SUGGESTED_USER=""

### ── Argument parsing ───────────────────────────────────────── ###
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt-now) PROMPT_NOW=1 ;;
    --username)   shift; SUGGESTED_USER="${1:-}" ;;
    *)            echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift || true
done

### ── Helpers ────────────────────────────────────────────────── ###
need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo -v </dev/tty
    while true; do sudo -n true; sleep 60; kill -0 "$" || exit; done 2>/dev/null &
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

assert_macos_tools() {
  for c in lpadmin cupsenable cupsaccept lpstat lp; do
    have_cmd "$c" || { echo "Error: missing '$c' (CUPS tools required)." >&2; exit 1; }
  done
}

# Pick the first existing PPD from a list passed as arguments; fall back to generic
pick_ppd() {
  local p
  for p in "$@"; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done
  echo "$GENERIC_PPD"
}

enable_features_no_probe() {
  local pr="$1"
  for opt in Option1=True Duplexer=True Duplexer=Installed OptionDuplex=Installed \
             DuplexUnit=Installed InstalledDuplex=True \
             Stapler=Installed Finisher=Installed FinisherInstalled=True StapleUnit=Installed; do
    lpadmin -p "$pr" -o "$opt" >/dev/null 2>&1 || true
  done
}

set_default_simplex() {
  lpadmin -p "$1" -o Duplex=None >/dev/null 2>&1 || true
}

send_auth_probe() {
  local pr="$1"
  local pdf="/System/Library/Printers/Libraries/PrintJobMgr.framework/Versions/A/Resources/TestPage.pdf"
  if [ -f "$pdf" ]; then
    lp -d "$pr" "$pdf" >/dev/null 2>&1 || true
  else
    printf "Authentication probe\n" | lp -d "$pr" >/dev/null 2>&1 || true
  fi
}

# add_printer <name> <location> <ppd_candidate...>
# The share name equals the printer name (matches all existing scripts).
add_printer() {
  local name="$1" loc="$2"; shift 2
  local ppd
  ppd="$(pick_ppd "$@")"

  echo
  echo "# Adding '$name' → smb://$SERVER/$name"
  echo "# Location : $loc"
  echo "# PPD      : $ppd"

  lpadmin -x "$name" 2>/dev/null || true

  lpadmin -p "$name" -E \
    -v "smb://$SERVER/$name" \
    -D "$name" -L "$loc" -m "$ppd" \
    -o auth-info-required=negotiate \
    ${SUGGESTED_USER:+-o auth-info-username-default="$SUGGESTED_USER"} \
    2>/dev/null

  cupsaccept "$name"
  cupsenable "$name"
  enable_features_no_probe "$name"
  set_default_simplex "$name"

  echo "✔ Installed '$name'"

  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "   → Sending auth probe for '$name'…"
    send_auth_probe "$name"
  fi
}

### ── Printer group installers ───────────────────────────────── ###
install_students() {
  echo "▶ Installing Student printers (2nd Floor)…"
  add_printer "rsm-2s111-xerox-mac" "2nd Floor / South / Help Desk"        "${XEROX_C8200_PPDS[@]}"
  add_printer "rsm-2w107-xerox-mac" "2nd Floor / West / Grad Student Lounge" "${XEROX_C8200_PPDS[@]}"
}

install_3s() {
  echo "▶ Installing 3rd Floor South printer…"
  add_printer "rsm-3s143-xerox-mac" "3rd Floor / South" "${XEROX_C8200_PPDS[@]}"
}

install_4s() {
  echo "▶ Installing 4th Floor South printer…"
  add_printer "rsm-4s143-xerox-mac" "4th Floor / South" "${XEROX_C8200_PPDS[@]}"
}

install_5w() {
  echo "▶ Installing 5th Floor West printer…"
  add_printer "rsm-5w109-xerox-mac" "5th Floor / West" "${XEROX_C8200_PPDS[@]}"
}

install_2e() {
  echo "▶ Installing 2nd Floor East printer…"
  add_printer "rsm-2e132-xerox-bw-mac" "2nd Floor / East" "${XEROX_B8145_PPDS[@]}"
}

install_3w() {
  echo "▶ Installing 3rd Floor West printers…"
  add_printer "rsm-3w111-hp-color"     "3rd Floor / West" "${HP_CP4025_PPDS[@]}"
  add_printer "rsm-3w111-xerox-bw-mac" "3rd Floor / West" "${XEROX_B8145_PPDS[@]}"
}

install_4w() {
  echo "▶ Installing 4th Floor West printers…"
  add_printer "rsm-4w111-hp-color"     "4th Floor / West" "${HP_CP4025_PPDS[@]}"
  add_printer "rsm-4w111-xerox-bw-mac" "4th Floor / West" "${XEROX_B8145_PPDS[@]}"
}

install_phd() {
  echo "▶ Installing PhD printers (3rd Floor North)…"
  add_printer "rsm-3n127-hp-color"     "3rd Floor / North / PhD" "${HP_CP4025_PPDS[@]}"
  add_printer "rsm-3n127-xerox-bw-mac" "3rd Floor / North / PhD" "${XEROX_B8145_PPDS[@]}"
}

remove_all_rsm() {
  echo "▶ Removing all RSM printers…"
  local removed=0
  while IFS= read -r printer; do
    case "$printer" in
      rsm-*)
        echo "  Removing '$printer'…"
        lpadmin -x "$printer" 2>/dev/null && removed=$((removed + 1)) || echo "  ⚠ Could not remove '$printer'" ;;
    esac
  done < <(lpstat -p 2>/dev/null | awk '{print $2}')
  if [ "$removed" -eq 0 ]; then
    echo "  No RSM printers found."
  else
    echo "✔ Removed $removed RSM printer(s)."
  fi
}

install_all() {
  install_students
  install_2e
  install_3s
  install_3w
  install_4s
  install_4w
  install_5w
  install_phd
}

### ── Post-install message ───────────────────────────────────── ###
post_install_msg() {
  echo
  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "• macOS will prompt for AD credentials now; they'll be saved in Keychain."
  else
    echo "• On your first print, macOS will prompt for AD credentials and save them in Keychain."
  fi
  echo "• Enter your AD username as:  ad\\\\username"
  echo "• Duplex hardware is enabled, but default remains single-sided."
  echo
}

### ── Interactive menu ───────────────────────────────────────── ###
show_menu() {
  echo
  echo "============================================="
  echo "  Rady School of Management – Printer Setup"
  echo "  Server: $SERVER"
  echo "============================================="
  echo
  echo "  Select the printer(s) to install:"
  echo
  echo "  1) Students          – rsm-2s111-xerox-mac & rsm-2w107-xerox-mac"
  echo "  2) 2nd Floor East    – rsm-2e132-xerox-bw-mac"
  echo "  3) 3rd Floor South   – rsm-3s143-xerox-mac"
  echo "  4) 3rd Floor West    – rsm-3w111-xerox-bw-mac & rsm-3w111-hp-color"
  echo "  5) 4th Floor South   – rsm-4s143-xerox-mac"
  echo "  6) 4th Floor West    – rsm-4w111-xerox-bw-mac & rsm-4w111-hp-color"
  echo "  7) 5th Floor West    – rsm-5w109-xerox-mac"
  echo "  8) PhD               – rsm-3n127-xerox-bw-mac & rsm-3n127-hp-color"
  echo "  9) All               – Install every printer above"
  echo "  r) Remove all        – Remove all rsm-* printers"
  echo "  q) Quit"
  echo
}

main() {
  echo "> Rady School of Management – macOS SMB Printer Installer"
  echo "> Enter your Mac password when prompted. The cursor will NOT move — keep typing, then press RETURN."
  echo

  need_sudo
  assert_macos_tools

  while true; do
    show_menu
    printf "  Your choice [1-9, r, or q]: "
    read -r choice </dev/tty

    case "$choice" in
      1) install_students; post_install_msg ;;
      2) install_2e;       post_install_msg ;;
      3) install_3s;       post_install_msg ;;
      4) install_3w;       post_install_msg ;;
      5) install_4s;       post_install_msg ;;
      6) install_4w;       post_install_msg ;;
      7) install_5w;       post_install_msg ;;
      8) install_phd;      post_install_msg ;;
      9) install_all;      post_install_msg ;;
      r|R) remove_all_rsm ;;
      q|Q) echo "Bye!"; exit 0 ;;
      *) echo "  Invalid choice. Please enter 1–9, r, or q." ; continue ;;
    esac

    printf "  Return to menu? [y/N]: "
    read -r again </dev/tty
    case "$again" in
      y|Y) continue ;;
      *) break ;;
    esac
  done

  echo "Done."
}

main
