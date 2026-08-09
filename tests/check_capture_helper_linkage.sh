#!/bin/bash
set -euo pipefail

[[ $# -eq 1 && -x $1 ]] || {
    echo "usage: $0 /path/to/vfs_proprietary-capture-helper" >&2
    exit 2
}

helper=$1

readelf -d "$helper" | grep -Eq \
    'Shared library: \[libtommath\.so(\.[0-9]+)*\]'

for symbol in \
    mssAdaptiveMatcherOpen \
    mssCogentOpen \
    mssDpOpen \
    mssFingercellOpen; do
    readelf --dyn-syms --wide "$helper" | awk -v expected="$symbol" \
        '$5 == "GLOBAL" && $7 != "UND" && $8 == expected { found = 1 }
         END { exit !found }'
done
