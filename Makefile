# Makefile for AF_ALG eBPF blocker on RHEL9

CLANG ?= clang
CC ?= gcc
LLC ?= llc
BPFTOOL ?= bpftool
KERNEL_VERSION ?= $(shell uname -r)
VMLINUX_BTF ?= /sys/kernel/btf/vmlinux

# Paths
SRC_DIR := .
OBJ_DIR := obj
BPF_OBJ := $(OBJ_DIR)/block_af_alg.o
LOADER_BIN := $(OBJ_DIR)/af_alg_lsm_loader
INSTALL_DIR := /opt/copy-fail-blocker

# Flags
INCLUDES := -I/usr/include/bpf
CLANG_BPF_SYS_INCLUDES = $(shell clang -print-resource-dir)/include
LOADER_CFLAGS := -O2 -Wall -Wextra
LOADER_LDLIBS := -lbpf -lelf -lz

.PHONY: all clean install uninstall test help check-tools vmlinux loader run-loader

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

$(LOADER_BIN): $(SRC_DIR)/af_alg_lsm_loader.c $(OBJ_DIR)
	@echo "[*] Compiling libbpf loader..."
	$(CC) $(LOADER_CFLAGS) $(SRC_DIR)/af_alg_lsm_loader.c -o $@ $(LOADER_LDLIBS)
	@echo "[+] Compiled loader: $@"

run-loader: $(BPF_OBJ) loader
	@echo "[*] Running libbpf loader in foreground..."
	sudo $(LOADER_BIN) $(BPF_OBJ)

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

# Install as systemd service
install: all
	@echo "[*] Installing as systemd service..."
	sudo mkdir -p $(INSTALL_DIR)
	sudo cp $(LOADER_BIN) $(INSTALL_DIR)/af_alg_lsm_loader
	sudo cp $(BPF_OBJ) $(INSTALL_DIR)/block_af_alg.o
	sudo chmod 755 $(INSTALL_DIR)/af_alg_lsm_loader
	sudo chmod 644 $(INSTALL_DIR)/block_af_alg.o
	@printf '%s\n' \
		'[Unit]' \
		'Description=AF_ALG eBPF Socket Blocker' \
		'After=network.target' \
		'Documentation=man:socket(2)' \
		'' \
		'[Service]' \
		'Type=simple' \
		'ExecStart=/opt/copy-fail-blocker/af_alg_lsm_loader /opt/copy-fail-blocker/block_af_alg.o' \
		'Restart=always' \
		'RestartSec=5' \
		'StandardOutput=journal' \
		'StandardError=journal' \
		'SyslogIdentifier=af-alg-blocker' \
		'AmbientCapabilities=CAP_SYS_ADMIN CAP_SYS_RESOURCE CAP_PERFMON' \
		'' \
		'[Install]' \
		'WantedBy=multi-user.target' | sudo tee /etc/systemd/system/block-af-alg.service > /dev/null
	@echo "[+] Service installed"
	@echo "[*] To start: sudo systemctl start block-af-alg"
	@echo "[*] To enable: sudo systemctl enable block-af-alg"

uninstall:
	@echo "[*] Uninstalling..."
	sudo systemctl stop block-af-alg || true
	sudo systemctl disable block-af-alg || true
	sudo rm -f /etc/systemd/system/block-af-alg.service
	sudo rm -rf $(INSTALL_DIR)
	sudo systemctl daemon-reload
	@echo "[+] Uninstalled"

# List loaded eBPF programs
list:
	@echo "[*] Loaded eBPF programs:"
	sudo $(BPFTOOL) prog list

# Show statistics
stats:
	@echo "[*] AF_ALG blocker statistics:"
	sudo $(BPFTOOL) map dump name af_alg_stats || echo "Map not loaded"

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
	@echo "  make run-loader   - Load+attach with libbpf loader (foreground)"
	@echo "  make load-bcc     - Load via BCC Python script (recommended)"
	@echo "  make load-direct  - Load directly with bpftool"
	@echo "  make test         - Test AF_ALG socket blocking"
	@echo "  make install      - Install as systemd service"
	@echo "  make uninstall    - Remove systemd service"
	@echo "  make list         - List loaded eBPF programs"
	@echo "  make stats        - Show blocker statistics"
	@echo "  make clean        - Remove built objects"
	@echo "  make help         - Show this help"
