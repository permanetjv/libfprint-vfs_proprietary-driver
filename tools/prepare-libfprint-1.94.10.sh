#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${1:-$repo_root/libfprint}
driver_target=$source_root/libfprint/drivers/vfs_proprietary

[[ -f $source_root/meson.build && -f $source_root/meson_options.txt ]] || {
    echo "not a libfprint source tree: $source_root" >&2
    exit 2
}
git -C "$source_root" describe --tags --exact-match 2>/dev/null | grep -qx v1.94.10 || {
    echo "libfprint source must be exactly tag v1.94.10" >&2
    exit 2
}
git -C "$source_root" diff --quiet || {
    echo "libfprint source has tracked changes; refusing to patch it" >&2
    exit 2
}
[[ ! -e $driver_target ]] || {
    echo "driver target already exists: $driver_target" >&2
    exit 2
}

cp -a "$repo_root/vfs_proprietary" "$driver_target"
if ! git -C "$source_root" apply --check \
        "$repo_root/integration/libfprint-1.94.10.patch" ||
   ! git -C "$source_root" apply \
        "$repo_root/integration/libfprint-1.94.10.patch"; then
    echo "failed to apply the libfprint 1.94.10 integration patch" >&2
    exit 1
fi
