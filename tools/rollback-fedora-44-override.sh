#!/bin/bash
set -euo pipefail

if [[ -e /run/.containerenv ]]; then
    host=(flatpak-spawn --host)
else
    host=()
fi

"${host[@]}" rpm-ostree status
"${host[@]}" sudo rpm-ostree override reset \
    --uninstall libfprint-vfs495-runtime libfprint
echo "The override removal is staged. Reboot to return to Fedora's libfprint."
