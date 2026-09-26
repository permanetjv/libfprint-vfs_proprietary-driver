#!/bin/bash
set -euo pipefail

usage() {
    echo "usage: $0 service|helper|initializer|stack [arguments...]" >&2
    exit 2
}

require_ac_power() {
    local supply
    for supply in /sys/class/power_supply/*; do
        [[ -r $supply/type && -r $supply/online ]] || continue
        [[ $(<"$supply/type") == Mains ]] || continue
        if [[ $(<"$supply/online") == 1 ]]; then
            return 0
        fi
    done
    echo "refusing security-state changes without connected AC power" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
component=$1
shift

: "${VFS495_VENDOR_ROOT:?set VFS495_VENDOR_ROOT to the extracted vendor RPM root}"
: "${VFS495_OPENSSL_ROOT:?set VFS495_OPENSSL_ROOT to the extracted OpenSSL 0.9.8 RPM root}"
: "${VFS495_LIBUSB_ROOT:?set VFS495_LIBUSB_ROOT to the extracted libusb-compat RPM root}"
: "${VFS495_STATE_ROOT:?set VFS495_STATE_ROOT to a private writable state directory}"
: "${VFS495_USB_DEVICE:?set VFS495_USB_DEVICE to the VFS495 USB device node}"
: "${VFS495_USB_SCOPE:=node}"

if [[ ! $VFS495_USB_DEVICE =~ ^/dev/bus/usb/[0-9]{3}/[0-9]{3}$ ]] ||
   [[ ! -c $VFS495_USB_DEVICE ]] ||
   [[ $(stat -c %t "$VFS495_USB_DEVICE") != bd ]]; then
    echo "refusing unexpected USB device: $VFS495_USB_DEVICE" >&2
    exit 2
fi
usb_bus_dir=${VFS495_USB_DEVICE%/*}
usb_major_hex=$(stat -c %t "$VFS495_USB_DEVICE")
usb_minor_hex=$(stat -c %T "$VFS495_USB_DEVICE")
usb_sysfs=/sys/dev/char/$((16#$usb_major_hex)):$((16#$usb_minor_hex))
if [[ ! -r $usb_sysfs/idVendor || ! -r $usb_sysfs/idProduct ]] ||
   [[ $(<"$usb_sysfs/idVendor") != 138a ]] ||
   [[ $(<"$usb_sysfs/idProduct") != 003f ]]; then
    echo "refusing non-VFS495 USB device: $VFS495_USB_DEVICE" >&2
    exit 2
fi

case "$VFS495_USB_SCOPE" in
    node)
        usb_bwrap_args=(
            --dir /dev/bus
            --dir /dev/bus/usb
            --dir "$usb_bus_dir"
            --dev-bind "$VFS495_USB_DEVICE" "$VFS495_USB_DEVICE"
        )
        ;;
    bus)
        if [[ $EUID -eq 0 ]]; then
            echo "refusing bus-wide USB visibility for a root process" >&2
            exit 2
        fi
        usb_bwrap_args=(
            --dir /dev/bus
            --dev-bind /dev/bus/usb /dev/bus/usb
        )
        ;;
    mirror)
        : "${VFS495_USB_MIRROR:=/dev/vfs495-usb}"
        [[ -d $VFS495_USB_MIRROR ]] || {
            echo "$VFS495_USB_MIRROR mirror is not available" >&2
            exit 2
        }
        usb_bwrap_args=(
            --dir /dev/bus
            --dev-bind "$VFS495_USB_MIRROR" /dev/bus/usb
        )
        ;;
    *)
        echo "VFS495_USB_SCOPE must be 'node', 'mirror', or 'bus'" >&2
        exit 2
        ;;
esac

case "$component" in
    service)
        executable=/opt/vendor/usr/bin/vcsFPService
        ;;
    helper)
        : "${VFS495_CAPTURE_HELPER:?set VFS495_CAPTURE_HELPER to the built capture helper}"
        executable=/opt/bin/capture-helper
        ;;
    initializer)
        executable=/opt/vendor/usr/sbin/validity-sensor
        ;;
    stack)
        : "${VFS495_CAPTURE_HELPER:?set VFS495_CAPTURE_HELPER to the built capture helper}"
        : "${VFS495_STACK_SUPERVISOR:?set VFS495_STACK_SUPERVISOR to the stack supervisor script}"
        executable=/opt/bin/bash
        ;;
    *)
        usage
        ;;
esac

install -d -m 0700 \
    "$VFS495_STATE_ROOT/tmp" \
    "$VFS495_STATE_ROOT/run"

persistent_data=$VFS495_STATE_ROOT/ValidityPersistentData
if [[ -e $persistent_data ]]; then
    if [[ ! -f $persistent_data || -L $persistent_data ]]; then
        echo "$persistent_data must be a regular, non-symlink file" >&2
        exit 2
    fi
    chmod 0600 "$persistent_data"
else
    install -m 0600 /dev/null "$persistent_data"
fi

network_bwrap_args=(--unshare-net)
udev_bwrap_args=()
if [[ ${VFS495_USE_HOST_NETLINK:-} == 1 ]]; then
    [[ $component == initializer ]] || {
        echo "VFS495_USE_HOST_NETLINK is supported only for the initializer" >&2
        exit 2
    }
    [[ -d /run/udev ]] || {
        echo "/run/udev is required for initializer device rediscovery" >&2
        exit 2
    }
    network_bwrap_args=()
    udev_bwrap_args=(
        --dir /run/udev
        --ro-bind /run/udev /run/udev
    )
fi

bwrap_args=(
    "${network_bwrap_args[@]}"
    --unshare-pid
    --unshare-ipc
    --new-session
    --die-with-parent
    --cap-drop ALL
    --ro-bind / /
    --proc /proc
    --dev /dev
    "${usb_bwrap_args[@]}"
    --bind "$VFS495_STATE_ROOT/tmp" /tmp
    --bind "$VFS495_STATE_ROOT/run" /run
    "${udev_bwrap_args[@]}"
    --tmpfs /etc
    --bind "$persistent_data" /etc/ValidityPersistentData
    --tmpfs /opt
    --dir /opt/vendor
    --dir /opt/openssl
    --dir /opt/libusb
    --dir /opt/bin
    --ro-bind "$VFS495_VENDOR_ROOT" /opt/vendor
    --tmpfs /usr/bin
    --ro-bind /usr/bin/bash /usr/bin/sh
    --ro-bind /usr/bin/rm /usr/bin/rm
    --ro-bind /usr/bin/pidof /usr/bin/pidof
    --ro-bind "$VFS495_VENDOR_ROOT/usr/sbin/HPUsbVFS.img" /usr/bin/HPUsbVFS.img
    --ro-bind "$VFS495_VENDOR_ROOT/usr/sbin/HPUsbVFS471.img" /usr/bin/HPUsbVFS471.img
    --ro-bind "$VFS495_VENDOR_ROOT/usr/sbin/HPUsbVFS491.img" /usr/bin/HPUsbVFS491.img
    --ro-bind "$VFS495_VENDOR_ROOT/usr/sbin/HPUsbVFS495.img" /usr/bin/HPUsbVFS495.img
    --ro-bind "$VFS495_OPENSSL_ROOT" /opt/openssl
    --ro-bind "$VFS495_LIBUSB_ROOT" /opt/libusb
)
runtime_library_path=/opt/vendor/usr/lib64:/opt/openssl/usr/lib64:/opt/libusb/usr/lib64

if [[ -n ${VFS495_SERVICE_GDB_PATH:-} ]]; then
    [[ $component == stack ]] || {
        echo "VFS495_SERVICE_GDB_PATH is supported only for the stack" >&2
        exit 2
    }
    [[ -x $VFS495_SERVICE_GDB_PATH ]] || {
        echo "VFS495_SERVICE_GDB_PATH is not executable" >&2
        exit 2
    }
    service_gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-vcs-fp-service.commands
    service_gdb_wrapper=$(dirname "${BASH_SOURCE[0]}")/gdb-vcs-fp-service-wrapper.sh
    [[ -f $service_gdb_commands && -x $service_gdb_wrapper ]] || {
        echo "vcsFPService GDB support files are missing" >&2
        exit 2
    }
    bwrap_args+=(
        --ro-bind "$service_gdb_wrapper" /opt/bin/vcsFPService-gdb
        --ro-bind "$service_gdb_commands" /opt/bin/gdb-vcs-fp-service.commands
    )
    raw_hash_compat=${VFS495_SERVICE_RAW_HASH_COMPAT:-}
    if [[ -n $raw_hash_compat ]]; then
        require_ac_power
        expected_ack=I_ACCEPT_VFS495_RAW_HASH_CHECK_BYPASS
        if [[ $raw_hash_compat != "$expected_ack" ]]; then
            echo "refusing RAW-hash compatibility without the exact acknowledgement token" >&2
            exit 2
        fi
        : "${VFS495_SERVICE_EXPECTED_SHA256:?set the audited service SHA-256}"
        if [[ ! $VFS495_SERVICE_EXPECTED_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
            echo "VFS495_SERVICE_EXPECTED_SHA256 must be 64 lowercase hex characters" >&2
            exit 2
        fi
        actual_service_sha256=$(sha256sum \
            "$VFS495_VENDOR_ROOT/usr/bin/vcsFPService" | awk '{print $1}')
        if [[ $actual_service_sha256 != "$VFS495_SERVICE_EXPECTED_SHA256" ]]; then
            echo "refusing RAW-hash compatibility with an unaudited service binary" >&2
            exit 2
        fi
        if [[ $VFS495_USB_SCOPE != mirror ]]; then
            echo "RAW-hash compatibility requires the re-enumeration-safe USB mirror" >&2
            exit 2
        fi
        : "${VFS495_SERVICE_MIRROR_MONITOR_PID:?set the live USB mirror monitor PID}"
        if [[ ! $VFS495_SERVICE_MIRROR_MONITOR_PID =~ ^[1-9][0-9]*$ ]] ||
           ! kill -0 "$VFS495_SERVICE_MIRROR_MONITOR_PID" 2>/dev/null; then
            echo "refusing RAW-hash compatibility without a live USB mirror monitor" >&2
            exit 2
        fi
        mirrored_usb_device=$VFS495_USB_MIRROR${VFS495_USB_DEVICE#/dev/bus/usb}
        if [[ ! -c $mirrored_usb_device ]] ||
           [[ $(stat -c %t:%T "$mirrored_usb_device") != \
              $(stat -c %t:%T "$VFS495_USB_DEVICE") ]]; then
            echo "refusing RAW-hash compatibility with a stale USB mirror device" >&2
            exit 2
        fi
        bwrap_args+=(--setenv VFS495_SERVICE_RAW_HASH_COMPAT_ENABLED 1)
    fi
    no_ssl_compat=${VFS495_SERVICE_NO_SSL_COMPAT:-}
    if [[ -n $no_ssl_compat ]]; then
        if [[ $raw_hash_compat != I_ACCEPT_VFS495_RAW_HASH_CHECK_BYPASS ]]; then
            echo "VFS495 no-SSL compatibility also requires RAW-hash compatibility" >&2
            exit 2
        fi
        expected_ack=I_ACCEPT_VFS495_VENDOR_NO_SSL_MODE
        if [[ $no_ssl_compat != "$expected_ack" ]]; then
            echo "refusing no-SSL compatibility without the exact acknowledgement token" >&2
            exit 2
        fi
        bwrap_args+=(--setenv VFS495_SERVICE_NO_SSL_COMPAT_ENABLED 1)
    fi
    flex_id_compat=${VFS495_SERVICE_FLEX_ID_COMPAT:-}
    if [[ -n $flex_id_compat ]]; then
        # Flex ID selection is independent of the transport security mode.
        # Require the same audited service and exact-device guards supplied by
        # RAW-hash compatibility, but permit either normal SSL or -nossl.
        if [[ $raw_hash_compat != I_ACCEPT_VFS495_RAW_HASH_CHECK_BYPASS ]]; then
            echo "VFS495 Flex-ID compatibility also requires RAW-hash compatibility" >&2
            exit 2
        fi
        expected_ack=I_ACCEPT_VFS495_FLEX_ID_0X83
        if [[ $flex_id_compat != "$expected_ack" ]]; then
            echo "refusing Flex-ID compatibility without the exact acknowledgement token" >&2
            exit 2
        fi
        bwrap_args+=(--setenv VFS495_SERVICE_FLEX_ID_COMPAT_ENABLED 1)
    fi
    if [[ -z ${VFS495_CAPTURE_GDB_PATH:-} ]]; then
        bwrap_args+=(--ro-bind "$VFS495_SERVICE_GDB_PATH" /opt/bin/gdb)
        if [[ -n ${VFS495_SERVICE_GDB_LIB_ROOT:-} ]]; then
            [[ -d $VFS495_SERVICE_GDB_LIB_ROOT ]] || {
                echo "VFS495_SERVICE_GDB_LIB_ROOT is not a directory" >&2
                exit 2
            }
            bwrap_args+=(--ro-bind "$VFS495_SERVICE_GDB_LIB_ROOT" /opt/gdb-libs)
            runtime_library_path=/opt/gdb-libs:$runtime_library_path
        fi
    elif [[ $VFS495_SERVICE_GDB_PATH != "$VFS495_CAPTURE_GDB_PATH" ]]; then
        echo "service and capture GDB paths must match when both traces are enabled" >&2
        exit 2
    fi
fi

if [[ $component == helper || $component == stack ]]; then
    if [[ -n ${VFS495_CAPTURE_GDB_PATH:-} ]]; then
        [[ -x $VFS495_CAPTURE_GDB_PATH ]] || {
            echo "VFS495_CAPTURE_GDB_PATH is not executable" >&2
            exit 2
        }
        capture_gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-capture-helper.commands
        capture_gdb_wrapper=$(dirname "${BASH_SOURCE[0]}")/gdb-capture-helper-wrapper.sh
        [[ -f $capture_gdb_commands && -x $capture_gdb_wrapper ]] || {
            echo "capture-helper GDB support files are missing" >&2
            exit 2
        }
        bwrap_args+=(
            --ro-bind "$VFS495_CAPTURE_HELPER" /opt/bin/capture-helper-real
            --ro-bind "$capture_gdb_wrapper" /opt/bin/capture-helper
            --ro-bind "$VFS495_CAPTURE_GDB_PATH" /opt/bin/gdb
            --ro-bind "$capture_gdb_commands" /opt/bin/gdb-capture-helper.commands
        )
        if [[ -n ${VFS495_CAPTURE_GDB_LIB_ROOT:-} ]]; then
            [[ -d $VFS495_CAPTURE_GDB_LIB_ROOT ]] || {
                echo "VFS495_CAPTURE_GDB_LIB_ROOT is not a directory" >&2
                exit 2
            }
            bwrap_args+=(--ro-bind "$VFS495_CAPTURE_GDB_LIB_ROOT" /opt/gdb-libs)
            runtime_library_path=/opt/gdb-libs:$runtime_library_path
        fi
    else
        bwrap_args+=(--ro-bind "$VFS495_CAPTURE_HELPER" /opt/bin/capture-helper)
    fi
fi

if [[ $component == stack ]]; then
    bwrap_args+=(
        --ro-bind "$VFS495_STACK_SUPERVISOR" /opt/bin/stack-supervisor
        --ro-bind /usr/bin/bash /opt/bin/bash
        --ro-bind /usr/bin/sleep /opt/bin/sleep
    )
    set -- /opt/bin/stack-supervisor "$@"
fi

if [[ -n ${VFS495_STRACE_PATH:-} ]]; then
    [[ -x $VFS495_STRACE_PATH ]] || {
        echo "VFS495_STRACE_PATH is not executable" >&2
        exit 2
    }
    bwrap_args+=(--ro-bind "$VFS495_STRACE_PATH" /opt/bin/strace)
    if [[ $component != stack ]]; then
        traced_executable=$executable
        executable=/opt/bin/strace
        set -- \
            -ff -tt -s 64 \
            -e 'trace=process,ipc,file,network,signal,ioctl,poll,ppoll,select,pselect6,clock_nanosleep' \
            -o "/tmp/${component}.strace" \
            "$traced_executable" "$@"
    fi
fi

if [[ -n ${VFS495_GDB_PATH:-} ]]; then
    [[ $component == initializer ]] || {
        echo "VFS495_GDB_PATH is supported only for the initializer" >&2
        exit 2
    }
    [[ -x $VFS495_GDB_PATH ]] || {
        echo "VFS495_GDB_PATH is not executable" >&2
        exit 2
    }
    bwrap_args+=(--ro-bind "$VFS495_GDB_PATH" /opt/bin/gdb)
    if [[ -n ${VFS495_GDB_LIB_ROOT:-} ]]; then
        [[ -d $VFS495_GDB_LIB_ROOT ]] || {
            echo "VFS495_GDB_LIB_ROOT is not a directory" >&2
            exit 2
        }
        bwrap_args+=(--ro-bind "$VFS495_GDB_LIB_ROOT" /opt/gdb-libs)
        runtime_library_path=/opt/gdb-libs:$runtime_library_path
    fi
    debugged_executable=$executable
    executable=/opt/bin/gdb
    readonly_command=${VFS495_GDB_READONLY_COMMAND:-}
    trace_setowner=${VFS495_GDB_TRACE_SETOWNER_RESULT:-}
    provision_vfs495=${VFS495_GDB_PROVISION_VFS495:-}
    setowner_cache_compat=${VFS495_GDB_SETOWNER_CACHE_COMPAT:-}
    setowner_aes_keys=${VFS495_GDB_SETOWNER_AES_KEYS:-}
    setowner_full_keys=${VFS495_GDB_SETOWNER_FULL_KEYS:-}
    setowner_sim=${VFS495_GDB_SETOWNER_SIM:-}
    selected_gdb_modes=0
    [[ -n $readonly_command ]] && ((selected_gdb_modes += 1))
    [[ $trace_setowner == 1 ]] && ((selected_gdb_modes += 1))
    [[ -n $provision_vfs495 ]] && ((selected_gdb_modes += 1))
    [[ -n $setowner_cache_compat ]] && ((selected_gdb_modes += 1))
    [[ -n $setowner_aes_keys ]] && ((selected_gdb_modes += 1))
    [[ -n $setowner_full_keys ]] && ((selected_gdb_modes += 1))
    [[ -n $setowner_sim ]] && ((selected_gdb_modes += 1))
    if ((selected_gdb_modes > 1)); then
        echo "choose only one read-only, setowner-trace, cache-compat, AES-key ownership, full-key ownership, simulated-patch ownership, or provisioning GDB mode" >&2
        exit 2
    fi
    if [[ -n $trace_setowner && $trace_setowner != 1 ]]; then
        echo "VFS495_GDB_TRACE_SETOWNER_RESULT must be '1' when set" >&2
        exit 2
    fi
    if [[ -n $provision_vfs495 ]]; then
        require_ac_power
        expected_ack=I_UNDERSTAND_THIS_WRITES_SENSOR_OTP
        if [[ $provision_vfs495 != "$expected_ack" ]]; then
            echo "refusing provisioning without the exact OTP acknowledgement token" >&2
            exit 2
        fi
        if [[ $# -ne 2 || $1 != setowner || $2 != -doinit ]]; then
            echo "provisioning requires exactly: initializer setowner -doinit" >&2
            exit 2
        fi
        : "${VFS495_PROVISION_EXPECTED_INITIALIZER_SHA256:?set the audited initializer SHA-256}"
        if [[ ! $VFS495_PROVISION_EXPECTED_INITIALIZER_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
            echo "VFS495_PROVISION_EXPECTED_INITIALIZER_SHA256 must be 64 lowercase hex characters" >&2
            exit 2
        fi
        actual_initializer_sha256=$(sha256sum \
            "$VFS495_VENDOR_ROOT/usr/sbin/validity-sensor" | awk '{print $1}')
        if [[ $actual_initializer_sha256 != "$VFS495_PROVISION_EXPECTED_INITIALIZER_SHA256" ]]; then
            echo "refusing provisioning with an unaudited initializer binary" >&2
            exit 2
        fi
        if [[ $VFS495_USB_SCOPE != mirror ]]; then
            echo "provisioning requires the re-enumeration-safe USB mirror" >&2
            exit 2
        fi
        : "${VFS495_PROVISION_MIRROR_MONITOR_PID:?set the live USB mirror monitor PID}"
        if [[ ! $VFS495_PROVISION_MIRROR_MONITOR_PID =~ ^[1-9][0-9]*$ ]] ||
           ! kill -0 "$VFS495_PROVISION_MIRROR_MONITOR_PID" 2>/dev/null; then
            echo "refusing provisioning without a live USB mirror monitor" >&2
            exit 2
        fi
        mirrored_usb_device=$VFS495_USB_MIRROR${VFS495_USB_DEVICE#/dev/bus/usb}
        if [[ ! -c $mirrored_usb_device ]] ||
           [[ $(stat -c %t:%T "$mirrored_usb_device") != \
              $(stat -c %t:%T "$VFS495_USB_DEVICE") ]]; then
            echo "refusing provisioning with a stale USB mirror device" >&2
            exit 2
        fi
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-provision-vfs495.commands
    elif [[ -n $setowner_sim ]]; then
        require_ac_power
        expected_ack=I_ACCEPT_VFS495_VOLATILE_TEST_PATCH_OWNERSHIP
        if [[ $setowner_sim != "$expected_ack" ]]; then
            echo "refusing simulated-patch ownership without the exact acknowledgement token" >&2
            exit 2
        fi
        if [[ $# -ne 2 || $1 != setowner_sim || $2 != -doinit ]]; then
            echo "simulated-patch ownership requires exactly: initializer setowner_sim -doinit" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256:?set the audited initializer SHA-256}"
        if [[ ! $VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
            echo "VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256 must be 64 lowercase hex characters" >&2
            exit 2
        fi
        actual_initializer_sha256=$(sha256sum \
            "$VFS495_VENDOR_ROOT/usr/sbin/validity-sensor" | awk '{print $1}')
        if [[ $actual_initializer_sha256 != "$VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256" ]]; then
            echo "refusing simulated-patch ownership with an unaudited initializer binary" >&2
            exit 2
        fi
        if [[ $VFS495_USB_SCOPE != mirror ]]; then
            echo "simulated-patch ownership requires the re-enumeration-safe USB mirror" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_MIRROR_MONITOR_PID:?set the live USB mirror monitor PID}"
        if [[ ! $VFS495_SETOWNER_MIRROR_MONITOR_PID =~ ^[1-9][0-9]*$ ]] ||
           ! kill -0 "$VFS495_SETOWNER_MIRROR_MONITOR_PID" 2>/dev/null; then
            echo "refusing simulated-patch ownership without a live USB mirror monitor" >&2
            exit 2
        fi
        mirrored_usb_device=$VFS495_USB_MIRROR${VFS495_USB_DEVICE#/dev/bus/usb}
        if [[ ! -c $mirrored_usb_device ]] ||
           [[ $(stat -c %t:%T "$mirrored_usb_device") != \
              $(stat -c %t:%T "$VFS495_USB_DEVICE") ]]; then
            echo "refusing simulated-patch ownership with a stale USB mirror device" >&2
            exit 2
        fi
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-setowner-sim.commands
    elif [[ -n $setowner_full_keys ]]; then
        require_ac_power
        expected_ack=I_ACCEPT_VFS495_FULL_TEST_KEY_OWNERSHIP
        if [[ $setowner_full_keys != "$expected_ack" ]]; then
            echo "refusing full-key ownership without the exact acknowledgement token" >&2
            exit 2
        fi
        if [[ $# -ne 2 || $1 != setowner || $2 != -doinit ]]; then
            echo "full-key ownership requires exactly: initializer setowner -doinit" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256:?set the audited initializer SHA-256}"
        if [[ ! $VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
            echo "VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256 must be 64 lowercase hex characters" >&2
            exit 2
        fi
        actual_initializer_sha256=$(sha256sum \
            "$VFS495_VENDOR_ROOT/usr/sbin/validity-sensor" | awk '{print $1}')
        if [[ $actual_initializer_sha256 != "$VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256" ]]; then
            echo "refusing full-key ownership with an unaudited initializer binary" >&2
            exit 2
        fi
        if [[ $VFS495_USB_SCOPE != mirror ]]; then
            echo "full-key ownership requires the re-enumeration-safe USB mirror" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_MIRROR_MONITOR_PID:?set the live USB mirror monitor PID}"
        if [[ ! $VFS495_SETOWNER_MIRROR_MONITOR_PID =~ ^[1-9][0-9]*$ ]] ||
           ! kill -0 "$VFS495_SETOWNER_MIRROR_MONITOR_PID" 2>/dev/null; then
            echo "refusing full-key ownership without a live USB mirror monitor" >&2
            exit 2
        fi
        mirrored_usb_device=$VFS495_USB_MIRROR${VFS495_USB_DEVICE#/dev/bus/usb}
        if [[ ! -c $mirrored_usb_device ]] ||
           [[ $(stat -c %t:%T "$mirrored_usb_device") != \
              $(stat -c %t:%T "$VFS495_USB_DEVICE") ]]; then
            echo "refusing full-key ownership with a stale USB mirror device" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_KEYS_ROOT:?set the private ownership-key directory}"
        if [[ ! -d $VFS495_SETOWNER_KEYS_ROOT || -L $VFS495_SETOWNER_KEYS_ROOT ]]; then
            echo "ownership-key root must be a non-symlink directory" >&2
            exit 2
        fi
        declare -A expected_key_sizes=(
            [ha_pub_mod.bin]=256
            [ha_priv_blob.bin]=1184
            [s_priv_exp.bin]=256
            [s_priv_mod.bin]=256
            [cik.bin]=32
            [cios.bin]=32
        )
        for key_name in "${!expected_key_sizes[@]}"; do
            key_path=$VFS495_SETOWNER_KEYS_ROOT/$key_name
            if [[ ! -f $key_path || -L $key_path ]] ||
               [[ $(stat -c %s "$key_path") != "${expected_key_sizes[$key_name]}" ]]; then
                echo "$key_path must be a regular, non-symlink ${expected_key_sizes[$key_name]}-byte file" >&2
                exit 2
            fi
            if ((8#$(stat -c %a "$key_path") & 077)); then
                echo "$key_path must not grant group or other permissions" >&2
                exit 2
            fi
        done
        bwrap_args+=(
            --ro-bind "$VFS495_SETOWNER_KEYS_ROOT" /opt/ownership-keys
            --chdir /opt/ownership-keys
        )
        # Supply one inert raw argv slot. The debugger validates the processed
        # argc before repointing argv[1..4] at audited in-binary option strings.
        set -- "$@" __vfs495_full_key_pointer_slot
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-setowner-full-keys.commands
    elif [[ -n $setowner_aes_keys ]]; then
        require_ac_power
        expected_ack=I_ACCEPT_VFS495_AES_OWNERSHIP_WITH_NEW_KEYS
        if [[ $setowner_aes_keys != "$expected_ack" ]]; then
            echo "refusing AES-key ownership without the exact acknowledgement token" >&2
            exit 2
        fi
        if [[ $# -ne 2 || $1 != setowner || $2 != -doinit ]]; then
            echo "AES-key ownership requires exactly: initializer setowner -doinit" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256:?set the audited initializer SHA-256}"
        if [[ ! $VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
            echo "VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256 must be 64 lowercase hex characters" >&2
            exit 2
        fi
        actual_initializer_sha256=$(sha256sum \
            "$VFS495_VENDOR_ROOT/usr/sbin/validity-sensor" | awk '{print $1}')
        if [[ $actual_initializer_sha256 != "$VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256" ]]; then
            echo "refusing AES-key ownership with an unaudited initializer binary" >&2
            exit 2
        fi
        if [[ $VFS495_USB_SCOPE != mirror ]]; then
            echo "AES-key ownership requires the re-enumeration-safe USB mirror" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_MIRROR_MONITOR_PID:?set the live USB mirror monitor PID}"
        if [[ ! $VFS495_SETOWNER_MIRROR_MONITOR_PID =~ ^[1-9][0-9]*$ ]] ||
           ! kill -0 "$VFS495_SETOWNER_MIRROR_MONITOR_PID" 2>/dev/null; then
            echo "refusing AES-key ownership without a live USB mirror monitor" >&2
            exit 2
        fi
        mirrored_usb_device=$VFS495_USB_MIRROR${VFS495_USB_DEVICE#/dev/bus/usb}
        if [[ ! -c $mirrored_usb_device ]] ||
           [[ $(stat -c %t:%T "$mirrored_usb_device") != \
              $(stat -c %t:%T "$VFS495_USB_DEVICE") ]]; then
            echo "refusing AES-key ownership with a stale USB mirror device" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_KEYS_ROOT:?set the private AES ownership-key directory}"
        if [[ ! -d $VFS495_SETOWNER_KEYS_ROOT || -L $VFS495_SETOWNER_KEYS_ROOT ]]; then
            echo "AES ownership-key root must be a non-symlink directory" >&2
            exit 2
        fi
        for key_name in cik.bin cios.bin; do
            key_path=$VFS495_SETOWNER_KEYS_ROOT/$key_name
            if [[ ! -f $key_path || -L $key_path ]] ||
               [[ $(stat -c %s "$key_path") != 32 ]]; then
                echo "$key_path must be a regular, non-symlink 32-byte file" >&2
                exit 2
            fi
            if ((8#$(stat -c %a "$key_path") & 077)); then
                echo "$key_path must not grant group or other permissions" >&2
                exit 2
            fi
        done
        bwrap_args+=(
            --ro-bind "$VFS495_SETOWNER_KEYS_ROOT" /opt/ownership-keys
            --chdir /opt/ownership-keys
        )
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-setowner-aes-keys.commands
    elif [[ -n $setowner_cache_compat ]]; then
        require_ac_power
        expected_ack=I_CONFIRMED_RAW_STATE_2_AND_ACCEPT_OWNERSHIP
        if [[ $setowner_cache_compat != "$expected_ack" ]]; then
            echo "refusing SetOwner cache compatibility without the exact acknowledgement token" >&2
            exit 2
        fi
        if [[ $# -ne 2 || $1 != setowner || $2 != -doinit ]]; then
            echo "SetOwner cache compatibility requires exactly: initializer setowner -doinit" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256:?set the audited initializer SHA-256}"
        if [[ ! $VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
            echo "VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256 must be 64 lowercase hex characters" >&2
            exit 2
        fi
        actual_initializer_sha256=$(sha256sum \
            "$VFS495_VENDOR_ROOT/usr/sbin/validity-sensor" | awk '{print $1}')
        if [[ $actual_initializer_sha256 != "$VFS495_SETOWNER_EXPECTED_INITIALIZER_SHA256" ]]; then
            echo "refusing SetOwner cache compatibility with an unaudited initializer binary" >&2
            exit 2
        fi
        if [[ $VFS495_USB_SCOPE != mirror ]]; then
            echo "SetOwner cache compatibility requires the re-enumeration-safe USB mirror" >&2
            exit 2
        fi
        : "${VFS495_SETOWNER_MIRROR_MONITOR_PID:?set the live USB mirror monitor PID}"
        if [[ ! $VFS495_SETOWNER_MIRROR_MONITOR_PID =~ ^[1-9][0-9]*$ ]] ||
           ! kill -0 "$VFS495_SETOWNER_MIRROR_MONITOR_PID" 2>/dev/null; then
            echo "refusing SetOwner cache compatibility without a live USB mirror monitor" >&2
            exit 2
        fi
        mirrored_usb_device=$VFS495_USB_MIRROR${VFS495_USB_DEVICE#/dev/bus/usb}
        if [[ ! -c $mirrored_usb_device ]] ||
           [[ $(stat -c %t:%T "$mirrored_usb_device") != \
              $(stat -c %t:%T "$VFS495_USB_DEVICE") ]]; then
            echo "refusing SetOwner cache compatibility with a stale USB mirror device" >&2
            exit 2
        fi
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-setowner-cache-compat.commands
    elif [[ $trace_setowner == 1 ]]; then
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-setowner-result.commands
    else
      case $readonly_command in
      sensorstat)
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-sensorstat.commands
        ;;
      get_ownership_info)
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-get-ownership-info.commands
        ;;
      getver)
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-get-version.commands
        ;;
      sslstat)
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-sslstat.commands
        ;;
      security_info)
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-security-info.commands
        ;;
      setowner_cache_preflight)
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-setowner-cache-preflight.commands
        ;;
      provision_vfs495_preflight)
        gdb_commands=$(dirname "${BASH_SOURCE[0]}")/gdb-provision-vfs495-preflight.commands
        ;;
      '')
        gdb_commands=
        ;;
      *)
        echo "unsupported read-only GDB command: $VFS495_GDB_READONLY_COMMAND" >&2
        exit 2
        ;;
      esac
    fi
    if [[ -n $gdb_commands ]]; then
        [[ -f $gdb_commands ]] || {
            echo "missing GDB command file: $gdb_commands" >&2
            exit 2
        }
        bwrap_args+=(--ro-bind "$gdb_commands" /opt/bin/gdb-commands)
        set -- \
            --batch \
            -x /opt/bin/gdb-commands \
            --args "$debugged_executable" "$@"
    else
        set -- \
            --batch \
            -ex 'set pagination off' \
            -ex 'set startup-with-shell off' \
            -ex 'break VFInitialize' \
            -ex 'break StackInit' \
            -ex 'break ProtInit' \
            -ex 'break OldInit' \
            -ex 'break vcsTestInitializeEx' \
            -ex 'break vcsTestInitialize' \
            -ex 'break usb_init' \
            -ex run \
            -ex 'thread apply all backtrace' \
            --args "$debugged_executable" "$@"
    fi
fi

exec /usr/bin/bwrap "${bwrap_args[@]}" \
    --setenv LD_LIBRARY_PATH "$runtime_library_path" \
    "$executable" "$@"
