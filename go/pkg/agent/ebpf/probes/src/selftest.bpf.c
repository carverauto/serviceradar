// SPDX-License-Identifier: Dual MIT/GPL

#define SEC(name) __attribute__((section(name), used))

SEC("tracepoint/syscalls/sys_enter_execve")
int sr_selftest_exec(void *ctx) {
    return 0;
}

char __license[] SEC("license") = "Dual MIT/GPL";
