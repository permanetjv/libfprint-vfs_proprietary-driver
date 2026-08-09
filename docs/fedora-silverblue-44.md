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

`/etc/ValidityPersistentData` is a single vendor binary data file, not a
directory. The launcher creates it as a private `0600` regular file and bind
mounts only that file. Mounting a directory at this path causes
`vcsSensorSetOwner` to return `0xcf` (`VCS_RESULT_FILE_OPEN_FAILED`) before the
actual sensor-policy result can be observed.

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

The ownership investigation produced these results both before and after the
BIOS update and firmware-level fingerprint reset described below:

- `sensorstat`: the sensor is secure and no secure session is established;
- `resetowner -doinit`: reports success;
- `get_ownership_info`: 65,535 total and 65,535 available ownership cycles,
  unchanged across the reset and ownership attempts;
- an unmodified `setowner -doinit` returns local status `0x172`,
  `VCS_RESULT_SENSOR_CMD_DENIED`, before submitting SetOwner to the reader;
- after correcting the VFS495 provisioning-cache regression under a guarded
  debugger, SetOwner submission and its wait both return success, but the
  reader's asynchronous callback returns `0x36`, `VCS_RESULT_ERROR`.

Disabling USB autosuspend and running the acquisition path as root do not
change the result. No fingerprint image has been saved. The current verdict is
therefore: kernel 7.1 transport works, while raw capture remains blocked by the
sensor firmware's ownership policy. The callback trace distinguishes that
policy result from a host USB, wait, or process-isolation failure.

## BIOS update and fingerprint-reset result

The EliteBook was updated from HP N75 01.57 to the latest applicable HP N75
01.62 firmware. Post-flash checks report `N75 Ver. 01.62`, firmware date
2024-03-17, Secure Boot enabled, kernel 7.1.7, and a normally enumerated VFS495.
The dedicated **Fingerprint Reset on Reboot** confirmation was also completed;
the TPM and broader factory-security state were not cleared.

The first isolated `setowner -doinit` after that reset loaded firmware and the
USB mirror followed the reader across re-enumeration. With a fresh, regular
`ValidityPersistentData` file, the unmodified vendor API returned `0x172`.
Follow-up read-only probes again reported a secure sensor with no secure
session and 65,535 of 65,535 ownership cycles available. These values alone do
not establish that the reader is unowned.

Deeper diagnostics report sensor firmware `04.60.00.0104 Falcon ROM`, raw
device security state `0x2`, and product ID `0x003f`. Vendor code defines that
raw state as provisioned and initially derives `isProvisioned=1`, but a later
post-patch version path incorrectly overwrites the cache with zero. A guarded
compatibility trace preserves the raw-derived value only for this exact device
and state. This permits the real SetOwner request, which the firmware rejects
in its callback with `0x36`.

The separately authorized `provision vfs495 -doinit` diagnostic entered the
vendor provisioning handler, which reported `Already provisioned.` Neither
the sensor-provision nor OTP-write function was called, so no OTP change
occurred. Provisioning is therefore not the next step.

The vendor utility documents that SetOwner is expected to fail when the sensor
is already secure. Offline control-flow inspection also confirms that a
successful `resetowner -doinit` result follows the actual synchronous
reset-ownership operation and storage cleanup; blindly repeating that
destructive command would not add evidence. The remaining blocker is finding
a reliable way to clear or re-establish the VFS495 ownership/secure-session
state after the BIOS reset, or establishing that this firmware revision cannot
be adopted by the legacy Linux stack. No fingerprint image or biometric data
has been captured.

All sensor-security-changing launcher modes now require connected AC power,
the audited initializer hash, an exact acknowledgement token, and a live,
major/minor-validated USB mirror. The tracked mirror monitor follows transient
disconnects and device-number changes without the sysfs race found in the
initial ad-hoc monitor.

References used for the firmware/reset investigation:

- [HP December 2023 BIOS refresh for 2015 notebook PCs](https://support.hp.com/emea_middle_east-en/document/ish_9824930-9824982-16)
- [HP BIOS security reset and fingerprint-sensor confirmation behavior](https://support.hp.com/ca-en/document/c07012053)
