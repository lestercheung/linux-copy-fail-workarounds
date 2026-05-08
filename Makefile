# Makefile for AF_ALG eBPF blocker on RHEL9

CLANG ?= clang
CC ?= gcc
LLC ?= llc
BPFTOOL ?= bpftool
KERNEL_VERSION ?= $(shell uname -r)

# Paths
SRC_DIR := .
OBJ_DIR := obj
BPF_OBJ := $(OBJ_DIR)/block_af_alg.o
LOADER_BIN := $(OBJ_DIR)/lsm_loader
UDP_EVENTS_BIN := $(OBJ_DIR)/udp_encap_events
INSTALL_DIR := /opt/copy-fail-blocker
RPM_PACKAGES ?= block-af-alg block-udp-encap
RPM_VERSION ?= 0.1.0
RPMBUILD_TOP ?= $(HOME)/rpmbuild

# Flags
INCLUDES := -I/usr/include/bpf
CLANG_BPF_SYS_INCLUDES = $(shell clang -print-resource-dir)/include
LOADER_CFLAGS := -O2 -Wall -Wextra
LOADER_LDLIBS := -lbpf -lelf -lz

.PHONY: all clean test help check-tools loader run-loader udp-events rpm-setup rpm-sources rpm-build rpm-install

all: $(BPF_OBJ) loader

# Create output directory
$(OBJ_DIR):
	@mkdir -p $(OBJ_DIR)

# Compile eBPF program
$(BPF_OBJ): $(SRC_DIR)/block_af_alg.c $(OBJ_DIR)
	@echo "[*] Compiling eBPF program..."
	$(CLANG) -O2 -g -target bpf \
		-D__KERNEL__ \
		$(INCLUDES) \
		-c $(SRC_DIR)/block_af_alg.c -o $@
	@echo "[+] Compiled: $@"

# Build libbpf userspace loader (no bpftool needed at runtime)
loader: $(LOADER_BIN)

$(LOADER_BIN): $(SRC_DIR)/lsm_loader.c $(OBJ_DIR)
	@echo "[*] Compiling libbpf loader..."
	$(CC) $(LOADER_CFLAGS) $(SRC_DIR)/lsm_loader.c -o $@ $(LOADER_LDLIBS)
	@echo "[+] Compiled loader: $@"

run-loader: $(BPF_OBJ) loader
	@echo "[*] Running libbpf loader in foreground..."
	sudo $(LOADER_BIN) $(BPF_OBJ)

udp-events: $(UDP_EVENTS_BIN)

$(UDP_EVENTS_BIN): $(SRC_DIR)/udp_encap_events.c $(OBJ_DIR)
	@echo "[*] Compiling UDP_ENCAP event monitor..."
	$(CC) $(LOADER_CFLAGS) $(SRC_DIR)/udp_encap_events.c -o $@ $(LOADER_LDLIBS)
	@echo "[+] Compiled monitor: $@"

# Verify compilation
verify: $(BPF_OBJ)
	@echo "[*] Verifying eBPF object..."
	file $(BPF_OBJ)
	llvm-objdump -S $(BPF_OBJ)

# Load eBPF program (via BCC)
load-bcc: all
	@echo "[*] Loading via BCC..."
	sudo python3 $(SRC_DIR)/block-af-alg.py

# Load eBPF program (direct)
load-direct: all check-tools
	@echo "[*] Loading eBPF object directly..."
	sudo $(BPFTOOL) prog loadall $(BPF_OBJ) /sys/fs/bpf/af_alg_block autoattach
	@echo "[+] LSM program loaded and auto-attached from /sys/fs/bpf/af_alg_block"

# Check tools availability
check-tools:
	@command -v $(CLANG) >/dev/null 2>&1 || { echo "ERROR: clang not found"; exit 1; }
	@command -v $(BPFTOOL) >/dev/null 2>&1 || { echo "ERROR: bpftool not found"; exit 1; }
	@echo "[+] Tools available"

# Test the blocker
test: all
	@echo "[*] Testing AF_ALG socket blocker..."
	@python3 -c 'import socket,sys; \
try:\
 s=socket.socket(38, socket.SOCK_SEQPACKET); print("ERROR: AF_ALG socket created (blocker not active)"); s.close(); sys.exit(1)\
except PermissionError:\
 print("SUCCESS: AF_ALG socket blocked with PermissionError"); sys.exit(0)\
except OSError as e:\
 print(f"Socket error (expected): {e}"); sys.exit(0)'

# List loaded eBPF programs
list:
	@echo "[*] Loaded eBPF programs:"
	sudo $(BPFTOOL) prog list

# Show statistics
stats:
	@echo "[*] AF_ALG blocker statistics:"
	sudo $(BPFTOOL) map dump name af_alg_stats || echo "Map not loaded"

rpm-setup:
	@echo "[*] Preparing rpmbuild tree..."
	@command -v rpmdev-setuptree >/dev/null 2>&1 || { echo "ERROR: rpmdev-setuptree not found (install rpmdevtools)"; exit 1; }
	rpmdev-setuptree
	@echo "[+] rpmbuild tree ready at $(RPMBUILD_TOP)"

rpm-sources: rpm-setup
	@echo "[*] Creating source tarballs and staging spec/service for: $(RPM_PACKAGES)"
	@for pkg in $(RPM_PACKAGES); do \
		test -f $$pkg.spec || { echo "ERROR: Missing $$pkg.spec"; exit 1; }; \
		test -f $$pkg.service || { echo "ERROR: Missing $$pkg.service"; exit 1; }; \
		{ git ls-files; git ls-files --others --exclude-standard; } | \
		tar -czf $(RPMBUILD_TOP)/SOURCES/$$pkg-$(RPM_VERSION).tar.gz \
			--no-recursion \
			--transform "s,^,$$pkg-$(RPM_VERSION)/," \
			-T -; \
		cp $$pkg.spec $(RPMBUILD_TOP)/SPECS/; \
		cp $$pkg.service $(RPMBUILD_TOP)/SOURCES/; \
	done
	@echo "[+] Staged rpmbuild sources for all packages"

rpm-build: rpm-sources
	@echo "[*] Building binary RPMs for: $(RPM_PACKAGES)"
	@command -v rpmbuild >/dev/null 2>&1 || { echo "ERROR: rpmbuild not found (install rpm-build)"; exit 1; }
	@for pkg in $(RPM_PACKAGES); do \
		rpmbuild -bb $(RPMBUILD_TOP)/SPECS/$$pkg.spec || exit 1; \
	done
	@echo "[+] Build complete. RPMs:"
	@for pkg in $(RPM_PACKAGES); do \
		ls -1 $(RPMBUILD_TOP)/RPMS/*/$$pkg-*.rpm; \
	done

rpm-install: rpm-build
	@echo "[*] Installing generated RPMs..."
	@for pkg in $(RPM_PACKAGES); do \
		sudo dnf install -y $(RPMBUILD_TOP)/RPMS/*/$$pkg-*.rpm || exit 1; \
	done
	@echo "[+] Installed. Enable/start with:"
	@echo "    sudo systemctl enable --now block-af-alg.service"
	@echo "    sudo systemctl enable --now block-udp-encap.service"

clean:
	@echo "[*] Cleaning..."
	rm -rf $(OBJ_DIR)
	@echo "[+] Clean"

help:
	@echo "AF_ALG eBPF Blocker - Makefile Targets"
	@echo "======================================="
	@echo "  make all          - Compile eBPF program"
	@echo "  make check-tools  - Verify clang/bpftool installed"
	@echo "  make verify       - Show compiled object details"
	@echo "  make loader       - Build libbpf userspace loader"
	@echo "  make udp-events   - Build UDP_ENCAP ringbuf event monitor"
	@echo "  make run-loader   - Load+attach with libbpf loader (foreground)"
	@echo "  make load-bcc     - Load via BCC Python script (recommended)"
	@echo "  make load-direct  - Load directly with bpftool"
	@echo "  make test         - Test AF_ALG socket blocking"
	@echo "  make list         - List loaded eBPF programs"
	@echo "  make stats        - Show blocker statistics"
	@echo "  make rpm-setup    - Create rpmbuild tree under ~/rpmbuild"
	@echo "  make rpm-sources  - Create source tarballs + stage all spec/service files"
	@echo "  make rpm-build    - Build binary RPMs for all RPM_PACKAGES"
	@echo "  make rpm-install  - Build then install all generated RPMs"
	@echo "  make clean        - Remove built objects"
	@echo "  make help         - Show this help"
