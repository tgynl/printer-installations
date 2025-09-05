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
  set bashScript to "/bin/bash -c 'set -eu; set -o | grep -q pipefail && set -o pipefail || true

SERVER=\"rsm-print.ad.ucsd.edu\"

Q1_NAME=\"rsm-2s111-xerox-mac\"
Q1_DESC=\"Xerox AltaLink C8230 — Help Desk\"
Q1_LOC=\"2nd Floor South Wing - Help Desk area\"

Q2_NAME=\"rsm-2w107-xerox-mac\"
Q2_DESC=\"Xerox AltaLink C8230 — Grand Student Lounge\"
Q2_LOC=\"2nd Floor West Wing - Grand Student Lounge\"

# --- Helper: check command exists ---
have_cmd() { command -v \"$1\" >/dev/null 2>&1; }

# --- Ensure required CUPS tools ---
assert_tools() {
  for c in lpadmin lpoptions cupsenable cupsaccept; do
    if ! have_cmd \"$c\"; then
      echo \"Error: missing $c (CUPS)\" >&2
      exit 1
    fi
  done
}

# --- Pick Xerox PPD if present, else Generic PS ---
ppd_for_model_or_generic() {
  if [ -f \"/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8230.gz\" ]; then
    echo \"/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8230.gz\"
    return
  fi
  if [ -f \"/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8230.gz\" ]; then
    echo \"/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8230.gz\"
    return
  fi
  if [ -f \"/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8200 Series.gz\" ]; then
    echo \"/Library/Printers/PPDs/Contents/Resources/Xerox AltaLink C8200 Series.gz\"
    return
  fi
  if [ -f \"/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8200 Series.gz\" ]; then
    echo \"/Library/Printers/PPDs/Contents/Resources/en.lproj/Xerox AltaLink C8200 Series.gz\"
    return
  fi
  echo \"drv:///sample.drv/generic.ppd\"
}

# --- Set option only if PPD exposes it ---
set_ppd_option_if_supported() {
  printer=\"$1\"; key=\"$2\"; value=\"$3\"
  if lpoptions -p \"$printer\" -l | awk -F\":\" '{print $1}' | grep -qx \"$key\"; then
    lpadmin -p \"$printer\" -o \"$key=$value\" || true
  fi
}

# --- Default to single-sided ---
set_default_simplex() {
  printer=\"$1\"
  if lpoptions -p \"$printer\" -l 2>/dev/null | grep -q '^Duplex/'; then
    opts=$(lpoptions -p \"$printer\" -l | grep '^Duplex/' | sed -E 's/^[^:]+:[[:space:]]*//')
    echo \"$opts\" | grep -qw None    && { lpadmin -p \"$printer\" -o Duplex=None;    return; }
    echo \"$opts\" | grep -qw Off     && { lpadmin -p \"$printer\" -o Duplex=Off;     return; }
    echo \"$opts\" | grep -qw Simplex && { lpadmin -p \"$printer\" -o Duplex=Simplex; return; }
  fi
  set_ppd_option_if_supported \"$printer\" \"Duplex\" \"None\"
}

# --- Expose duplex/stapling features (if the PPD supports them) ---
expose_feature_flags() {
  printer=\"$1\"
  # Duplex-related flags
  set_ppd_option_if_supported \"$printer\" \"Duplexer\" \"True\"
  set_ppd_option_if_supported \"$printer\" \"Duplexer\" \"Installed\"
  set_ppd_option_if_supported \"$printer\" \"OptionDuplex\" \"Installed\"
  set_ppd_option_if_supported \"$printer\" \"DuplexUnit\" \"Installed\"
  set_ppd_option_if_supported \"$printer\" \"InstalledDuplex\" \"True\"
  # Ensure default stays single-sided
  set_ppd_option_if_supported \"$printer\" \"Duplex\" \"None\"

  # Stapling/finisher flags
  set_ppd_option_if_supported \"$printer\" \"Stapler\" \"Installed\"
  set_ppd_option_if_supported \"$printer\" \"Finisher\" \"Installed\"
  set_ppd_option_if_supported \"$printer\" \"FinisherInstalled\" \"True\"
  set_ppd_option_if_supported \"$printer\" \"StapleUnit\" \"Installed\"
  # Keep default as no stapling
  set_ppd_option_if_supported \"$printer\" \"Staple\" \"None\"
}

# --- Add a printer queue via SMB ---
add_printer() {
  name=\"$1\"; share=\"$2\"; desc=\"$3\"; loc=\"$4\"
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
  echo \"All done. Default is single-sided; users can select 2-sided & stapling in app dialogs if supported by the driver.\"
}
main
'"

  try
    -- Standard macOS elevation prompt:
    do shell script bashScript with administrator privileges
    display dialog "RSM printers installed successfully." buttons {"OK"} default button "OK" with icon note
  on error errMsg number errNum
    display dialog "Installation failed (" & errNum & "): " & errMsg buttons {"OK"} default button "OK" with icon stop
  end try
end run
