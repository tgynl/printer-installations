#!/usr/bin/env bash
# Rady School of Management - macOS SMB Printer Installer (All Locations)
# Server: rsm-print.ad.ucsd.edu
#
# Runs interactively even when executed via:
#   curl -fsSL https://raw.githubusercontent.com/tgynl/printer-installations/main/printers-macos.sh | bash
#
# Flags:
#   --prompt-now            Send a test job after install to trigger auth prompt immediately
#   --username <ad\\user>   Prefill suggested username for auth prompt

set -eu
(set -o pipefail) 2>/dev/null || true

### --- Shared config --- ###
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

### --- Argument parsing --- ###
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt-now) PROMPT_NOW=1 ;;
    --username) shift; SUGGESTED_USER="${1:-}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift || true
done

### --- TTY-safe input (fixes curl | bash interactive exit) --- ###
TTY="/dev/tty"
read_tty() {
  # Reads one line from the user's terminal into REPLY
  if [ -r "$TTY" ]; then
    IFS= read -r REPLY < "$TTY" || REPLY=""
  else
    # Fallback (non-interactive)
    IFS= read -r REPLY || REPLY=""
  fi
}

print_tty() {
  # Prints to the user's terminal (so prompts appear even when stdout is redirected)
  if [ -w "$TTY" ]; then
    printf "%s" "$*" > "$TTY"
  else
    printf "%s" "$*"
  fi
}

### --- Helpers --- ###
need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    # force sudo prompt to use terminal if available
    if [ -r "$TTY" ]; then
      sudo -v < "$TTY"
    else
      sudo -v
    fi
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

assert_macos_tools() {
  for c in lpadmin cupsenable cupsaccept lpstat lp; do
    have_cmd "$c" || { echo "Error: missing '$c' (CUPS tools required)." >&2; exit 1; }
  done
}

pick_ppd() {
  local p
  for p in "$@"; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done
  echo "$GENERIC_PPD"
}

enable_features_no_probe() {
  local pr="$1"
  local opt
  for opt in \
    "Option1=True" \
    "Duplexer=True" \
    "Duplexer=Installed" \
    "OptionDuplex=Installed" \
    "DuplexUnit=Installed" \
    "InstalledDuplex=True" \
    "Stapler=Installed" \
    "Finisher=Installed" \
    "FinisherInstalled=True" \
    "StapleUnit=Installed"
  do
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

add_printer() {
  local name="$1" loc="$2"; shift 2
  local ppd
  ppd="$(pick_ppd "$@")"

  echo
  echo "# Adding '$name' -> smb://$SERVER/$name"
  echo "# Location : $loc"
  echo "# PPD      : $ppd"

  lpadmin -x "$name" 2>/dev/null || true

  lpadmin -p "$name" -E \
    -v "smb://$SERVER/$name" \
    -D "$name" \
    -L "$loc" \
    -m "$ppd" \
    -o auth-info-required=negotiate \
    ${SUGGESTED_USER:+-o auth-info-username-default="$SUGGESTED_USER"} \
    2>/dev/null

  cupsaccept "$name"
  cupsenable "$name"

  enable_features_no_probe "$name"
  set_default_simplex "$name"

  echo "✔ Installed '$name'"

  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "  -> Sending auth probe for '$name'..."
    send_auth_probe "$name"
  fi
}

### --- Printer group installers --- ###
install_students() {
  echo "▶ Installing Student printers (2nd Floor)..."
  # NOTE: if your real queues end with -mac, change names here accordingly.
  add_printer "rsm-2s111-xerox" "2nd Floor / South / Help Desk" "${XEROX_C8200_PPDS[@]}"
  add_printer "rsm-2w107-xerox" "2nd Floor / West / Grad Student Lounge" "${XEROX_C8200_PPDS[@]}"
}

install_2e() { echo "▶ Installing 2nd Floor East printer..."; add_printer "rsm-2e132-xerox-bw-mac" "2nd Floor / East" "${XEROX_B8145_PPDS[@]}"; }
install_3s() { echo "▶ Installing 3rd Floor South printer..."; add_printer "rsm-3s143-xerox-mac" "3rd Floor / South" "${XEROX_C8200_PPDS[@]}"; }
install_3w() {
  echo "▶ Installing 3rd Floor West printers..."
  add_printer "rsm-3w111-hp-color" "3rd Floor / West" "${HP_CP4025_PPDS[@]}"
  add_printer "rsm-3w111-xerox-bw-mac" "3rd Floor / West" "${XEROX_B8145_PPDS[@]}"
}
install_4s() { echo "▶ Installing 4th Floor South printer..."; add_printer "rsm-4s143-xerox-mac" "4th Floor / South" "${XEROX_C8200_PPDS[@]}"; }
install_4w() {
  echo "▶ Installing 4th Floor West printers..."
  add_printer "rsm-4w111-hp-color" "4th Floor / West" "${HP_CP4025_PPDS[@]}"
  add_printer "rsm-4w111-xerox-bw-mac" "4th Floor / West" "${XEROX_B8145_PPDS[@]}"
}
install_5w() { echo "▶ Installing 5th Floor West printer..."; add_printer "rsm-5w109-xerox-mac" "5th Floor / West" "${XEROX_C8200_PPDS[@]}"; }
install_phd() {
  echo "▶ Installing PhD printers (3rd Floor North)..."
  add_printer "rsm-3n127-hp-color" "3rd Floor / North / PhD" "${HP_CP4025_PPDS[@]}"
  add_printer "rsm-3n127-xerox-bw-mac" "3rd Floor / North / PhD" "${XEROX_B8145_PPDS[@]}"
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

remove_all_rsm() {
  echo "▶ Removing all RSM printers..."
  local removed=0
  local printer

  while IFS= read -r printer; do
    case "$printer" in
      rsm-*)
        echo "  Removing '$printer'..."
        if lpadmin -x "$printer" 2>/dev/null; then
          removed=$((removed + 1))
        else
          echo "  ⚠ Could not remove '$printer'"
        fi
        ;;
    esac
  done < <(lpstat -p 2>/dev/null | awk '{print $2}')

  if [ "$removed" -eq 0 ]; then
    echo "No RSM printers found."
  else
    echo "✔ Removed $removed RSM printer(s)."
  fi
}

post_install_msg() {
  echo
  if [ "$PROMPT_NOW" -eq 1 ]; then
    echo "• macOS will prompt for AD credentials now; they'll be saved in Keychain."
  else
    echo "• On your first print, macOS will prompt for AD credentials and save them in Keychain."
  fi
  echo "• Enter your AD username as: ad\\username"
  echo "• Duplex hardware is enabled, but default remains single-sided."
  echo
}

show_menu() {
  echo
  echo "============================================="
  echo " Rady School of Management - Printer Setup"
  echo " Server: $SERVER"
  echo "============================================="
  echo
  echo "Select the printer(s) to install:"
  echo
  echo " 1) Students - 2nd Floor (South + West)"
  echo " 2) 2nd Floor East"
  echo " 3) 3rd Floor South"
  echo " 4) 3rd Floor West"
  echo " 5) 4th Floor South"
  echo " 6) 4th Floor West"
  echo " 7) 5th Floor West"
  echo " 8) PhD (3rd Floor North)"
  echo " 9) All"
  echo " r) Remove all rsm-* printers"
  echo " q) Quit"
  echo
}

main() {
  echo "> Rady School of Management - macOS SMB Printer Installer"
  echo "> Enter your Mac password when prompted."
  echo "> The cursor will NOT move - keep typing, then press RETURN."

  need_sudo
  assert_macos_tools

  while true; do
    show_menu

    print_tty "Your choice [1-9, r, or q]: "
    read_tty
    choice="$REPLY"

    case "$choice" in
      1) install_students; post_install_msg ;;
      2) install_2e; post_install_msg ;;
      3) install_3s; post_install_msg ;;
      4) install_3w; post_install_msg ;;
      5) install_4s; post_install_msg ;;
      6) install_4w; post_install_msg ;;
      7) install_5w; post_install_msg ;;
      8) install_phd; post_install_msg ;;
      9) install_all; post_install_msg ;;
      r|R) remove_all_rsm ;;
      q|Q) echo "Bye!"; exit 0 ;;
      *) echo "Invalid choice. Please enter 1-9, r, or q." ;;
    esac

    print_tty "Return to menu? [y/N]: "
    read_tty
    again="$REPLY"

    case "$again" in
      y|Y) continue ;;
      *) break ;;
    esac
  done

  echo "Done."
}

main
