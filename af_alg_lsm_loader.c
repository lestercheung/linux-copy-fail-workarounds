#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

static volatile sig_atomic_t stop;

static void handle_signal(int sig)
{
    (void)sig;
    stop = 1;
}

static int libbpf_log_fn(enum libbpf_print_level level, const char *fmt, va_list args)
{
    if (level == LIBBPF_DEBUG) {
        return 0;
    }
    return vfprintf(stderr, fmt, args);
}

static int bump_memlock_rlimit(void)
{
    struct rlimit rlim = {
        .rlim_cur = RLIM_INFINITY,
        .rlim_max = RLIM_INFINITY,
    };

    if (setrlimit(RLIMIT_MEMLOCK, &rlim) != 0) {
        return -errno;
    }

    return 0;
}

int main(int argc, char **argv)
{
    const char *obj_path = "obj/block_af_alg.o";
    struct bpf_object *obj = NULL;
    struct bpf_program *prog;
    struct bpf_link *links[16] = {0};
    int link_count = 0;
    int err;

    if (argc > 1) {
        obj_path = argv[1];
    }

    libbpf_set_print(libbpf_log_fn);

    err = bump_memlock_rlimit();
    if (err) {
        fprintf(stderr, "failed to raise memlock rlimit: %s\n", strerror(-err));
        return 1;
    }

    obj = bpf_object__open_file(obj_path, NULL);
    if (!obj) {
        fprintf(stderr, "failed to open BPF object: %s\n", obj_path);
        return 1;
    }

    err = bpf_object__load(obj);
    if (err) {
        fprintf(stderr, "failed to load BPF object: %s (err=%d)\n", obj_path, err);
        bpf_object__close(obj);
        return 1;
    }

    bpf_object__for_each_program(prog, obj) {
        const char *sec = bpf_program__section_name(prog);
        if (!sec || strncmp(sec, "lsm/", 4) != 0) {
            continue;
        }

        if (link_count >= (int)(sizeof(links) / sizeof(links[0]))) {
            fprintf(stderr, "too many programs to attach\n");
            err = -E2BIG;
            goto out;
        }

        links[link_count] = bpf_program__attach_lsm(prog);
        err = libbpf_get_error(links[link_count]);
        if (err) {
            links[link_count] = NULL;
            fprintf(stderr, "failed to attach LSM program '%s' (err=%d)\n",
                    bpf_program__name(prog), err);
            goto out;
        }

        printf("attached LSM program: %s (section: %s)\n",
               bpf_program__name(prog), sec);
        link_count++;
    }

    if (link_count == 0) {
        fprintf(stderr, "no LSM programs found in object: %s\n", obj_path);
        err = -ENOENT;
        goto out;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    printf("AF_ALG blocker is active. Press Ctrl+C to detach and exit.\n");
    while (!stop) {
        sleep(1);
    }

    err = 0;

out:
    for (int i = 0; i < link_count; i++) {
        bpf_link__destroy(links[i]);
    }
    bpf_object__close(obj);

    if (err) {
        return 1;
    }

    printf("detached all LSM links and exited cleanly.\n");
    return 0;
}
