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

The versioned Fedora 44 RPM and SRPM build reproducibly from Fedora's dist-git
baseline, run the port checks during `%check`, and have transactional
rpm-ostree install and override-reset helpers. Deployment remains intentionally
deferred until raw acquisition, SELinux policy, production systemd isolation,
and suspend/resume handling are verified.

The Fedora package keeps VFS495 out of libfprint's USB-autosuspend allowlist.
The driver remains discoverable through the normal udev permissions rule, but
systemd does not switch this reset-sensitive legacy reader to `power/control=auto`.

## July 2026 reference comparison

The independently published
[`0nsec/vfs495-fprintd`](https://github.com/0nsec/vfs495-fprintd) reference uses
the same VFS495, HP EliteBook 840 G3, SoftPaq-era `vcsFPService`, wrapper, and
OpenSSL 0.9.8 dependency. It provides useful evidence that this proprietary
capture stack can still return clean swipe images on a modern Linux userspace.
It also contributes a sensible persistent-process architecture: keep the
service and initialized wrapper warm, capture frames on demand, and put a
separate fprintd-compatible matcher/backend above acquisition.

The reference is not a replacement driver and does not resolve this machine's
current ownership state. It runs the proprietary service directly as root,
does not document or package the sensor-specific `/etc/ValidityPersistentData`
needed for secure-session recovery, and assumes acquisition already works on
the author's sensor. Its own README marks authentication unusable because NBIS
cross-matching of velocity-distorted swipe images is unreliable. Its untracked
`vfs_nbis` executable is also required by the backend but absent from the
repository.

The parts adapted here are the persistent capture topology, normal-SSL service
operation, explicit Flex ID `0x83` compatibility, and separation of raw image
acquisition from matching. The RAW-partition and Flex ID compatibility changes
are guarded by the exact audited `vcsFPService` hash and explicit
acknowledgement tokens.
Porting the reference's open-fprintd/NBIS layer is intentionally deferred until
this host can capture an image; it cannot fix a sensor command rejected before
pixels are returned.

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

The reference-aligned normal-SSL path now gets substantially farther than the
original port. With the guarded RAW-partition and Flex ID compatibility active,
the Falcon image reconstructor selects Flex ID `0x83`; `idsStartupIr`, image
size calculation, all capture-context allocations, and the fingerprint worker
arm return success. The actual GetFingerprint reply is still `0x172`,
`VCS_RESULT_SENSOR_CMD_DENIED`; the vendor ESD wrapper then rewrites that to
`0x168` after its recovery attempt. A separate guarded no-SSL diagnostic
reaches the same sensor denial, proving that image reconstruction and host SSL
policy are not the final blocker.

Falcon secure-session tracing also resolves an earlier ambiguous success
value. The first `scsSSLEstablishSession` return of zero means only that its
state-machine step was accepted. The SSL context remains in state `7`, while
`scsSSLIsInSecureSession` requires state `8`. The next step frees the failed
context and returns `0x17f`; no authenticated session was established.

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

The vendor utility's other documented ownership forms have now been exercised
under equivalent guards. Supplying fresh CIK/CIOS AES keys produces a real
flags-`0x13` request, and supplying the utility's audited in-binary RSA test
keypair plus both AES keys produces flags `0x1f`. Both submissions and waits
succeed on the host, but both asynchronous sensor callbacks return `0x36`.
The full-key handler persists `HAPrivKey` and `SPrivMod` before it sends the
request, so the resulting 2,956-byte local state file is not proof of sensor
ownership. A zero-byte pre-attempt state backup and a 2,956-byte pre-simulation
backup are retained outside Git.

Offline control-flow inspection found one materially different vendor route,
`setowner_sim`. Despite its name, it is not a mock: for firmware `04.60` it
loads a volatile `0x400` module-test patch, calls the real TakeOwnership path,
attempts SSL initialization and calibration, then restores the normal run
patch. A hash-pinned, AC-only, USB-mirror-validated launcher mode and detailed
trace are committed. No simulated-patch ownership call has reached the sensor
yet: the preceding ESD hard reset left the reader unable to complete even a
read-only initializer `getver`, and logical USB reset plus driver unbind/rebind
did not recover it. The laptop's xHCI root hub reports no per-port power
switching. Testing this last vendor-supported route therefore requires a full
machine power transition; resetting the complete xHCI controller would disturb
every USB device and was not done.

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
