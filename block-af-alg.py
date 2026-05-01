#!/usr/bin/env python3
"""
BCC eBPF program to BLOCK AF_ALG socket creation via LSM hook.
AF_ALG is address family 38, used for kernel crypto socket interface.

Uses LSM_PROBE(socket_create) which allows returning -EPERM to deny.
Requires:
  - CONFIG_BPF_LSM=y
  - 'bpf' in /sys/kernel/security/lsm
  - BCC 0.26+
  - Kernel 5.7+
"""

from bcc import BPF
import sys
import signal

bpf_source = """
#include <linux/socket.h>

#define AF_ALG 38

BPF_ARRAY(block_count, u64, 1);

LSM_PROBE(socket_create, int family, int type, int protocol, int kern) {
    if (family == AF_ALG) {
        u32 idx = 0;
        u64 *count = block_count.lookup(&idx);
        if (count) {
            __sync_fetch_and_add(count, 1);
        }
        bpf_trace_printk("BLOCKED: AF_ALG socket attempt, pid=%u\\n",
                         bpf_get_current_pid_tgid() >> 32);
        return -1;
    }
    return 0;
}
"""

def main():
    print("[*] Loading AF_ALG socket blocker eBPF program (LSM hook - actual blocking)")
    
    # Create BPF object
    try:
        b = BPF(text=bpf_source)
    except Exception as e:
        print(f"[!] Error loading BPF: {e}")
        print("[!] Ensure CAP_SYS_ADMIN, CAP_SYS_RESOURCE, CAP_PERFMON are available")
        print("[!] Run as: sudo python3 block-af-alg.py")
        sys.exit(1)
    
    # LSM_PROBE is auto-attached by BCC.
    print("[+] Attached LSM hook: socket_create")
    
    # Print trace output
    print("[+] Blocking AF_ALG socket attempts (Ctrl-C to stop)...")
    print("[+] Output from trace_pipe:")
    
    def signal_handler(sig, frame):
        # Print statistics
        print("\n[*] Unloading...")
        try:
            count_val = b["block_count"][0].value
            print(f"[+] Total AF_ALG socket() calls blocked (denied): {count_val}")
        except Exception:
            pass
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    
    # Read trace output
    b.trace_print()

if __name__ == "__main__":
    main()
