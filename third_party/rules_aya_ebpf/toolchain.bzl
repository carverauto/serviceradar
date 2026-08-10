"""Public API: declare an aya eBPF toolchain."""

load(
    "//private:toolchain.bzl",
    _AyaEbpfToolchainInfo = "AyaEbpfToolchainInfo",
    _aya_ebpf_toolchain = "aya_ebpf_toolchain",
)

AyaEbpfToolchainInfo = _AyaEbpfToolchainInfo
aya_ebpf_toolchain = _aya_ebpf_toolchain
