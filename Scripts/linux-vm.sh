#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f work/linux-vm.env ] && . work/linux-vm.env
HOST="${CON_LINUX_HOST:?set CON_LINUX_HOST (user@host) or put it in work/linux-vm.env}"
KEY="${CON_LINUX_KEY:?set CON_LINUX_KEY (ssh key path) or put it in work/linux-vm.env}"
SSH=(ssh -i "$KEY" -o BatchMode=yes)
rsync -az --delete -e "${SSH[*]}" --exclude /work/ --exclude /Con.app/ --exclude .build/ --exclude .DS_Store ./ "$HOST:con-build/Con/"
"${SSH[@]}" "$HOST" "cd ~/con-build/Con && export PATH=\$HOME/con-build/swift/usr/bin:\$PATH && $*"
