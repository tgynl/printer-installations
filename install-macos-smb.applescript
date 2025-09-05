(*
Rady School of Management – macOS SMB Printer Installer (AppleScript)
- Server: rsm-print.ad.ucsd.edu (Windows Server 2016)
- Printers:
    • rsm-2s111-xerox-mac — 2nd Floor South Wing - Help Desk area
    • rsm-2w107-xerox-mac — 2nd Floor West Wing - Grand Student Lounge
- Model: Xerox AltaLink C8230 (prefer vendor PPD if installed; fallback to Generic PS)
- Default: single-sided (no duplex); duplex + stapling available if PPD exposes them
*)

on run
  set bashScript to "/bin/bash -lc 'set -euo pipefail
SERVER=\"rsm-print.ad.ucsd.edu\"

Q1_NAME=\"rsm-2s111-xerox-mac\"
Q1_DESC=\"Xerox AltaLink C8230 — Help Desk\"
Q1_LOC=\"2nd Floor South Wing - Help Desk area\"

Q2_NAME=\"rsm-2w107-xerox-mac\"
Q2_DESC=\"Xerox AltaLink C8230 — Grand Student Lounge\"
Q2_LOC=\"2nd Floor West Wing - Grand Student Lounge\"

XEROX_PPD_CANDIDATES=(
  \"/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8230.gz\"
  \"/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8230.gz\"
  \"/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8200 Series.gz\"
  \"/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8200 Series.gz\"
)
GENERIC_PPD=\"drv:///sample.drv/generic.ppd\"

have_cmd() { command -v \"$1\" >/dev/null 2>&1; }
assert_tools() {
  for c in lpadmin lpoptions cupsenable cupsaccept; do
    if ! have_cmd \"$c\"; then
      echo \"Error: missing $c (CUPS)\" >&2
      exit 1
    fi
  done
}

pick_xerox_ppd() {
  for p in \"${XEROX_PPD_CANDIDATES[@]}\"; do
    [[ -f \"$p\" ]] && { echo \"$p\"; return 0; }
  done
  return 1
}

ppd_for_model_or_generic() {
  if PPD=$(pick_xerox_ppd); then
    echo \"$PPD\"
  else
    echo \"$GENERIC_PPD\"
  fi
}

set_ppd_option_if_supported() {
  local printer=\"$1\" key=\"$2\" value=\"$3\"
  if lpoptions -p \"$printer\" -l | awk -F\":\" \"{print \\$1}\" | grep -qx \"$key\"; then
    lpadmin -p \"$printer\" -o \"$key=$value\" || true
  fi
}

set_default_simplex() {
  local printer=\"$1\" line choices
  if line=$(lpoptions -p \"$printer\" -l | grep '^Duplex/'); then
    choices=$(echo \"$line\" | sed -E 's/^[^:]+:\\s*//')
    echo \"$choices\" | grep -qw None    && { lpadmin -p \"$printer\" -o Duplex=None;    return; }
    echo \"$choices\" | grep -qw Off     && { lpadmin -p \"$printer\" -o Duplex=Off;     return; }
    echo \"$choices\" | grep -qw Simplex && { lpadmin -p \"$printer\" -o Duplex=Simplex; return; }
  fi
  set_ppd_option_if_supported \"$printer\" Duplex None
}

expose_feature_flags() {
  local printer=\"$1\"
  for kv in \
    Duplexer=True \
    Duplexer=Installed \
    OptionDuplex=Installed \
    DuplexUnit=Installed \
    InstalledDuplex=True \
    Duplex=None
  do set_ppd_option_if_supported \"$printer\" \"${kv%%=*}\" \"${kv#*=}\"; done

  for kv in \
    Stapler=Installed \
    Finisher=Installed \
    FinisherInstalled=True \
    StapleUnit=Installed \
    Staple=None
  do set_ppd_option_if_supported \"$printer\" \"${kv%%=*}\" \"${kv#*=}\"; done
}

add_printer() {
  local name=\"$1\" share=\"$2\" desc=\"$3\" loc=\"$4\" ppd
  ppd=$(ppd_for_model_or_generic)
  echo \"==> Installing $name (PPD: $ppd)\"

  lpadmin -x \"$name\" 2>/dev/null || true
  lpadmin -p \"$name\" -E -v \"smb://$SERVER/$share\" -D \"$desc\" -L \"$loc\" -m \"$ppd\"
  cupsaccept \"$name\" && cupsenable \"$name\"
  expose_feature_flags \"$name\"
  set_default_simplex \"$name\"
}

main() {
  assert_tools
  add_printer \"$Q1_NAME\" \"$Q1_NAME\" \"$Q1_DESC\" \"$Q1_LOC\"
  add_printer \"$Q2_NAME\" \"$Q2_NAME\" \"$Q2_DESC\" \"$Q2_LOC\"
  echo
  echo \"All done. Default is single-sided; users can select 2-sided & stapling from app dialogs if supported by the driver.\"
}
main
'"

  try
    -- This triggers a standard macOS admin password prompt
    do shell script bashScript with administrator privileges
    display dialog "RSM printers installed successfully." buttons {"OK"} default button "OK" with icon note
  on error errMsg number errNum
    display dialog "Installation failed (" & errNum & "): " & errMsg buttons {"OK"} default button "OK" with icon stop
  end try
end run
