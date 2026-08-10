"""Public API: build a Rust aya eBPF program into a BPF object."""

load(
    "//private:ebpf_object.bzl",
    _ebpf_object = "ebpf_object",
)

ebpf_object = _ebpf_object
