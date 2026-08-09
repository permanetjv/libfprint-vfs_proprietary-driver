#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
distgit_root=${1:-/var/home/jake/Git/poly-homelab/.tmp/fedora-libfprint-distgit}
output_root=${2:-$repo_root/build/fedora-44}
spec=$repo_root/packaging/fedora/libfprint.spec
expected_distgit_commit=92d8aa1d4a5a756f8090cccf1fe903c025f7225f

if [[ -n $(git -C "$repo_root" status --porcelain --untracked-files=no) ]]; then
    echo "tracked fork files must be committed before building RPMs" >&2
    exit 2
fi

command -v fedpkg >/dev/null || {
    echo "fedpkg is required; install it with sudo dnf inside the toolbox" >&2
    exit 2
}
command -v rpmbuild >/dev/null || {
    echo "rpmbuild is required; install rpm-build with sudo dnf inside the toolbox" >&2
    exit 2
}

[[ -f $distgit_root/libfprint.spec && -f $distgit_root/sources ]] || {
    echo "not a Fedora libfprint dist-git checkout: $distgit_root" >&2
    exit 2
}
[[ $(git -C "$distgit_root" rev-parse HEAD) == "$expected_distgit_commit" ]] || {
    echo "Fedora dist-git must be pinned to $expected_distgit_commit" >&2
    exit 2
}
git -C "$distgit_root" diff --quiet
git -C "$distgit_root" diff --cached --quiet

vfs495_commit=$(sed -n 's/^%global vfs495_commit //p' "$spec")
[[ $vfs495_commit =~ ^[0-9a-f]{40}$ ]] || {
    echo "invalid vfs495_commit in $spec" >&2
    exit 2
}
git -C "$repo_root" cat-file -e "$vfs495_commit^{commit}"

mkdir -p "$output_root"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

(
    cd "$distgit_root"
    fedpkg sources
)

cp "$distgit_root/libfprint-v1.94.10.tar.gz" "$output_root/SOURCES/"
for patch in \
    2c7842c905147a2d127c1b168b2e9d43.patch \
    0001-doc-Include-Binary-buffer-I-O-section-for-the-byte-r.patch \
    0002-fpi-byte-writer-Add-APIs-to-write-and-get-GBytes.patch \
    0003-fpi-byte-reader-Add-support-to-read-and-get-peek-GBy.patch \
    0004-fpi-byte-reader-Add-support-to-read-to-a-static-buff.patch \
    0005-fpi-usb-transfer-Add-missing-definition-of-set_short.patch \
    0006-fpi-usb-transfer-Wrap-g_error_new-arguments.patch \
    egis_reader.patch; do
    cp "$distgit_root/$patch" "$output_root/SOURCES/"
done
cp "$repo_root/integration/libfprint-1.94.10.patch" \
    "$output_root/SOURCES/libfprint-vfs495-integration.patch"
cp "$spec" "$output_root/SPECS/"

archive="$output_root/SOURCES/libfprint-vfs495-port-$vfs495_commit.tar.gz"
git -C "$repo_root" archive \
    --format=tar.gz \
    --prefix="libfprint-vfs495-port-$vfs495_commit/" \
    "$vfs495_commit" \
    vfs_proprietary tests tools/raw-capture.py >"$archive"

rpmbuild -ba --quiet \
    --define "_topdir $output_root" \
    "$output_root/SPECS/$(basename "$spec")"

current_release=$(rpmspec -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec")
find "$output_root/RPMS" "$output_root/SRPMS" -type f \
    -name "*-$current_release*.rpm" -print | sort
