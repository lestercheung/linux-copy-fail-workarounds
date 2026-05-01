# AF_ALG eBPF Blocker — RHEL9 Setup & Compilation Guide

## Overview
This blocks all `socket()` syscalls with `family == AF_ALG` (38), preventing the crypto socket exploitation vector used in the copy-fail-repo.py exploit.

---

## Step 1: Install BCC & Dependencies on RHEL9

```bash
# Enable EPEL for bcc packages
sudo dnf install -y epel-release

# Install BCC and kernel development tools
sudo dnf install -y \
  bcc \
  bcc-devel \
  bcc-tools \
  kernel-devel \
  kernel-headers \
  clang \
  llvm

# Verify BCC installation
bcc-version

# Verify tracepoint availability
ls /sys/kernel/debug/tracing/events/syscalls/ | grep socket
```

Expected output includes:
- `sys_enter_socket`
- `sys_exit_socket`
- `sys_enter_accept4`

---

## Step 2: Enable Kernel Features (if needed)

Check if tracepoints and eBPF are enabled:

```bash
# Check kernel config
grep CONFIG_TRACEPOINTS /boot/config-$(uname -r)
grep CONFIG_BPF /boot/config-$(uname -r)
grep CONFIG_HAVE_EBPF_JIT /boot/config-$(uname -r)

# All should show: =y
```

If not enabled, you may need to rebuild the kernel or use a different approach (LSM hooks, seccomp).

---

## Step 3: Run the eBPF Program

```bash
# Make script executable
chmod +x block-af-alg.py

# Run with sudo (required for eBPF)
sudo python3 block-af-alg.py

# Output should show:
# [*] Loading AF_ALG socket blocker eBPF program
# [+] Attached to sys_enter_socket tracepoint
# [+] Monitoring AF_ALG socket attempts (Ctrl-C to stop)
# [+] Output from trace_pipe:
```

---

## Step 4: Test the Blocker

In another terminal, try to create an AF_ALG socket:

```bash
# Test program - will fail with -EPERM
python3 << 'EOF'
import socket
try:
    s = socket.socket(38, socket.SOCK_SEQPACKET)  # AF_ALG = 38
    print("ERROR: AF_ALG socket created (blocker not working)")
except PermissionError:
    print("SUCCESS: AF_ALG socket blocked")
except OSError as e:
    print(f"Socket creation failed: {e}")
EOF
```

You should see:
- **Without blocker**: AF_ALG socket creates successfully (dangerous)
- **With blocker**: `BLOCK: socket(AF_ALG) pid=... uid=...` in trace output, and PermissionError in test

---

## Step 5: Persist the Blocker (Systemd Service)

Create a systemd service to auto-start:

```bash
# Create service file
sudo tee /etc/systemd/system/block-af-alg.service <<'EOF'
[Unit]
Description=AF_ALG eBPF Socket Blocker
Documentation=man:socket(2)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/block-af-alg.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=af-alg-blocker

# Requires eBPF permissions
AmbientCapabilities=CAP_SYS_ADMIN CAP_SYS_RESOURCE CAP_PERFMON

[Install]
WantedBy=multi-user.target
EOF

# Copy script to /opt/
sudo cp block-af-alg.py /opt/block-af-alg.py
sudo chmod 755 /opt/block-af-alg.py

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable block-af-alg.service
sudo systemctl start block-af-alg.service

# Check status
sudo systemctl status block-af-alg.service

# View logs
sudo journalctl -u block-af-alg.service -f
```

---

## Step 6: Alternative: LSM Hook Approach (Stronger)

If tracepoints don't work, use the Linux Security Module (LSM) approach:

```bash
# Check if LSM is available
cat /sys/kernel/security/lsm

# Or use seccomp-based approach (simpler):
# Create a seccomp profile that blocks AF_ALG socket() calls
```

---

## Step 7: Monitor & Verify

```bash
# Check if blocker is running
ps aux | grep block-af-alg

# Monitor blocked attempts
sudo tail -f /var/log/audit/audit.log | grep "AF_ALG\|socket"

# Or use eBPF stats
sudo cat /proc/meminfo | grep eBPF
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Operation not permitted" running the program | Run with `sudo` |
| "No such file or directory" tracepoint | Enable `CONFIG_TRACEPOINTS` in kernel |
| Tracepoint not found | Use `sudo cat /sys/kernel/debug/tracing/available_events \| grep socket` |
| Module not found (bcc-devel) | Install `dnf install -y kernel-devel-$(uname -r)` |
| bpf_override_return not working | Some kernels require 5.7+; check with `uname -r` |

---

## References

- [BCC Documentation](https://github.com/iovisor/bcc)
- [AF_ALG Socket Interface](https://www.kernel.org/doc/html/latest/crypto/userspace-if.html)
- [eBPF in RHEL](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/security_hardening/using-ebpf_security-hardening)
- [Syscall Tracepoints](https://www.kernel.org/doc/html/latest/trace/events.html)
