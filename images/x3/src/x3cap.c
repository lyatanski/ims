// SPDX-License-Identifier: (BSD-2-Clause OR GPL-2.0)
/* x3cap: loads and attaches the X3 capture program (bpf/x3_kern.c) and
 * drains its ring buffer, and manages its target map from the command line.
 *
 *   x3cap run -i IFACE [-d DIR] [-v]       load, pin the maps in DIR, attach
 *                                           to IFACE's tc ingress and egress
 *   x3cap add ADDR PORT TASK [bi|uni] [-d DIR]
 *   x3cap del ADDR PORT [-d DIR]
 *   x3cap list [-d DIR]
 *   x3cap stats [-d DIR]
 *
 * The packets are only counted here (and printed with -v): wrapping them into
 * X3 PDUs (ETSI TS 103 221-2) and delivering them to the MDF3 is the agent's
 * job, which is to replace "run". "add" and "del" stand in for its LI_T3
 * triggers.
 *
 * -v prints the addresses of intercepted media, which identify the target's
 * call: lab use only.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <net/if.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/socket.h>
#include <unistd.h>

#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/udp.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "x3_abi.h"

/* The skeleton embeds the BPF object as one very long string literal */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Woverlength-strings"
#include "x3_kern.skel.h"
#pragma clang diagnostic pop

#define DEFAULT_DIR "/sys/fs/bpf/x3"
#ifndef BPF_FS_MAGIC
#define BPF_FS_MAGIC 0xcafe4a11
#endif
/* Fixed, so that a run replaces the filters a crashed one left behind
 * instead of adding a second pair */
#define TC_HANDLE   0x58
#define TC_PRIORITY 0x58

static const char* const map_names[] = {"x3_targets", "x3_events", "x3_stats"};

static volatile sig_atomic_t stop;
static bool                  verbose;
static unsigned long long    events;

/* libbpf's warnings, less the kernel's answer to creating the clsact qdisc
 * when it is there already, which is not an error */
static int libbpf_print(enum libbpf_print_level level, const char* fmt, va_list ap)
{
    if (level == LIBBPF_DEBUG || strstr(fmt, "Kernel error message") != NULL)
        return 0;
    return vfprintf(stderr, fmt, ap);
}

static void on_signal(int sig)
{
    (void)sig;
    stop = 1;
}

static int pin_path(char* buf, size_t len, const char* dir, const char* name)
{
    int n = snprintf(buf, len, "%s/%s", dir, name);
    return n > 0 && (size_t)n < len ? 0 : -1;
}

/* bpffs at /sys/fs/bpf, mounting it when the container has none */
static int ensure_bpffs(const char* dir)
{
    struct statfs st;
    if (statfs("/sys/fs/bpf", &st) == 0 && st.f_type == BPF_FS_MAGIC)
        goto mkdir;
    if (mount("bpf", "/sys/fs/bpf", "bpf", 0, NULL) < 0) {
        fprintf(stderr, "x3cap: no bpffs at /sys/fs/bpf and cannot mount one: %s\n",
                strerror(errno));
        return -1;
    }
mkdir:
    if (mkdir(dir, 0700) < 0 && errno != EEXIST) {
        fprintf(stderr, "x3cap: mkdir %s: %s\n", dir, strerror(errno));
        return -1;
    }
    return 0;
}

/* Bytes before the IP header on the interface, from its ARPHRD type */
static int l2_len(const char* ifname)
{
    char path[128];
    int  type = -1;
    snprintf(path, sizeof(path), "/sys/class/net/%s/type", ifname);
    FILE* f = fopen(path, "r");
    if (f) {
        if (fscanf(f, "%d", &type) != 1)
            type = -1;
        fclose(f);
    }
    switch (type) {
    case 1:   /* ARPHRD_ETHER */
    case 772: /* ARPHRD_LOOPBACK */
        return ETH_HLEN;
    case 65534: /* ARPHRD_NONE: tun, wireguard */
        return 0;
    default:
        fprintf(stderr, "x3cap: %s: unsupported link type %d\n", ifname, type);
        return -1;
    }
}

static int tc_attach(int ifindex, enum bpf_tc_attach_point ap, int prog_fd)
{
    LIBBPF_OPTS(bpf_tc_hook, hook, .ifindex = ifindex, .attach_point = ap);
    LIBBPF_OPTS(bpf_tc_opts, opts, .handle = TC_HANDLE, .priority = TC_PRIORITY,
                .prog_fd = prog_fd, .flags = BPF_TC_F_REPLACE);

    int rc = bpf_tc_hook_create(&hook);
    if (rc && rc != -EEXIST)
        return rc;
    return bpf_tc_attach(&hook, &opts);
}

static void tc_detach(int ifindex, enum bpf_tc_attach_point ap)
{
    LIBBPF_OPTS(bpf_tc_hook, hook, .ifindex = ifindex, .attach_point = ap);
    LIBBPF_OPTS(bpf_tc_opts, opts, .handle = TC_HANDLE, .priority = TC_PRIORITY);
    /* The clsact qdisc stays: other programs may have filters on it */
    bpf_tc_detach(&hook, &opts);
}

static void print_event(const struct x3_event* ev)
{
    char     s[INET6_ADDRSTRLEN] = "?", d[INET6_ADDRSTRLEN] = "?";
    unsigned sp = 0, dp = 0;

    if (ev->cap_len >= sizeof(struct iphdr) && (ev->data[0] >> 4) == 4) {
        const struct iphdr* ip = (const void*)ev->data;
        inet_ntop(AF_INET, &ip->saddr, s, sizeof(s));
        inet_ntop(AF_INET, &ip->daddr, d, sizeof(d));
        unsigned off = ip->ihl * 4u;
        if (ev->cap_len >= off + sizeof(struct udphdr)) {
            const struct udphdr* udp = (const void*)(ev->data + off);
            sp = ntohs(udp->source);
            dp = ntohs(udp->dest);
        }
    } else if (ev->cap_len >= sizeof(struct ipv6hdr) + sizeof(struct udphdr)) {
        const struct ipv6hdr* ip6 = (const void*)ev->data;
        const struct udphdr*  udp = (const void*)(ev->data + sizeof(*ip6));
        inet_ntop(AF_INET6, &ip6->saddr, s, sizeof(s));
        inet_ntop(AF_INET6, &ip6->daddr, d, sizeof(d));
        sp = ntohs(udp->source);
        dp = ntohs(udp->dest);
    }
    printf("task %u %s %s [%s]:%u -> [%s]:%u len %u cap %u\n", ev->task,
           ev->match == X3_MATCH_DST ? "dst" : "src",
           ev->ingress ? "ingress" : "egress", s, sp, d, dp, ev->pkt_len,
           ev->cap_len);
    fflush(stdout);
}

static int on_event(void* ctx, void* data, size_t len)
{
    (void)ctx;
    if (len < sizeof(struct x3_event))
        return 0;
    events++;
    if (verbose)
        print_event(data);
    return 0;
}

static int cmd_run(const char* ifname, const char* dir)
{
    char                path[256];
    struct x3_kern_bpf* skel     = NULL;
    struct ring_buffer* rb       = NULL;
    bool                in_att   = false, eg_att = false;
    int                 rc       = 1;
    int                 ifindex  = (int)if_nametoindex(ifname);
    int                 l2       = l2_len(ifname);

    if (!ifindex) {
        fprintf(stderr, "x3cap: no interface %s\n", ifname);
        return 1;
    }
    if (l2 < 0 || ensure_bpffs(dir) < 0)
        return 1;

    /* Pins left by a run that did not exit cleanly would keep its targets */
    for (size_t i = 0; i < sizeof(map_names) / sizeof(*map_names); i++)
        if (pin_path(path, sizeof(path), dir, map_names[i]) == 0)
            unlink(path);

    skel = x3_kern_bpf__open();
    if (!skel) {
        fprintf(stderr, "x3cap: open: %s\n", strerror(errno));
        return 1;
    }
    skel->rodata->x3_l2_len = (__u32)l2;
    if (x3_kern_bpf__load(skel)) {
        fprintf(stderr, "x3cap: load failed\n");
        goto out;
    }

    struct bpf_map* maps[] = {skel->maps.x3_targets, skel->maps.x3_events,
                              skel->maps.x3_stats};
    for (size_t i = 0; i < sizeof(maps) / sizeof(*maps); i++) {
        if (pin_path(path, sizeof(path), dir, map_names[i]) < 0
            || bpf_map__pin(maps[i], path)) {
            fprintf(stderr, "x3cap: pin %s failed\n", map_names[i]);
            goto out;
        }
    }

    if (tc_attach(ifindex, BPF_TC_INGRESS, bpf_program__fd(skel->progs.x3_ingress))) {
        fprintf(stderr, "x3cap: attach to %s ingress failed\n", ifname);
        goto out;
    }
    in_att = true;
    if (tc_attach(ifindex, BPF_TC_EGRESS, bpf_program__fd(skel->progs.x3_egress))) {
        fprintf(stderr, "x3cap: attach to %s egress failed\n", ifname);
        goto out;
    }
    eg_att = true;

    rb = ring_buffer__new(bpf_map__fd(skel->maps.x3_events), on_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "x3cap: ring buffer: %s\n", strerror(errno));
        goto out;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    printf("x3cap: attached to %s (ifindex %d, l2 %d), maps in %s\n", ifname,
           ifindex, l2, dir);
    fflush(stdout);

    while (!stop) {
        int n = ring_buffer__poll(rb, 1000);
        if (n < 0 && n != -EINTR) {
            fprintf(stderr, "x3cap: poll: %s\n", strerror(-n));
            goto out;
        }
    }
    rc = 0;

out:
    /* Detach and unpin: no target outlives the process */
    if (eg_att)
        tc_detach(ifindex, BPF_TC_EGRESS);
    if (in_att)
        tc_detach(ifindex, BPF_TC_INGRESS);
    for (size_t i = 0; i < sizeof(map_names) / sizeof(*map_names); i++)
        if (pin_path(path, sizeof(path), dir, map_names[i]) == 0)
            unlink(path);
    ring_buffer__free(rb);
    x3_kern_bpf__destroy(skel);
    printf("x3cap: detached, %llu packets captured\n", events);
    return rc;
}

static int open_map(const char* dir, const char* name)
{
    char path[256];
    if (pin_path(path, sizeof(path), dir, name) < 0)
        return -1;
    int fd = bpf_obj_get(path);
    if (fd < 0)
        fprintf(stderr, "x3cap: %s: %s (is \"x3cap run\" up?)\n", path, strerror(errno));
    return fd;
}

static int parse_key(const char* addr, const char* port, struct x3_key* key)
{
    char*         end;
    unsigned long p = strtoul(port, &end, 10);

    memset(key, 0, sizeof(*key));
    if (*end || p == 0 || p > 65535) {
        fprintf(stderr, "x3cap: bad port %s\n", port);
        return -1;
    }
    key->port = htons((__u16)p);
    if (inet_pton(AF_INET, addr, key->addr) == 1) {
        key->family = AF_INET;
    } else if (inet_pton(AF_INET6, addr, key->addr) == 1) {
        key->family = AF_INET6;
    } else {
        fprintf(stderr, "x3cap: bad address %s\n", addr);
        return -1;
    }
    return 0;
}

static int cmd_add(char** argv, int argc, const char* dir)
{
    struct x3_key    key;
    struct x3_target val = {.scope = X3_BIDIRECTIONAL};
    char*            end;

    if (argc < 3 || argc > 4 || parse_key(argv[0], argv[1], &key) < 0)
        return 2;
    unsigned long task = strtoul(argv[2], &end, 10);
    if (*end || task > 0xffffffffUL) {
        fprintf(stderr, "x3cap: bad task %s\n", argv[2]);
        return 2;
    }
    val.task = (__u32)task;
    if (argc == 4) {
        if (strcmp(argv[3], "uni") == 0)
            val.scope = X3_UNIDIRECTIONAL;
        else if (strcmp(argv[3], "bi") != 0)
            return 2;
    }
    int fd = open_map(dir, "x3_targets");
    if (fd < 0)
        return 1;
    if (bpf_map_update_elem(fd, &key, &val, BPF_ANY)) {
        fprintf(stderr, "x3cap: add: %s\n", strerror(errno));
        return 1;
    }
    return 0;
}

static int cmd_del(char** argv, int argc, const char* dir)
{
    struct x3_key key;
    if (argc != 2 || parse_key(argv[0], argv[1], &key) < 0)
        return 2;
    int fd = open_map(dir, "x3_targets");
    if (fd < 0)
        return 1;
    if (bpf_map_delete_elem(fd, &key)) {
        fprintf(stderr, "x3cap: del: %s\n", strerror(errno));
        return 1;
    }
    return 0;
}

static int cmd_list(const char* dir)
{
    struct x3_key    key, next;
    struct x3_target val;
    char             a[INET6_ADDRSTRLEN];
    int              fd = open_map(dir, "x3_targets");

    if (fd < 0)
        return 1;
    void* prev = NULL;
    while (bpf_map_get_next_key(fd, prev, &next) == 0) {
        if (bpf_map_lookup_elem(fd, &next, &val) == 0) {
            inet_ntop(next.family == AF_INET ? AF_INET : AF_INET6, next.addr, a, sizeof(a));
            printf("[%s]:%u task %u %s\n", a, ntohs(next.port), val.task,
                   val.scope == X3_BIDIRECTIONAL ? "bi" : "uni");
        }
        key  = next;
        prev = &key;
    }
    return 0;
}

static int cmd_stats(const char* dir)
{
    static const char* const names[X3_STAT_MAX] = {"captured", "dropped", "truncated"};
    int                      ncpu               = libbpf_num_possible_cpus();
    int                      fd                 = open_map(dir, "x3_stats");

    if (fd < 0 || ncpu <= 0)
        return 1;
    __u64* v = calloc((size_t)ncpu, sizeof(*v));
    if (!v)
        return 1;
    for (__u32 i = 0; i < X3_STAT_MAX; i++) {
        unsigned long long sum = 0;
        if (bpf_map_lookup_elem(fd, &i, v) == 0)
            for (int c = 0; c < ncpu; c++)
                sum += v[c];
        printf("%s %llu\n", names[i], sum);
    }
    free(v);
    return 0;
}

static void usage(void)
{
    fprintf(stderr,
            "usage: x3cap run -i IFACE [-d DIR] [-v]\n"
            "       x3cap add ADDR PORT TASK [bi|uni] [-d DIR]\n"
            "       x3cap del ADDR PORT [-d DIR]\n"
            "       x3cap list [-d DIR]\n"
            "       x3cap stats [-d DIR]\n"
            "DIR defaults to " DEFAULT_DIR "\n");
}

int main(int argc, char** argv)
{
    const char* dir    = DEFAULT_DIR;
    const char* ifname = NULL;
    int         opt;

    if (argc < 2) {
        usage();
        return 2;
    }
    const char* cmd = argv[1];
    optind          = 2;
    while ((opt = getopt(argc, argv, "+i:d:v")) != -1) {
        switch (opt) {
        case 'i':
            ifname = optarg;
            break;
        case 'd':
            dir = optarg;
            break;
        case 'v':
            verbose = true;
            break;
        default:
            usage();
            return 2;
        }
    }
    char** rest  = argv + optind;
    int    nrest = argc - optind;
    /* Options may also follow the positional arguments */
    if (nrest >= 2 && strcmp(rest[nrest - 2], "-d") == 0) {
        dir = rest[nrest - 1];
        nrest -= 2;
    }

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    libbpf_set_print(libbpf_print);
    if (strcmp(cmd, "run") == 0 && ifname && nrest == 0)
        return cmd_run(ifname, dir);
    if (strcmp(cmd, "add") == 0)
        return cmd_add(rest, nrest, dir);
    if (strcmp(cmd, "del") == 0)
        return cmd_del(rest, nrest, dir);
    if (strcmp(cmd, "list") == 0 && nrest == 0)
        return cmd_list(dir);
    if (strcmp(cmd, "stats") == 0 && nrest == 0)
        return cmd_stats(dir);
    usage();
    return 2;
}
