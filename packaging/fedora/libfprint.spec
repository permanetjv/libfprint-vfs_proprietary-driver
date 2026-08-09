%global vfs495_commit 05006f158b62921f5a3af8a26b4e045308394a39

Name:           libfprint
Version:        1.94.10
Release:        5.vfs495.5%{?dist}
Summary:        Toolkit for fingerprint scanners with the VFS495 port

# Most of libfprint and the VFS495 port are LGPL-2.1-or-later.
# libfprint/nbis is NIST-PD.
License:        LGPL-2.1-or-later AND NIST-PD
URL:            https://fprint.freedesktop.org/
Source0:        https://gitlab.freedesktop.org/libfprint/libfprint/-/archive/v%{version}/libfprint-v%{version}.tar.gz
Source1:        https://github.com/permanetjv/libfprint-vfs_proprietary-driver/archive/%{vfs495_commit}.tar.gz#/libfprint-vfs495-port-%{vfs495_commit}.tar.gz

# Fedora 44 patches, copied without modification from Fedora dist-git commit
# 92d8aa1d4a5a756f8090cccf1fe903c025f7225f.
Patch00001:     2c7842c905147a2d127c1b168b2e9d43.patch
Patch10001:     0001-doc-Include-Binary-buffer-I-O-section-for-the-byte-r.patch
Patch10002:     0002-fpi-byte-writer-Add-APIs-to-write-and-get-GBytes.patch
Patch10003:     0003-fpi-byte-reader-Add-support-to-read-and-get-peek-GBy.patch
Patch10004:     0004-fpi-byte-reader-Add-support-to-read-to-a-static-buff.patch
Patch10005:     0005-fpi-usb-transfer-Add-missing-definition-of-set_short.patch
Patch10006:     0006-fpi-usb-transfer-Wrap-g_error_new-arguments.patch
Patch10007:     egis_reader.patch
Patch20001:     libfprint-vfs495-integration.patch

BuildRequires:  meson
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  git
BuildRequires:  openssl-devel
BuildRequires:  pkgconfig(glib-2.0) >= 2.50
BuildRequires:  pkgconfig(gio-2.0) >= 2.44.0
BuildRequires:  pkgconfig(gusb) >= 0.3.0
BuildRequires:  pkgconfig(nss)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  gtk-doc
BuildRequires:  libgudev-devel
BuildRequires:  systemd
BuildRequires:  gobject-introspection-devel
BuildRequires:  python3
BuildRequires:  python3-cairo
BuildRequires:  python3-gobject
BuildRequires:  cairo-devel
BuildRequires:  umockdev >= 0.13.2

%description
libfprint offers support for consumer fingerprint readers. This Fedora 44
build adds the open-source VFS495 driver and capture helper. The proprietary
HP/Synaptics runtime is deliberately not included or declared as a package
dependency.

%package        devel
Summary:        Development files for %{name}
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description    devel
The %{name}-devel package contains libraries and header files for developing
applications that use %{name}.

%package        tests
Summary:        Tests for the %{name} package
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description tests
The %{name}-tests package contains tests that can be used to verify the
functionality of the installed %{name} package.

%package        vfs495-runtime
Summary:        Isolated runtime integration for the VFS495 driver
Requires:       %{name}%{?_isa} = %{version}-%{release}
Requires:       fprintd
Requires:       bubblewrap
Requires:       procps-ng
Requires:       libtommath
Requires:       bash
Requires:       coreutils
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

%description vfs495-runtime
Open-source systemd and bubblewrap integration for an externally supplied,
non-redistributable VFS495 vendor runtime. This package contains no vendor
binaries, firmware, keys, or sensor state.

%prep
%autosetup -S git -n libfprint-v%{version}
tar -xzf %{SOURCE1}
cp -a libfprint-vfs495-port-%{vfs495_commit}/vfs_proprietary \
  libfprint/drivers/vfs_proprietary

%build
# Match Fedora 44's all-driver build so this remains a drop-in libfprint.
%meson -Ddrivers=all
%meson_build

%install
%meson_install
port_root=libfprint-vfs495-port-%{vfs495_commit}
install -Dpm0755 "$port_root/tools/monitor-vfs495-usb-mirror.sh" \
  %{buildroot}%{_libexecdir}/vfs495/vfs495-usb-mirror
install -Dpm0755 "$port_root/packaging/systemd/vfs495-vendor-supervisor" \
  %{buildroot}%{_libexecdir}/vfs495/vfs495-vendor-supervisor
install -Dpm0755 "$port_root/packaging/systemd/vfs495-vendor-inner-supervisor" \
  %{buildroot}%{_libexecdir}/vfs495/vfs495-vendor-inner-supervisor
install -Dpm0644 "$port_root/packaging/systemd/vfs495-usb-mirror.service" \
  %{buildroot}%{_unitdir}/vfs495-usb-mirror.service
install -Dpm0644 "$port_root/packaging/systemd/vfs495-vendor.service" \
  %{buildroot}%{_unitdir}/vfs495-vendor.service
install -Dpm0644 "$port_root/packaging/systemd/60-vfs495-runtime.conf" \
  %{buildroot}%{_unitdir}/fprintd.service.d/60-vfs495-runtime.conf

%check
%set_build_flags
port_root=libfprint-vfs495-port-%{vfs495_commit}
gcc $CFLAGS -Wall -Wextra -Werror \
  -I libfprint/drivers/vfs_proprietary \
  "$port_root/tests/test_protocol.c" \
  libfprint/drivers/vfs_proprietary/protocol.c \
  $(pkg-config --cflags --libs glib-2.0) \
  -o vfs495-test-protocol
./vfs495-test-protocol
python3 -m unittest -v "$port_root/tests/test_raw_capture.py"
helper=$(find %{_vpath_builddir} -type f \
  -name vfs_proprietary-capture-helper -print -quit)
test -n "$helper"
"$port_root/tests/check_capture_helper_linkage.sh" "$helper"
! grep -q '^usb:v138Ap003F' data/autosuspend.hwdb
hwdb_generator=$(dirname "$helper")/../../fprint-list-udev-hwdb
test -x "$hwdb_generator"
! "$hwdb_generator" 2>/dev/null | \
  grep -q '^usb:v138Ap003F'

%ldconfig_scriptlets

%post vfs495-runtime
%systemd_post vfs495-usb-mirror.service vfs495-vendor.service

%preun vfs495-runtime
%systemd_preun vfs495-usb-mirror.service vfs495-vendor.service

%postun vfs495-runtime
%systemd_postun_with_restart vfs495-usb-mirror.service vfs495-vendor.service

%files
%license COPYING
%doc NEWS THANKS AUTHORS README.md
%{_libdir}/*.so.*
%{_libdir}/girepository-1.0/*.typelib
%{_libexecdir}/libfprint/vfs_proprietary-capture-helper
%{_udevhwdbdir}/60-autosuspend-libfprint-2.hwdb
%{_udevrulesdir}/70-libfprint-2.rules
%{_datadir}/metainfo/org.freedesktop.libfprint.metainfo.xml

%files devel
%doc HACKING.md
%{_includedir}/*
%{_libdir}/*.so
%{_libdir}/pkgconfig/%{name}-2.pc
%{_datadir}/gir-1.0/*.gir
%{_datadir}/gtk-doc/html/libfprint-2/

%files tests
%{_libexecdir}/installed-tests/libfprint-2/
%{_datadir}/installed-tests/libfprint-2/

%files vfs495-runtime
%doc libfprint-vfs495-port-%{vfs495_commit}/packaging/systemd/runtime.conf.example
%{_libexecdir}/vfs495/
%{_unitdir}/vfs495-usb-mirror.service
%{_unitdir}/vfs495-vendor.service
%dir %{_unitdir}/fprintd.service.d
%{_unitdir}/fprintd.service.d/60-vfs495-runtime.conf

%changelog
* Sun Aug 09 2026 PermaNet JV <permanetjv@users.noreply.github.com> - 1.94.10-5.vfs495.5
- Add the open-source VFS495 port to Fedora 44's libfprint package
- Keep VFS495 out of libfprint's USB autosuspend allowlist
- Scope compatibility-library lookup to the capture-helper child
- Add a separate persistent, isolated vendor-runtime integration subpackage
- Keep the non-redistributable vendor capture runtime outside the RPM
