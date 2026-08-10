"""The aya eBPF toolchain: a nightly Rust sysroot plus a bpf-linker."""

TOOLCHAIN_TYPE = Label("//:toolchain_type")

AyaEbpfToolchainInfo = provider(
    doc = "Everything needed to compile a Rust aya eBPF program to a BPF object.",
    fields = {
        "installers": "rustup-dist `install.sh` scripts, run in order to assemble the sysroot.",
        "component_files": "depset of every file in the component archives.",
        "bpf_linker": "File: the bpf-linker binary used to link the BPF target.",
        "host_triple": "Rust target triple of the execution platform.",
        "target_triple": "Rust target triple of the BPF output (bpfel-unknown-none).",
    },
)

def _impl(ctx):
    # Assembled at action time rather than at fetch time: each rustup-dist
    # component ships an install.sh that merges itself into a shared --prefix,
    # and a repository rule cannot run one archive's installer over another
    # archive's output. Handing the action the installers plus every component
    # file keeps the assembly a declared, cacheable step.
    return [platform_common.ToolchainInfo(
        aya_ebpf = AyaEbpfToolchainInfo(
            installers = ctx.files.installers,
            component_files = depset(ctx.files.components),
            bpf_linker = ctx.file.bpf_linker,
            host_triple = ctx.attr.host_triple,
            target_triple = ctx.attr.target_triple,
        ),
    )]

aya_ebpf_toolchain = rule(
    implementation = _impl,
    doc = "Declares a usable aya eBPF toolchain. Pair with a `toolchain()` that " +
          "constrains it to the execution platforms its binaries can run on.",
    attrs = {
        "installers": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "`install.sh` from each rustup-dist component archive, in install order. " +
                  "rust-src must be among them: `-Z build-std=core` compiles core from " +
                  "source, because the tier-3 bpfel target ships no precompiled std.",
        ),
        "components": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Every file of each component archive. The installers copy out of these, " +
                  "so they have to be action inputs even though nothing names them directly.",
        ),
        "bpf_linker": attr.label(
            allow_single_file = True,
            mandatory = True,
            cfg = "exec",
            doc = "The bpf-linker binary. Statically bundles its own LLVM, so it needs " +
                  "nothing from the execution platform.",
        ),
        "host_triple": attr.string(
            mandatory = True,
            doc = "Rust target triple of the execution platform, e.g. x86_64-unknown-linux-gnu.",
        ),
        "target_triple": attr.string(
            default = "bpfel-unknown-none",
            doc = "Rust target triple of the emitted object.",
        ),
    },
    provides = [platform_common.ToolchainInfo],
)
