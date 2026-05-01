/* 
 * Standalone eBPF program to block AF_ALG sockets
 * Compile with: clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -c block_af_alg.c -o block_af_alg.o
 * Load with: sudo bpftool prog loadall block_af_alg.o /sys/fs/bpf/block_af_alg autoattach
 * Note: This is an LSM program (not XDP/kprobe). Kernel must support BPF LSM.
 */

#include <linux/bpf.h>
#include <linux/socket.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#define AF_ALG 38
#define EPERM 1

/* Map to store statistics */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 10);
    __type(key, __u32);
    __type(value, __u64);
} af_alg_stats SEC(".maps");

/* LSM hook: socket_create
 * Blocks socket() calls when family == AF_ALG.
 * Returning negative errno from LSM hooks is the supported deny mechanism.
 */
SEC("lsm/socket_create")
int BPF_PROG(trace_socket_create, int family, int type, int protocol, int kern) {
    
    if (family == AF_ALG) {
        __u32 idx = 0;
        __u64 *val = bpf_map_lookup_elem(&af_alg_stats, &idx);
        if (val) {
            __sync_fetch_and_add(val, 1);
        }
        
        // Log the event - it will go to /sys/kernel/tracing/trace_pipe
        bpf_printk("BLOCKED: AF_ALG socket attempt, pid=%d uid=%d",
                   bpf_get_current_pid_tgid() >> 32,
                   bpf_get_current_uid_gid() & 0xFFFFFFFF);

        // Deny the socket creation.
        return -EPERM;
    }

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
