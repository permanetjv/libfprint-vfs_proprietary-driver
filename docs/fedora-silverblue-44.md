# Fedora Silverblue 44 port status

This branch is an in-progress port and hardware investigation for an HP
EliteBook 840 G3 with a Validity VFS495 (`138a:003f`). The test host runs
Fedora Silverblue 44, libfprint 1.94.10, fprintd 1.94.5, and kernel
7.1.7-200.fc44.x86_64.

## Source and licensing boundary

The open-source driver, protocol validation, tests, and isolation tools live in
this repository. The HP/Synaptics RPM, firmware images, service,
`validity-sensor`, and `libvfsFprintWrapper.so` remain external inputs. They are
not committed or redistributed here. Runtime tools require an explicitly
provided extracted vendor root and old compatibility libraries.

The proprietary processes are run in a bubblewrap boundary with a private PID,
IPC, temporary, runtime, and persistent-data namespace; all capabilities are
dropped. Only a validated VFS495 device mirror is mounted as USB. The
initializer may share host netlink and receives read-only `/run/udev` state so
it can follow the reader when firmware loading changes the USB device number.
The surrounding transient systemd unit restricts address families to
`AF_UNIX` and `AF_NETLINK` and denies IP networking.

## Port and build evidence

`tools/prepare-libfprint-1.94.10.sh` requires a clean checkout at the exact
`v1.94.10` tag, copies this driver into libfprint, and applies the integration
patch. The port uses `FpImageDevice`, asynchronous `GSubprocess`/GIO reads,
cancellation, bounded image dimensions, exact payload-length validation, and a
fixed-width protocol ready marker.

The following checks pass in a pristine libfprint 1.94.10 integration tree:

- strict compilation of the selected `vfs_proprietary` driver;
- four C protocol-validation tests;
- four Python raw-capture protocol tests;
- upstream `fpi-device`, `fpi-ssm`, and `fpi-assembling` unit tests;
- direct udev and hwdb generation for `138a:003f` without fatal warnings.

This is build evidence, not yet an installable or fully functional Fedora
package. Versioned RPMs, rpm-ostree installation and rollback, SELinux policy,
production systemd/udev integration, and suspend/resume handling remain to be
implemented after raw acquisition succeeds.

## Kernel 7.1 raw-capture verdict

Kernel USB transport is compatible. The isolated legacy components open the
device, submit and reap USB URBs, load firmware, follow re-enumeration, and
communicate through the vendor service IPC. The original acquisition path then
fails at `GroupGetFingerprint` because no secure session can be established
with the reader.

The ownership investigation produced these results:

- `sensorstat`: the sensor is secure and no secure session is established;
- `resetowner -doinit`: reports success;
- `get_ownership_info`: 65,535 total and 65,535 available ownership cycles,
  consistent with an unowned sensor;
- `setowner -doinit`: the vendor API returns `0x172`,
  `VCS_RESULT_SENSOR_CMD_DENIED`.

Disabling USB autosuspend and running the acquisition path as root do not
change the result. No fingerprint image has been saved. The current verdict is
therefore: kernel 7.1 transport works, while raw capture remains blocked by the
sensor firmware's ownership policy.

## Required firmware action

The vendor README says to reset the fingerprint sensor in BIOS before retrying
first-time ownership. On this HP generation the preferred narrow action is:

1. Reboot and press `Esc`, then `F10` for Computer Setup.
2. Open **Security** and set **Fingerprint Reset on Reboot** to **Yes** (wording
   may vary slightly).
3. Save changes and exit. Accept a dedicated **Reset Fingerprint Sensor**
   confirmation with `F1` if it appears.
4. Do not clear the TPM or choose a broader factory-security reset for this
   driver test.

After Fedora starts, run the isolated `setowner -doinit` initializer once,
retain its generated persistent owner data, and repeat raw capture before
starting RPM or fprintd integration.

The installed HP N75 firmware is 01.57. HP also documents N75 01.61 for the
EliteBook 820/840/850 G3 and says that release fixes a fingerprint power-on
authentication issue. A BIOS update has not been attempted and should be
evaluated separately from the narrow fingerprint reset:

- [HP December 2023 BIOS refresh for 2015 notebook PCs](https://support.hp.com/emea_middle_east-en/document/ish_9824930-9824982-16)
- [HP BIOS security reset and fingerprint-sensor confirmation behavior](https://support.hp.com/ca-en/document/c07012053)
