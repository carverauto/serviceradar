// SPDX-License-Identifier: Dual MIT/GPL

#define SEC(name) __attribute__((section(name), used))
#define __uint(name, val) int (*name)[val]

#define BPF_MAP_TYPE_RINGBUF 27

#define SR_COMMAND_PATH_SIZE 256
#define SR_COMMAND_ARG_SIZE 128
#define SR_COMMAND_MAX_ARGS 8

typedef unsigned char __u8;
typedef unsigned int __u32;
typedef unsigned long long __u64;
typedef int __s32;

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 20);
} sr_command_events SEC(".maps");

struct sys_enter_execve_ctx {
    unsigned short common_type;
    __u8 common_flags;
    __u8 common_preempt_count;
    int common_pid;
    long syscall_nr;
    const char *filename;
    const char *const *argv;
    const char *const *envp;
};

struct sr_command_event {
    __u64 timestamp_ns;
    __u32 pid;
    __u32 tid;
    __u32 uid;
    __u32 gid;
    __u32 argc;
    __s32 result;
    char path[SR_COMMAND_PATH_SIZE];
    char argv[SR_COMMAND_MAX_ARGS][SR_COMMAND_ARG_SIZE];
};

static __u64 (*bpf_ktime_get_ns)(void) = (void *)5;
static __u64 (*bpf_get_current_pid_tgid)(void) = (void *)14;
static __u64 (*bpf_get_current_uid_gid)(void) = (void *)15;
static long (*bpf_probe_read_user)(void *dst, __u32 size, const void *unsafe_ptr) = (void *)112;
static long (*bpf_probe_read_user_str)(void *dst, __u32 size, const void *unsafe_ptr) = (void *)114;
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) = (void *)131;
static void (*bpf_ringbuf_submit)(void *data, __u64 flags) = (void *)132;

SEC("tracepoint/syscalls/sys_enter_execve")
int sr_command_execve(struct sys_enter_execve_ctx *ctx) {
    struct sr_command_event *event;
    __u64 pid_tgid;
    __u64 uid_gid;

    event = bpf_ringbuf_reserve(&sr_command_events, sizeof(*event), 0);
    if (!event) {
        return 0;
    }

    pid_tgid = bpf_get_current_pid_tgid();
    uid_gid = bpf_get_current_uid_gid();

    event->timestamp_ns = bpf_ktime_get_ns();
    event->pid = pid_tgid >> 32;
    event->tid = (__u32)pid_tgid;
    event->uid = (__u32)uid_gid;
    event->gid = uid_gid >> 32;
    event->argc = 0;
    event->result = 0;

    bpf_probe_read_user_str(event->path, sizeof(event->path), ctx->filename);

#pragma unroll
    for (int i = 0; i < SR_COMMAND_MAX_ARGS; i++) {
        const char *arg = 0;

        if (bpf_probe_read_user(&arg, sizeof(arg), &ctx->argv[i]) < 0 || !arg) {
            break;
        }
        if (bpf_probe_read_user_str(event->argv[i], sizeof(event->argv[i]), arg) > 0) {
            event->argc++;
        }
    }

    bpf_ringbuf_submit(event, 0);

    return 0;
}

char __license[] SEC("license") = "Dual MIT/GPL";
