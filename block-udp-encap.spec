Name:           block-udp-encap
Version:        0.1.0
Release:        2%{?dist}
Summary:        eBPF LSM blocker for UDP_ENCAP setsockopt abuse path

# This package ships a tiny userspace loader + BPF object and does not need
# auto-generated debug/debuginfo/debugsource RPM subpackages.
%global debug_package %{nil}
%global _debugsource_packages 0
%global _build_id_links none

License:        GPL-3.0-or-later
URL:            https://github.com/lestercheung/linux-copy-fail-workarounds
Source0:        %{name}-%{version}.tar.gz
Source1:        block-udp-encap.service

BuildRequires:  clang
BuildRequires:  gcc
BuildRequires:  libbpf-devel
BuildRequires:  elfutils-libelf-devel
BuildRequires:  zlib-devel
BuildRequires:  systemd-rpm-macros

# Runtime shared library dependencies are auto-generated from the loader ELF
# (e.g. libbpf.so.1, libelf.so.1, libz.so.1), which maps correctly on RHEL.
%{?systemd_requires}

%description
block-udp-encap provides an eBPF LSM program and userspace loader to block
setsockopt(IPPROTO_UDP, UDP_ENCAP, ...) calls that are used in exploit chains
requiring UDP encapsulation setup.

%prep
%autosetup -n %{name}-%{version}

%build
mkdir -p obj

clang -O2 -g -target bpf \
    -D__KERNEL__ \
    -I/usr/include/bpf \
    -c block_udp_encap.c -o obj/block_udp_encap.o

gcc -O2 -Wall -Wextra \
    lsm_loader.c -o obj/lsm_loader \
    -lbpf -lelf -lz

%install
install -d %{buildroot}%{_libexecdir}/block-udp-encap
install -m 0755 obj/lsm_loader %{buildroot}%{_libexecdir}/block-udp-encap/lsm_loader
install -m 0644 obj/block_udp_encap.o %{buildroot}%{_libexecdir}/block-udp-encap/block_udp_encap.o

install -d %{buildroot}%{_unitdir}
install -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/block-udp-encap.service

%post
%systemd_post block-udp-encap.service

%preun
%systemd_preun block-udp-encap.service

%postun
%systemd_postun_with_restart block-udp-encap.service

%files
%license LICENSE
%doc README.md QUICK-REFERENCE.md RHEL9-AF-ALG-SETUP.md
%{_libexecdir}/block-udp-encap/lsm_loader
%{_libexecdir}/block-udp-encap/block_udp_encap.o
%{_unitdir}/block-udp-encap.service

%changelog
* Fri May 08 2026 Copilot <copilot@local> - 0.1.0-2
- Disable build-id links to avoid file conflicts with block-af-alg package

* Fri May 08 2026 Copilot <copilot@local> - 0.1.0-1
- Initial RPM packaging for UDP_ENCAP blocker, loader, and systemd service
