#!/opt/bin/bash
set -euo pipefail

service_pid=
ready_timeout=${VFS495_SERVICE_READY_TIMEOUT:-20}

if [[ ! $ready_timeout =~ ^[1-9][0-9]*$ ]] || ((ready_timeout > 120)); then
    echo "VFS495_SERVICE_READY_TIMEOUT must be an integer from 1 through 120" >&2
    exit 64
fi

cleanup() {
    local attempt

    if [[ -n $service_pid ]] && kill -0 "$service_pid" 2>/dev/null; then
        kill -TERM "$service_pid" 2>/dev/null || true
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$service_pid" 2>/dev/null || break
            /opt/bin/sleep 0.1
        done
        if kill -0 "$service_pid" 2>/dev/null; then
            kill -KILL "$service_pid" 2>/dev/null || true
        fi
        wait "$service_pid" 2>/dev/null || true
    fi
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
if [[ -n ${VFS495_STRACE_PATH:-} ]]; then
    service_cmd=(/opt/bin/strace "${trace_args[@]}" -o /tmp/vcsFPService.strace "${service_cmd[@]}")
    helper_cmd=(/opt/bin/strace "${trace_args[@]}" -o /tmp/capture-helper.strace "${helper_cmd[@]}")
fi

"${service_cmd[@]}" &
service_pid=$!

for ((attempt = 0; attempt < ready_timeout * 10; attempt++)); do
    if [[ -e /tmp/vcsSemKey_ServiceReady ]]; then
        break
    fi
    if ! kill -0 "$service_pid" 2>/dev/null; then
        wait "$service_pid"
        echo "vcsFPService exited before becoming ready" >&2
        exit 1
    fi
    /opt/bin/sleep 0.1
done

if [[ ! -e /tmp/vcsSemKey_ServiceReady ]]; then
    echo "vcsFPService did not become ready within ${ready_timeout} seconds" >&2
    exit 1
fi

"${helper_cmd[@]}" "$@"
