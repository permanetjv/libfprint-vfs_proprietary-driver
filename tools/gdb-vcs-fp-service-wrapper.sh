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
no_ssl_compat=${VFS495_SERVICE_NO_SSL_COMPAT_ENABLED:-0}
case $no_ssl_compat in
    0|1) ;;
    *)
        echo "invalid VFS495 service no-SSL compatibility mode" >&2
        exit 2
        ;;
esac
flex_id_compat=${VFS495_SERVICE_FLEX_ID_COMPAT_ENABLED:-0}
case $flex_id_compat in
    0|1) ;;
    *)
        echo "invalid VFS495 service Flex-ID compatibility mode" >&2
        exit 2
        ;;
esac

exec /opt/bin/gdb \
    --batch \
    -ex "set \$vfs495_raw_hash_compat = $compat" \
    -ex "set \$vfs495_no_ssl_compat = $no_ssl_compat" \
    -ex "set \$vfs495_flex_id_compat = $flex_id_compat" \
    -x /opt/bin/gdb-vcs-fp-service.commands \
    --args /opt/vendor/usr/bin/vcsFPService \
    1>&2
