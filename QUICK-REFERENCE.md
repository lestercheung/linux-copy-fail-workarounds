# Quick Reference: AF_ALG eBPF Blocker on RHEL9

## Files Provided

- **block-af-alg.py** — BCC Python wrapper (easiest to use)
- **block_af_alg.c** — Standalone eBPF C source (can compile directly)
- **Makefile** — Automates compilation and installation
- **RHEL9-AF-ALG-SETUP.md** — Full setup guide
- **QUICK-REFERENCE.md** — This file

---

## One-Liner Setup

```bash
# Install dependencies (RHEL9)
sudo dnf install -y epel-release bcc bcc-devel kernel-devel clang llvm

# Run blocker immediately
sudo python3 block-af-alg.py

# In another terminal, verify it works
python3 -c "import socket; socket.socket(38, socket.SOCK_SEQPACKET)"
# Should fail with PermissionError
```

---

## Full Compile & Install

```bash
# Check tools
make check-tools

# Compile eBPF
make all

# Verify compilation
make verify

# Load and test
make load-bcc
make test

# Install as service (runs on boot)
make install

# Start service
sudo systemctl start block-af-alg
sudo systemctl status block-af-alg
```

---

## Direct Compilation (Without Makefile)

```bash
# Compile standalone eBPF program
clang -O2 -target bpf -c block_af_alg.c -o block_af_alg.o

# Verify
llvm-objdump -S block_af_alg.o

# Load with bpftool
sudo bpftool prog load block_af_alg.o type tracepoint name af_alg_block
```

---

## Monitoring

```bash
# Real-time trace output
sudo python3 block-af-alg.py

# View systemd logs
sudo journalctl -u block-af-alg.service -f

# List loaded eBPF programs
sudo bpftool prog list | grep af_alg

# Show program details
sudo bpftool prog show
```

---

## Uninstall

```bash
make uninstall
# or manually:
sudo systemctl stop block-af-alg
sudo systemctl disable block-af-alg
sudo rm /etc/systemd/system/block-af-alg.service /opt/block-af-alg.py
```

---

## How It Works

1. **Tracepoint Hook**: Attaches to `syscalls:sys_enter_socket`
2. **Family Check**: Reads first syscall arg (family parameter)
3. **AF_ALG Detection**: Checks if family == 38 (AF_ALG constant)
4. **Block**: Calls `bpf_override_return(ctx, -EPERM)` to deny the syscall
5. **Statistics**: Increments counter in BPF map for monitoring

---

## Testing

### Test 1: Verify blocking works
```bash
# Terminal 1: Start blocker
sudo python3 block-af-alg.py
# Watch for: [+] Monitoring AF_ALG socket attempts

# Terminal 2: Try to create AF_ALG socket
python3 << 'EOF'
import socket
try:
    s = socket.socket(38, socket.SOCK_SEQPACKET)
except PermissionError as e:
    print(f"SUCCESS: {e}")
EOF

# Terminal 1: Should show BLOCK message
```

### Test 2: Normal sockets still work
```bash
# This should succeed (not AF_ALG)
python3 << 'EOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.close()
print("IPv4 TCP socket OK")
EOF
```

### Test 3: Test against exploit script
```bash
# Blocker prevents copy-fail-repo.py from running
sudo python3 /path/to/copy-fail-repo.py

# Should fail immediately (can't create AF_ALG socket)
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Operation not permitted` | Not running as sudo | Use `sudo python3` |
| `No such file: /sys/kernel/debug/tracing/events/syscalls/sys_enter_socket` | Tracepoints not enabled | Check kernel config: `grep CONFIG_TRACEPOINTS /boot/config-$(uname -r)` |
| `ModuleNotFoundError: No module named bcc` | BCC not installed | `sudo dnf install -y bcc bcc-devel` |
| `bpf_override_return not available` | Kernel too old | Requires kernel 5.7+; check `uname -r` |
| `BLOCK message appears but socket still creates` | Kernel doesn't support override | Use LSM/seccomp instead |

---

## References

- **AF_ALG Docs**: https://www.kernel.org/doc/html/latest/crypto/userspace-if.html
- **BCC Repo**: https://github.com/iovisor/bcc
- **eBPF Guide**: https://ebpf.io/
- **RHEL9 eBPF**: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/security_hardening/using-ebpf_security-hardening
