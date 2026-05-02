Name:           copy-fail-blocker
Version:        0.1.0
Release:        2%{?dist}
Summary:        eBPF LSM blocker for AF_ALG sockets (copy-fail workaround)

# This package ships a tiny userspace loader + BPF object and does not need
# auto-generated debug/debuginfo/debugsource RPM subpackages.
%global debug_package %{nil}
%global _debugsource_packages 0

License:        GPL-3.0-or-later
URL:            https://github.com/lestercheung/linux-copy-fail-workarounds
Source0:        %{name}-%{version}.tar.gz
Source1:        block-af-alg.service

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
copy-fail-blocker provides an eBPF LSM program and a userspace loader to
block AF_ALG socket creation as a workaround for copy-fail style local
privilege escalation chains.

%prep
%autosetup -n %{name}-%{version}

%build
mkdir -p obj

clang -O2 -g -target bpf \
    -D__KERNEL__ \
    -I/usr/include/bpf \
    -c block_af_alg.c -o obj/block_af_alg.o

gcc -O2 -Wall -Wextra \
    lsm_loader.c -o obj/lsm_loader \
    -lbpf -lelf -lz

%install
install -d %{buildroot}%{_libexecdir}/copy-fail-blocker
install -m 0755 obj/lsm_loader %{buildroot}%{_libexecdir}/copy-fail-blocker/lsm_loader
install -m 0644 obj/block_af_alg.o %{buildroot}%{_libexecdir}/copy-fail-blocker/block_af_alg.o

install -d %{buildroot}%{_unitdir}
install -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/block-af-alg.service

%post
%systemd_post block-af-alg.service

%preun
%systemd_preun block-af-alg.service

%postun
%systemd_postun_with_restart block-af-alg.service

%files
%license LICENSE
%doc README.md QUICK-REFERENCE.md RHEL9-AF-ALG-SETUP.md
%{_libexecdir}/copy-fail-blocker/lsm_loader
%{_libexecdir}/copy-fail-blocker/block_af_alg.o
%{_unitdir}/block-af-alg.service

%changelog
* Sun May 03 2026 Copilot <copilot@local> - 0.1.0-2
- Drop incorrect hardcoded runtime Requires names; use auto-generated ELF deps

* Sat May 02 2026 Copilot <copilot@local> - 0.1.0-1
- Initial RPM packaging for loader, BPF object, and systemd service
