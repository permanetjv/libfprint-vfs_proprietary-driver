#!/opt/bin/bash
set -euo pipefail

service_launcher_pid=
ready_timeout=${VFS495_SERVICE_READY_TIMEOUT:-20}

if [[ ! $ready_timeout =~ ^[1-9][0-9]*$ ]] || ((ready_timeout > 120)); then
    echo "VFS495_SERVICE_READY_TIMEOUT must be an integer from 1 through 120" >&2
    exit 64
fi

cleanup() {
    local attempt pid targets

    targets=$service_launcher_pid
    targets+=" $(/usr/bin/pidof vcsFPService 2>/dev/null || true)"
    for pid in $targets; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        targets=$(/usr/bin/pidof vcsFPService 2>/dev/null || true)
        [[ -z $targets ]] && break
        /opt/bin/sleep 0.1
    done
    for pid in $targets; do
        kill -KILL "$pid" 2>/dev/null || true
    done
    if [[ -n $service_launcher_pid ]]; then
        wait "$service_launcher_pid" 2>/dev/null || true
    fi
    /usr/bin/rm -f /tmp/vcsSemKey_* /tmp/CH_*
}
trap cleanup EXIT HUP INT TERM

trace_args=(
    -ff
    -tt
    -s 64
    -e 'trace=process,ipc,file,signal,ioctl,poll,ppoll,select,pselect6'
)
service_cmd=(/opt/vendor/usr/bin/vcsFPService)
helper_cmd=(/opt/bin/capture-helper)
if [[ -n ${VFS495_SERVICE_GDB_PATH:-} ]]; then
    service_cmd=(/opt/bin/vcsFPService-gdb)
fi
if [[ -n ${VFS495_STRACE_PATH:-} ]]; then
    service_cmd=(/opt/bin/strace "${trace_args[@]}" -o /tmp/vcsFPService.strace "${service_cmd[@]}")
    helper_cmd=(/opt/bin/strace "${trace_args[@]}" -o /tmp/capture-helper.strace "${helper_cmd[@]}")
fi

# The daemon's ready marker and channel files outlive a killed process because
# this isolated /tmp is persistent across diagnostic runs.  Never let a stale
# marker satisfy the readiness check for a newly starting daemon.
/usr/bin/rm -f /tmp/vcsSemKey_* /tmp/CH_*

"${service_cmd[@]}" &
service_launcher_pid=$!

for ((attempt = 0; attempt < ready_timeout * 10; attempt++)); do
    if [[ -e /tmp/vcsSemKey_ServiceReady ]]; then
        break
    fi
    if [[ -n $service_launcher_pid ]] && ! kill -0 "$service_launcher_pid" 2>/dev/null; then
        if wait "$service_launcher_pid"; then
            service_launcher_pid=
        else
            status=$?
            echo "vcsFPService launcher exited with status $status" >&2
            exit "$status"
        fi
        if [[ -z $(/usr/bin/pidof vcsFPService 2>/dev/null || true) ]]; then
            echo "vcsFPService exited without leaving its daemon running" >&2
            exit 1
        fi
    elif [[ -z $service_launcher_pid ]] &&
         [[ -z $(/usr/bin/pidof vcsFPService 2>/dev/null || true) ]]; then
        echo "vcsFPService daemon exited before becoming ready" >&2
        exit 1
    fi
    /opt/bin/sleep 0.1
done

if [[ ! -e /tmp/vcsSemKey_ServiceReady ]]; then
    echo "vcsFPService did not become ready within ${ready_timeout} seconds" >&2
    exit 1
fi

"${helper_cmd[@]}" "$@"
