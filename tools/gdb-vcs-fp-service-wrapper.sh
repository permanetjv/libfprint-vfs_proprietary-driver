#!/bin/sh
set -eu

exec /opt/bin/gdb \
    --batch \
    -x /opt/bin/gdb-vcs-fp-service.commands \
    --args /opt/vendor/usr/bin/vcsFPService \
    1>&2
