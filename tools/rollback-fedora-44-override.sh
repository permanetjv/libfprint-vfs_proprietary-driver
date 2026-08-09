#!/bin/bash
set -euo pipefail

if [[ -e /run/.containerenv ]]; then
    host=(flatpak-spawn --host)
else
    host=()
fi

"${host[@]}" rpm-ostree status
"${host[@]}" sudo rpm-ostree override reset libfprint
echo "The override removal is staged. Reboot to return to Fedora's libfprint."
