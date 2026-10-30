#!/bin/bash
set -euo pipefail
PROGRAM="$(realpath "${1:-$(dirname "$(realpath "$0")")/con-login}")"
[[ -x "$PROGRAM" ]] || { echo "con-login not found at $PROGRAM" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Run it with sudo: it writes to /etc/apparmor.d." >&2; exit 2; }
cat > /etc/apparmor.d/con-login <<PROFILE
abi <abi/4.0>,
include <tunables/global>

profile con-login "$PROGRAM" flags=(unconfined) {
  userns,

  include if exists <local/con-login>
}
PROFILE
apparmor_parser -r /etc/apparmor.d/con-login
echo "Installed AppArmor profile for con-login: $PROGRAM"
