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
    -name 'libfprint-1.94.10-5.vfs495.6.fc44.*.rpm' \
    ! -name '*-devel-*' ! -name '*-tests-*' ! -name '*.src.rpm' | sort)
[[ ${#packages[@]} -eq 1 ]] || {
    echo "expected one Fedora 44 libfprint binary RPM under $rpm_root" >&2
    exit 2
}
mapfile -t runtime_packages < <(find "$rpm_root" -type f \
    -name 'libfprint-vfs495-runtime-1.94.10-5.vfs495.6.fc44.*.rpm' | sort)
[[ ${#runtime_packages[@]} -eq 1 ]] || {
    echo "expected one Fedora 44 VFS495 runtime RPM under $rpm_root" >&2
    exit 2
}
packages[0]=$(readlink -f "${packages[0]}")
runtime_packages[0]=$(readlink -f "${runtime_packages[0]}")

"${host[@]}" test -r /etc/vfs495/runtime.conf || {
    echo "stage and validate /etc/vfs495/runtime.conf before deployment" >&2
    exit 2
}

"${host[@]}" rpm-ostree status
"${host[@]}" sudo rpm-ostree override replace \
    --install "${runtime_packages[0]}" "${packages[0]}"
echo "A new deployment is staged. Reboot to use it."
echo "Rollback command: tools/rollback-fedora-44-override.sh"
