#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rpm_root=${1:-$repo_root/build/fedora-44/RPMS}

if [[ -e /run/.containerenv ]]; then
    host=(flatpak-spawn --host)
else
    host=()
fi

mapfile -t packages < <(find "$rpm_root" -type f \
    -name 'libfprint-1.94.10-5.vfs495.3.fc44.*.rpm' \
    ! -name '*-devel-*' ! -name '*-tests-*' ! -name '*.src.rpm' | sort)
[[ ${#packages[@]} -eq 1 ]] || {
    echo "expected one Fedora 44 libfprint binary RPM under $rpm_root" >&2
    exit 2
}

"${host[@]}" rpm-ostree status
"${host[@]}" sudo rpm-ostree override replace "${packages[0]}"
echo "A new deployment is staged. Reboot to use it."
echo "Rollback command: tools/rollback-fedora-44-override.sh"
