// SPDX-License-Identifier: (BSD-2-Clause OR GPL-2.0)
/* X3 capture: the media side of the CC-POI (TS 33.127 7.4.4, TS 33.128
 * 7.12.6). Two BPF_PROG_TYPE_SCHED_CLS programs, attached to the clsact
 * qdisc of the media node's core-side interface by the loader.
 *
 * x3_targets holds the media endpoints under interception, filled from the
 * CC-TF's LI_T3 triggers. A UDP packet whose destination is one of them is
 * copied on ingress, and on egress one whose source is one of a
 * Bidirectional trigger. The copy is the IP packet, from its header on,
 * pushed to the x3_events ring buffer for the agent to wrap into X3 PDUs.
 *
 * Every packet goes on unchanged, captured or not: interception must never
 * affect the service (TS 33.128 5.2.1).
 *
 * Not matched: a non-first IPv4 fragment (it has no UDP header), and IPv6
 * with extension headers before UDP. Neither is usual for RTP.
 */

#include <linux/types.h>
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#include "x3_abi.h"

#define AF_INET  2
#define AF_INET6 10
#define IP_OFFSET_MASK 0x1fff

char LICENSE[] SEC("license") = "Dual BSD/GPL";

/* Bytes before the IP header: 14 on Ethernet (and loopback), 0 on a raw-IP
 * device. Set by the loader before the load */
const volatile __u32 x3_l2_len = ETH_HLEN;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, struct x3_key);
    __type(value, struct x3_target);
    __uint(max_entries, X3_MAX_TARGETS);
} x3_targets SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, X3_RINGBUF_BYTES);
} x3_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, X3_STAT_MAX);
} x3_stats SEC(".maps");

static __always_inline void count(__u32 stat)
{
    __u64* c = bpf_map_lookup_elem(&x3_stats, &stat);
    if (c)
        (*c)++;
}

static __always_inline void capture(struct __sk_buff* skb, __u32 l3_off,
                                    __u32 task, __u8 match, __u8 ingress)
{
    struct x3_event* ev = bpf_ringbuf_reserve(&x3_events, sizeof(*ev), 0);
    if (!ev) {
        count(X3_STAT_DROPPED);
        return;
    }

    __u32 pkt_len = skb->len - l3_off;
    __u32 len     = pkt_len;
    if (len > X3_SNAPLEN) {
        len = X3_SNAPLEN;
        count(X3_STAT_TRUNCATED);
    }
    /* The parse already read an IP and a UDP header there, so len is never
     * 0; the check is for the verifier */
    if (len < 1 || bpf_skb_load_bytes(skb, l3_off, ev->data, len) < 0) {
        bpf_ringbuf_discard(ev, 0);
        count(X3_STAT_DROPPED);
        return;
    }

    ev->ts_boot_ns = bpf_ktime_get_boot_ns();
    ev->task       = task;
    ev->pkt_len    = pkt_len;
    ev->ifindex    = skb->ifindex;
    ev->cap_len    = len;
    ev->match      = match;
    ev->ingress    = ingress;
    bpf_ringbuf_submit(ev, 0);
    count(X3_STAT_CAPTURED);
}

/* The source and destination endpoints of a UDP packet. 0 when it is not
 * one this program can match */
static __always_inline int parse(struct __sk_buff* skb, __u32* l3_off,
                                 struct x3_key* src, struct x3_key* dst)
{
    struct udphdr udp;
    __u32         l4_off;

    *l3_off = x3_l2_len;
    if (skb->protocol == bpf_htons(ETH_P_IP)) {
        struct iphdr ip;
        if (bpf_skb_load_bytes(skb, *l3_off, &ip, sizeof(ip)) < 0)
            return 0;
        if (ip.version != 4 || ip.ihl < 5 || ip.protocol != IPPROTO_UDP)
            return 0;
        if (ip.frag_off & bpf_htons(IP_OFFSET_MASK))
            return 0;
        l4_off      = *l3_off + ip.ihl * 4;
        src->family = AF_INET;
        dst->family = AF_INET;
        __builtin_memcpy(src->addr, &ip.saddr, 4);
        __builtin_memcpy(dst->addr, &ip.daddr, 4);
    } else if (skb->protocol == bpf_htons(ETH_P_IPV6)) {
        struct ipv6hdr ip6;
        if (bpf_skb_load_bytes(skb, *l3_off, &ip6, sizeof(ip6)) < 0)
            return 0;
        if (ip6.version != 6 || ip6.nexthdr != IPPROTO_UDP)
            return 0;
        l4_off      = *l3_off + sizeof(ip6);
        src->family = AF_INET6;
        dst->family = AF_INET6;
        __builtin_memcpy(src->addr, &ip6.saddr, 16);
        __builtin_memcpy(dst->addr, &ip6.daddr, 16);
    } else {
        return 0;
    }

    if (bpf_skb_load_bytes(skb, l4_off, &udp, sizeof(udp)) < 0)
        return 0;
    src->port = udp.source;
    dst->port = udp.dest;
    return 1;
}

/* TC_ACT_UNSPEC hands the packet to the next filter on the hook, if any,
 * as if this one were not there */
SEC("tc")
int x3_ingress(struct __sk_buff* skb)
{
    struct x3_key src = {}, dst = {};
    __u32         l3_off;

    if (!parse(skb, &l3_off, &src, &dst))
        return TC_ACT_UNSPEC;
    struct x3_target* t = bpf_map_lookup_elem(&x3_targets, &dst);
    if (t)
        capture(skb, l3_off, t->task, X3_MATCH_DST, 1);
    return TC_ACT_UNSPEC;
}

SEC("tc")
int x3_egress(struct __sk_buff* skb)
{
    struct x3_key src = {}, dst = {};
    __u32         l3_off;

    if (!parse(skb, &l3_off, &src, &dst))
        return TC_ACT_UNSPEC;
    struct x3_target* t = bpf_map_lookup_elem(&x3_targets, &src);
    if (t && t->scope == X3_BIDIRECTIONAL)
        capture(skb, l3_off, t->task, X3_MATCH_SRC, 0);
    return TC_ACT_UNSPEC;
}
