// SPDX-License-Identifier: Dual MIT/GPL

#define SEC(name) __attribute__((section(name), used))
#define __uint(name, val) int (*name)[val]
#define __type(name, val) val *name
#define __always_inline inline __attribute__((always_inline))

#define BPF_MAP_TYPE_ARRAY 2
#define BPF_MAP_TYPE_RINGBUF 27

#define SR_AF_INET 2
#define SR_AF_INET6 10
#define SR_LOSS_KERNEL_DROPS 0
#define SR_LOSS_PARSER_FAILURES 1
#define SR_LOSS_COUNTERS 2

typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;
typedef int __s32;

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 20);
} sr_network_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, SR_LOSS_COUNTERS);
    __type(key, __u32);
    __type(value, __u64);
} sr_network_losses SEC(".maps");

struct sys_enter_connect_ctx {
    unsigned short common_type;
    __u8 common_flags;
    __u8 common_preempt_count;
    int common_pid;
    long syscall_nr;
    int fd;
    const void *uservaddr;
    int addrlen;
};

struct sr_network_event {
    __u64 timestamp_ns;
    __u32 pid;
    __u32 tid;
    __u32 uid;
    __u32 gid;
    __u32 family;
    __u32 addr_len;
    __s32 result;
    __u8 dest_port[2];
    __u8 pad[2];
    __u8 dest_addr[16];
};

static __u64 (*bpf_ktime_get_ns)(void) = (void *)5;
static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *)1;
static __u64 (*bpf_get_current_pid_tgid)(void) = (void *)14;
static __u64 (*bpf_get_current_uid_gid)(void) = (void *)15;
static long (*bpf_probe_read_user)(void *dst, __u32 size, const void *unsafe_ptr) = (void *)112;
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) = (void *)131;
static void (*bpf_ringbuf_submit)(void *data, __u64 flags) = (void *)132;
static void (*bpf_ringbuf_discard)(void *data, __u64 flags) = (void *)133;

static __always_inline void sr_increment_network_loss(__u32 key) {
    __u64 *value = bpf_map_lookup_elem(&sr_network_losses, &key);

    if (value) {
        __sync_fetch_and_add(value, 1);
    }
}

SEC("tracepoint/syscalls/sys_enter_connect")
int sr_network_connect(struct sys_enter_connect_ctx *ctx) {
    struct sr_network_event *event;
    const __u8 *sockaddr;
    __u64 pid_tgid;
    __u64 uid_gid;
    __u16 family = 0;

    if (!ctx->uservaddr) {
        return 0;
    }
    sockaddr = (const __u8 *)ctx->uservaddr;
    if (bpf_probe_read_user(&family, sizeof(family), sockaddr) < 0) {
        sr_increment_network_loss(SR_LOSS_PARSER_FAILURES);
        return 0;
    }
    if (family != SR_AF_INET && family != SR_AF_INET6) {
        return 0;
    }

    event = bpf_ringbuf_reserve(&sr_network_events, sizeof(*event), 0);
    if (!event) {
        sr_increment_network_loss(SR_LOSS_KERNEL_DROPS);
        return 0;
    }

    pid_tgid = bpf_get_current_pid_tgid();
    uid_gid = bpf_get_current_uid_gid();

    event->timestamp_ns = bpf_ktime_get_ns();
    event->pid = pid_tgid >> 32;
    event->tid = (__u32)pid_tgid;
    event->uid = (__u32)uid_gid;
    event->gid = uid_gid >> 32;
    event->family = family;
    event->addr_len = (__u32)ctx->addrlen;
    event->result = 0;
    event->dest_port[0] = 0;
    event->dest_port[1] = 0;
    event->pad[0] = 0;
    event->pad[1] = 0;

#pragma unroll
    for (int i = 0; i < 16; i++) {
        event->dest_addr[i] = 0;
    }

    if (family == SR_AF_INET) {
        if (bpf_probe_read_user(event->dest_port, sizeof(event->dest_port), sockaddr + 2) < 0 ||
            bpf_probe_read_user(event->dest_addr, 4, sockaddr + 4) < 0) {
            sr_increment_network_loss(SR_LOSS_PARSER_FAILURES);
            bpf_ringbuf_discard(event, 0);
            return 0;
        }
    } else {
        if (bpf_probe_read_user(event->dest_port, sizeof(event->dest_port), sockaddr + 2) < 0 ||
            bpf_probe_read_user(event->dest_addr, sizeof(event->dest_addr), sockaddr + 8) < 0) {
            sr_increment_network_loss(SR_LOSS_PARSER_FAILURES);
            bpf_ringbuf_discard(event, 0);
            return 0;
        }
    }

    bpf_ringbuf_submit(event, 0);

    return 0;
}

char __license[] SEC("license") = "Dual MIT/GPL";
