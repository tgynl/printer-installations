#!/usr/bin/env bash
# Rady School of Management – macOS SMB Printer Installer (bash)
# Server: rsm-print.ad.ucsd.edu (Windows Server 2016)
# Printers:
#   • rsm-2s111-xerox-mac — 2nd Floor South Wing - Help Desk area
#   • rsm-2w107-xerox-mac — 2nd Floor West Wing - Grand Student Lounge
# Model: Xerox AltaLink C8230 (prefer vendor PPD; fallback Generic PS)
# Default: single-sided (no duplex); duplex & stapling available if supported
#
# Flags:
#   --uninstall        Remove both queues and exit
#   --force-generic    Force Generic PostScript even if Xerox PPD is present
#   --testpage         Print a CUPS test page to each queue after install
#   --quiet            Less console output (errors still shown)
#
# One-liner (handles CRLF safely):
# /bin/bash -c "$(
#   curl -fsSL https://raw.githubusercontent.com/tgynl/printer-installations/main/printers-students-macos.sh | tr -d '\r'
# )"

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

# Xerox PPD candidates (common installs)
XEROX_PPD_CANDIDATES=(
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8230.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8230.gz"
  "/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8200 Series.gz"
  "/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8200 Series.gz"
)

# Generic PostScript fallback
GENERIC_PPD="drv:///sample.drv/generic.ppd"

LOGFILE="/var/log/rsm-printers.log"
QUIET=0
FORCE_GENERIC=0
DO_UNINSTALL=0
DO_TESTPAGE=0

### --- Args --- ###
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) DO_UNINSTALL=1 ;;
    --force-generic) FORCE_GENERIC=1 ;;
    --testpage) DO_TESTPAGE=1 ;;
    --quiet|-q) QUIET=1 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  case_esac=true; shift
done

### --- Helpers --- ###
log()  { [ "$QUIET" -eq 0 ] && echo "$@" || true; echo "$(date '+%F %T') $@" >>"$LOGFILE" 2>/dev/null || true; }
elog() { echo "$@" >&2; echo "$(date '+%F %T') ERROR $@" >>"$LOGFILE" 2>/dev/null || true; }

need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo -v
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

assert_macos_tools() {
  for c in lpadmin lpoptions cupsenable cupsaccept lpstat; do
    if ! have_cmd "$c"; then
      elog "Missing required tool: $c (CUPS)"
      exit 1
    fi
  done
}

resolve_server() {
  if ! dscacheutil -q host -a name "$SERVER" >/dev/null 2>&1; then
    if ! ping -c1 -t1 "$SERVER" >/dev/null 2>&1; then
      elog "Could not resolve or reach $SERVER (DNS/Network). Continuing anyway."
      return 1
    fi
  fi
  return 0
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
  if [ "$FORCE_GENERIC" -eq 1 ]; then
    echo "$GENERIC_PPD"; return
  fi
  if PPD="$(pick_xerox_ppd)"; then
    echo "$PPD"
  else
    echo "$GENERIC_PPD"
  fi
}

# Set an option only if the PPD exposes it
set_ppd_option_if_supported() {
  local printer="$1" key="$2" value="$3"
  if lpoptions -p "$printer" -l | awk -F: '{print $1}' | grep -qx "$key"; then
    lpadmin -p "$printer" -o "$key=$value" || true
  fi
}

# Default to single-sided (Simplex)
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

# Expose duplex/stapling (names vary by PPD); do NOT enable by default
expose_feature_flags() {
  local printer="$1"
  # Duplex hardware
  set_ppd_option_if_supported "$printer" "Duplexer" "True"
  set_ppd_option_if_supported "$printer" "Duplexer" "Installed"
  set_ppd_option_if_supported "$printer" "OptionDuplex" "Installed"
  set_ppd_option_if_supported "$printer" "DuplexUnit" "Installed"
  set_ppd_option_if_supported "$printer" "InstalledDuplex" "True"
  set_ppd_option_if_supported "$printer" "Duplex" "None" # keep default single-sided
  # Stapler/Finisher
  set_ppd_option_if_supported "$printer" "Stapler" "Installed"
  set_ppd_option_if_supported "$printer" "Finisher" "Installed"
  set_ppd_option_if_supported "$printer" "FinisherInstalled" "True"
  set_ppd_option_if_supported "$printer" "StapleUnit" "Installed"
  set_ppd_option_if_supported "$printer" "Staple" "None"    # default: no stapling
}

# Run a block with errexit disabled; return success/failure
run_safely() {
  # Usage: run_safely cmd arg1 ... argN
  set +e
  "$@"
  local rc=$?
  set -e
  return "$rc"
}

add_printer() {
  local name="$1" share="$2" loc="$3"
  local ppd ok=0
  local desc="$name"   # (1) Description equals printer name

  ppd="$(ppd_for_model_or_generic)"
  log "Installing $name (PPD: $ppd)"

  # Perform the install steps; mark ok=1 only if all succeed
  ok=1
  run_safely lpadmin -x "$name" 2>/dev/null || true

  run_safely lpadmin -p "$name" -E -v "smb://$SERVER/$share" -D "$desc" -L "$loc" -m "$ppd" || ok=0
  run_safely cupsaccept "$name" || ok=0
  run_safely cupsenable "$name" || ok=0
  run_safely expose_feature_flags "$name" || ok=0
  run_safely set_default_simplex "$name" || ok=0

  if [ "$ok" -eq 1 ]; then
    # (2) Green check on success
    log "✅  $name installed (Location: $loc)"
    return 0
  else
    # (2) Red X on failure
    elog "❌  $name failed to install. See $LOGFILE for details."
    return 1
  fi
}

uninstall_printer() {
  local name="$1"
  if lpstat -p "$name" >/dev/null 2>&1; then
    run_safely lpadmin -x "$name"
    if lpstat -p "$name" >/dev/null 2>&1; then
      elog "❌  $name removal failed (still present)."
    else
      log "✅  $name removed."
    fi
  else
    log "ℹ️  $name not present; nothing to remove."
  fi
}

print_testpage() {
  local name="$1"
  if lpstat -p "$name" >/dev/null 2>&1; then
    log "Submitting CUPS test page to $name"
    run_safely lp -d "$name" /System/Library/Printers/Libraries/PrintJobMgr.framework/Versions/A/Resources/TestPage.pdf || true
  fi
}

main_install() {
  need_sudo
  assert_macos_tools
  resolve_server || true  # Non-fatal

  add_printer "$Q1_NAME" "$Q1_NAME" "$Q1_LOC" || true
  add_printer "$Q2_NAME" "$Q2_NAME" "$Q2_LOC" || true

  if [ "$DO_TESTPAGE" -eq 1 ]; then
    print_testpage "$Q1_NAME"
    print_testpage "$Q2_NAME"
  fi

  log ""
  log "All done! Default is single-sided."
  log "Users can choose 2-sided & stapling in app dialogs when supported by the driver."
}

main_uninstall() {
  need_sudo
  assert_macos_tools
  uninstall_printer "$Q1_NAME"
  uninstall_printer "$Q2_NAME"
  log "Uninstall complete."
}

if [ "$DO_UNINSTALL" -eq 1 ]; then
  main_uninstall
else
  main_install
fi
