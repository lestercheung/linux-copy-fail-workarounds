
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct socket;

char __license[] SEC("license") = "GPL";

/* UDP encapsulation constants */
#ifndef IPPROTO_UDP
#define IPPROTO_UDP      17
#endif
#ifndef EPERM
#define EPERM            1
#endif
#define UDP_ENCAP        100
#define UDP_ENCAP_ESPINUDP 2

/* Ringbuf map — mirrors xfrm_blocker.c */
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

struct event {
    __u32 pid;
    __u32 uid;
    __u32 level;
    __u32 optname;
    char  comm[16];
    __u64 ts;
};

/*
 * deny_espinudp - lsm/socket_setsockopt
 *
 * Blocks setsockopt(IPPROTO_UDP, UDP_ENCAP, ...) which the copyfail2 exploit
 * uses to enable UDP-encapsulated ESP on the receive socket (step 4 in the C
 * PoC).  Without this option set, the kernel will not demultiplex inbound UDP
 * packets to the XFRM ESP path, so even if the XFRM state were somehow
 * installed the splice-based memory-flip trick cannot deliver packets.
 */
SEC("lsm/socket_setsockopt")
int BPF_PROG(deny_espinudp, struct socket *sock, int level, int optname)
{
    struct event *e;
    __u32 pid;
    __u32 uid;

    /* Only care about the exact option the exploit sets */
    if (level == IPPROTO_UDP && optname == UDP_ENCAP) {
        pid = bpf_get_current_pid_tgid() >> 32;
        uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;

        /* Emit an event so user-space can audit the block */
        e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (e) {
            e->pid     = pid;
            e->uid     = uid;
            e->level   = (__u32)level;
            e->optname = (__u32)optname;
            e->ts      = bpf_ktime_get_ns();
            bpf_get_current_comm(&e->comm, sizeof(e->comm));
            bpf_ringbuf_submit(e, 0);
        }

        bpf_printk("BLOCKING: UDP_ENCAP/ESPINUDP setsockopt from PID=%u UID=%u",
                pid, uid);

        return -EPERM;
    }
    return 0;

}
