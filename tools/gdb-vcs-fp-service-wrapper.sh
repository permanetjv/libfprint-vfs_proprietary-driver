#!/bin/sh
set -eu

compat=${VFS495_SERVICE_RAW_HASH_COMPAT_ENABLED:-0}
case $compat in
    0|1) ;;
    *)
        echo "invalid VFS495 service compatibility mode" >&2
        exit 2
        ;;
esac

exec /opt/bin/gdb \
    --batch \
    -ex "set \$vfs495_raw_hash_compat = $compat" \
    -x /opt/bin/gdb-vcs-fp-service.commands \
    --args /opt/vendor/usr/bin/vcsFPService \
    1>&2
