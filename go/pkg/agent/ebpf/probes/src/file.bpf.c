// SPDX-License-Identifier: Dual MIT/GPL

#define SEC(name) __attribute__((section(name), used))
#define __uint(name, val) int (*name)[val]
#define __type(name, val) val *name
#define __always_inline inline __attribute__((always_inline))

#define BPF_MAP_TYPE_ARRAY 2
#define BPF_MAP_TYPE_RINGBUF 27

#define SR_FILE_PATH_SIZE 256
#define SR_FILE_OPERATION_OPEN 1
#define SR_FILE_OPERATION_ACCESS 2
#define SR_LOSS_KERNEL_DROPS 0
#define SR_LOSS_PARSER_FAILURES 1
#define SR_LOSS_COUNTERS 2

typedef unsigned char __u8;
typedef unsigned int __u32;
typedef unsigned long long __u64;
typedef int __s32;

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 20);
} sr_file_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, SR_LOSS_COUNTERS);
    __type(key, __u32);
    __type(value, __u64);
} sr_file_losses SEC(".maps");

struct sys_enter_openat_ctx {
    unsigned short common_type;
    __u8 common_flags;
    __u8 common_preempt_count;
    int common_pid;
    long syscall_nr;
    int dfd;
    const char *filename;
    int flags;
    unsigned short mode;
};

struct sys_enter_access_ctx {
    unsigned short common_type;
    __u8 common_flags;
    __u8 common_preempt_count;
    int common_pid;
    long syscall_nr;
    const char *filename;
    int mode;
};

struct sys_enter_faccessat_ctx {
    unsigned short common_type;
    __u8 common_flags;
    __u8 common_preempt_count;
    int common_pid;
    long syscall_nr;
    int dfd;
    const char *filename;
    int mode;
};

struct sr_file_event {
    __u64 timestamp_ns;
    __u32 pid;
    __u32 tid;
    __u32 uid;
    __u32 gid;
    __u32 operation;
    __u32 flags;
    __s32 result;
    char path[SR_FILE_PATH_SIZE];
};

static __u64 (*bpf_ktime_get_ns)(void) = (void *)5;
static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *)1;
static __u64 (*bpf_get_current_pid_tgid)(void) = (void *)14;
static __u64 (*bpf_get_current_uid_gid)(void) = (void *)15;
static long (*bpf_probe_read_user_str)(void *dst, __u32 size, const void *unsafe_ptr) = (void *)114;
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) = (void *)131;
static void (*bpf_ringbuf_submit)(void *data, __u64 flags) = (void *)132;

static __always_inline void sr_increment_file_loss(__u32 key) {
    __u64 *value = bpf_map_lookup_elem(&sr_file_losses, &key);

    if (value) {
        __sync_fetch_and_add(value, 1);
    }
}

static __always_inline int sr_emit_file_event(const char *path, __u32 operation, __u32 flags) {
    struct sr_file_event *event;
    __u64 pid_tgid;
    __u64 uid_gid;

    event = bpf_ringbuf_reserve(&sr_file_events, sizeof(*event), 0);
    if (!event) {
        sr_increment_file_loss(SR_LOSS_KERNEL_DROPS);
        return 0;
    }

    pid_tgid = bpf_get_current_pid_tgid();
    uid_gid = bpf_get_current_uid_gid();

    event->timestamp_ns = bpf_ktime_get_ns();
    event->pid = pid_tgid >> 32;
    event->tid = (__u32)pid_tgid;
    event->uid = (__u32)uid_gid;
    event->gid = uid_gid >> 32;
    event->operation = operation;
    event->flags = flags;
    event->result = 0;

    if (bpf_probe_read_user_str(event->path, sizeof(event->path), path) <= 0) {
        sr_increment_file_loss(SR_LOSS_PARSER_FAILURES);
    }
    bpf_ringbuf_submit(event, 0);

    return 0;
}

SEC("tracepoint/syscalls/sys_enter_openat")
int sr_file_openat(struct sys_enter_openat_ctx *ctx) {
    return sr_emit_file_event(ctx->filename, SR_FILE_OPERATION_OPEN, (__u32)ctx->flags);
}

SEC("tracepoint/syscalls/sys_enter_access")
int sr_file_access(struct sys_enter_access_ctx *ctx) {
    return sr_emit_file_event(ctx->filename, SR_FILE_OPERATION_ACCESS, (__u32)ctx->mode);
}

SEC("tracepoint/syscalls/sys_enter_faccessat")
int sr_file_faccessat(struct sys_enter_faccessat_ctx *ctx) {
    return sr_emit_file_event(ctx->filename, SR_FILE_OPERATION_ACCESS, (__u32)ctx->mode);
}

char __license[] SEC("license") = "Dual MIT/GPL";
