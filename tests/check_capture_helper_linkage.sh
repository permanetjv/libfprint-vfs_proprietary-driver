#!/bin/bash
set -euo pipefail

[[ $# -eq 1 && -x $1 ]] || {
    echo "usage: $0 /path/to/vfs_proprietary-capture-helper" >&2
    exit 2
}

helper=$1

if readelf -d "$helper" | grep -Eq \
    'Shared library: \[(libtommath|libvfsFprintWrapper)\.so'; then
    echo "capture helper must load proprietary runtime dependencies only at runtime" >&2
    exit 1
fi

for symbol in \
    dlopen \
    dlsym; do
    readelf --dyn-syms --wide "$helper" | awk -v expected="$symbol" \
        '$7 == "UND" && ($8 == expected || $8 ~ ("^" expected "@")) { found = 1 }
         END { exit !found }'
done

for symbol in \
    mssAdaptiveMatcherOpen \
    mssCogentOpen \
    mssDpOpen \
    mssFingercellOpen; do
    readelf --dyn-syms --wide "$helper" | awk -v expected="$symbol" \
        '$5 == "GLOBAL" && $7 != "UND" && $8 == expected { found = 1 }
         END { exit !found }'
done
