/* SPDX-License-Identifier: (BSD-2-Clause OR GPL-2.0) */
/* What the X3 capture program and its userspace share: the map layouts and
 * the ring-buffer record. */
#ifndef X3_ABI_H
#define X3_ABI_H

#include <linux/types.h>

/* Media streams under interception at once */
#define X3_MAX_TARGETS 65536
/* Bytes of each IP packet copied out. A longer packet is truncated, and
 * counted, which the agent reports as a fault: RTP is far shorter */
#define X3_SNAPLEN 2048
#define X3_RINGBUF_BYTES (8u << 20)

/* TS 33.128 7.12.6.2: Unidirectional matches the target address and port as
 * the destination only. Bidirectional also matches them as the source of the
 * packets going the other way */
enum x3_scope {
    X3_UNIDIRECTIONAL = 0,
    X3_BIDIRECTIONAL  = 1,
};

/* Which end of the packet matched: its destination (media towards the target
 * address and port, seen on tc ingress) or its source (media from it, seen
 * on tc egress) */
enum x3_match {
    X3_MATCH_DST = 1,
    X3_MATCH_SRC = 2,
};

/* x3_targets key: one media endpoint of this node, normally the address and
 * port rtpengine took for the stream on its core side */
struct x3_key {
    __u8   family; /* AF_INET or AF_INET6 */
    __u8   pad;
    __be16 port;
    __u8   addr[16]; /* IPv4 in the first 4 bytes, the rest zero */
};

/* x3_targets value */
struct x3_target {
    __u32 task;  /* the agent's handle for the Task (XID, destination, ...) */
    __u8  scope; /* enum x3_scope */
    __u8  pad[3];
};

/* x3_events record: one intercepted IP packet, from its IP header on. That
 * is payload format 5 or 6 of an X3 PDU (TS 33.128 7.12.6.3) */
struct x3_event {
    __u64 ts_boot_ns; /* CLOCK_BOOTTIME of the capture */
    __u32 task;
    __u32 pkt_len; /* the whole IP packet */
    __u32 ifindex;
    __u16 cap_len; /* bytes of it in data[] */
    __u8  match;   /* enum x3_match */
    __u8  ingress; /* 1 tc ingress, 0 tc egress */
    __u8  data[X3_SNAPLEN];
};

/* x3_stats, per CPU */
enum x3_stat {
    X3_STAT_CAPTURED  = 0,
    X3_STAT_DROPPED   = 1, /* ring buffer full or packet unreadable */
    X3_STAT_TRUNCATED = 2, /* longer than X3_SNAPLEN */
    X3_STAT_MAX,
};

#endif
