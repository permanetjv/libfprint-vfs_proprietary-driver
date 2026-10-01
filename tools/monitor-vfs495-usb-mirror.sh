#!/bin/bash
set -euo pipefail

mirror_root=${1:-/dev/vfs495-usb}

if [[ $EUID -ne 0 ]]; then
    echo "the VFS495 USB mirror monitor must run as root" >&2
    exit 2
fi
if [[ $mirror_root != /dev/vfs495-usb ]]; then
    echo "refusing unexpected USB mirror root: $mirror_root" >&2
    exit 2
fi

install -d -m 0755 "$mirror_root"
active_key=

while :; do
    sensor_path=
    for candidate in /sys/bus/usb/devices/*; do
        [[ -r $candidate/idVendor && -r $candidate/idProduct ]] || continue
        read -r vendor_id <"$candidate/idVendor" || continue
        read -r product_id <"$candidate/idProduct" || continue
        if [[ $vendor_id == 138a && $product_id == 003f ]]; then
            sensor_path=$candidate
            break
        fi
    done

    source_node=
    bus=
    device=
    if [[ -n $sensor_path && -r $sensor_path/busnum && -r $sensor_path/devnum ]]; then
        read -r busnum <"$sensor_path/busnum" || busnum=
        read -r devnum <"$sensor_path/devnum" || devnum=
        if [[ $busnum =~ ^[0-9]+$ && $devnum =~ ^[0-9]+$ ]]; then
            printf -v bus '%03d' "$((10#$busnum))"
            printf -v device '%03d' "$((10#$devnum))"
            source_node=/dev/bus/usb/$bus/$device
        fi
    fi

    if [[ -n $source_node && -c $source_node ]]; then
        if ! device_metadata=$(stat -c '%t %T %u %g %a' "$source_node" 2>/dev/null); then
            sleep 0.1
            continue
        fi
        read -r major_hex minor_hex owner group mode <<<"$device_metadata"
        key=$bus/$device:$major_hex:$minor_hex
        target=$mirror_root/$bus/$device
        if [[ $key != "$active_key" || ! -c $target ]]; then
            find "$mirror_root" -mindepth 2 -maxdepth 2 -type c -delete
            install -d -m 0755 "$mirror_root/$bus"
            mknod "$target" c "$((16#$major_hex))" "$((16#$minor_hex))"
            chown "$owner:$group" "$target"
            chmod "$mode" "$target"
            active_key=$key
            printf '%(%FT%T%z)T mirrored %s as %s (%s:%s)\n' \
                -1 "$source_node" "$target" "$major_hex" "$minor_hex"
        fi
    elif [[ -n $active_key ]]; then
        find "$mirror_root" -mindepth 2 -maxdepth 2 -type c -delete
        printf '%(%FT%T%z)T removed stale VFS495 mirror\n' -1
        active_key=
    fi

    sleep 0.1
done
