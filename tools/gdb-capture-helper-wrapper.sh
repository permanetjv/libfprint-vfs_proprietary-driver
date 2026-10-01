#!/usr/bin/sh
set -eu

exec /opt/bin/gdb \
    --batch \
    -x /opt/bin/gdb-capture-helper.commands \
    --args /opt/bin/capture-helper-real \
    1>&2
