# Fedora Silverblue 44 package

This package starts with Fedora 44's `libfprint-1.94.10` spec and patch set at
dist-git commit `92d8aa1d4a5a756f8090cccf1fe903c025f7225f`. It adds the
open-source VFS495 port pinned in the spec and installs the capture helper at
`/usr/libexec/libfprint/vfs_proprietary-capture-helper`.

The RPM contains no HP/Synaptics binaries, firmware, keys, or persistent sensor
state. It also has no build-time dependency on those components. The capture
helper loads an explicitly supplied vendor runtime only when invoked.

## Build in the Fedora 44 toolbox

Install build tools and dependencies through DNF inside the toolbox:

```sh
sudo dnf install -y fedpkg rpm-build rpmdevtools dnf-plugins-core
sudo dnf builddep -y packaging/fedora/libfprint.spec
tools/build-fedora-44-rpms.sh
```

The build script verifies the Fedora dist-git commit, obtains Fedora's upstream
source archive with `fedpkg sources`, creates a deterministic archive from the
port commit, runs the port's tests during `%check`, and writes results below
`build/fedora-44/`.

Before installation, inspect the RPM manifest and dependencies:

```sh
rpm -qpl build/fedora-44/RPMS/*/libfprint-1.94.10-5.vfs495.5.fc44.*.rpm
rpm -qpR build/fedora-44/RPMS/*/libfprint-1.94.10-5.vfs495.5.fc44.*.rpm
```

## Transactional install and rollback

The optional `libfprint-vfs495-runtime` RPM contains only open-source service
integration. Before installing it, stage the external compatibility roots
under `/var/lib/vfs495-runtime`, copy `runtime.conf.example` to
`/etc/vfs495/runtime.conf`, and verify its pinned hashes. The fprintd drop-in
passes legacy library paths only to capture-helper children and joins the
vendor service's systemd-created private `/tmp` and IPC namespaces.
The vendor service conflicts with `sleep.target`; its `BindsTo` relationship
stops fprintd before suspend. A later D-Bus request starts a fresh vendor
service and fprintd instance after resume.

After raw capture and the production isolation configuration are verified:

```sh
tools/install-fedora-44-override.sh
systemctl reboot
```

To stage removal of the override:

```sh
tools/rollback-fedora-44-override.sh
systemctl reboot
```

Both operations create a new rpm-ostree deployment. The currently booted
deployment is unchanged until reboot, and the previous deployment remains
available from the boot menu.
