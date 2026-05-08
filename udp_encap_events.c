#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

static volatile sig_atomic_t stop;

struct event {
    __u32 pid;
    __u32 uid;
    __u32 level;
    __u32 optname;
    char comm[16];
    __u64 ts;
};

static void handle_signal(int sig)
{
    (void)sig;
    stop = 1;
}

static int find_ringbuf_map_fd(const char *wanted_name)
{
    __u32 id = 0;

    while (bpf_map_get_next_id(id, &id) == 0) {
        int fd;
        struct bpf_map_info info = {};
        __u32 info_len = sizeof(info);

        fd = bpf_map_get_fd_by_id(id);
        if (fd < 0) {
            continue;
        }

        if (bpf_obj_get_info_by_fd(fd, &info, &info_len) != 0) {
            close(fd);
            continue;
        }

        if (info.type == BPF_MAP_TYPE_RINGBUF &&
            strncmp((const char *)info.name, wanted_name, BPF_OBJ_NAME_LEN) == 0) {
            return fd;
        }

        close(fd);
    }

    return -1;
}

static int on_event(void *ctx, void *data, size_t size)
{
    const struct event *e = data;

    (void)ctx;
    if (size < sizeof(*e)) {
        fprintf(stderr, "short event: got %zu bytes\n", size);
        return 0;
    }

    printf("pid=%u uid=%u comm=%s level=%u optname=%u ts_ns=%llu\n",
           e->pid,
           e->uid,
           e->comm,
           e->level,
           e->optname,
           (unsigned long long)e->ts);
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv)
{
    const char *map_name = "events";
    int map_fd;
    struct ring_buffer *rb;

    if (argc == 2) {
        map_name = argv[1];
    } else if (argc > 2) {
        fprintf(stderr, "Usage: %s [map_name]\n", argv[0]);
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    map_fd = find_ringbuf_map_fd(map_name);
    if (map_fd < 0) {
        fprintf(stderr,
                "ringbuf map '%s' not found; ensure blocker service is running\n",
                map_name);
        return 1;
    }

    rb = ring_buffer__new(map_fd, on_event, NULL, NULL);
    close(map_fd);
    if (!rb) {
        fprintf(stderr, "failed to create ring buffer consumer\n");
        return 1;
    }

    printf("listening for UDP_ENCAP events on ringbuf map '%s'...\n", map_name);
    while (!stop) {
        int err = ring_buffer__poll(rb, 1000);
        if (err == -EINTR) {
            break;
        }
        if (err < 0) {
            fprintf(stderr, "ring_buffer__poll failed: %d\n", err);
            ring_buffer__free(rb);
            return 1;
        }
    }

    ring_buffer__free(rb);
    return 0;
}
