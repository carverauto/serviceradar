"""Compile a Rust aya eBPF program into a loadable BPF object."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:shell.bzl", "shell")
load(":toolchain.bzl", "TOOLCHAIN_TYPE")

_NO_TOOLCHAIN = """no aya eBPF toolchain matched this build's execution platform.

An eBPF object is a Linux kernel artifact, but *building* one is cross-compilation
to bpfel-unknown-none and does not itself require Linux -- rules_aya_ebpf simply has
no toolchain registered for the platform Bazel chose to run actions on.

Either build with an execution platform that has one (--config=ci dispatches to the
linux-x86_64 RBE workers), or register a toolchain for this platform: upstream ships
rustup-dist and bpf-linker builds for darwin too, so a Mac can produce the same object.
"""

def _linker_env_var(target_triple):
    # cargo reads the per-target linker from CARGO_TARGET_<TRIPLE>_LINKER, with the
    # triple upper-cased and dashes turned into underscores.
    return "CARGO_TARGET_{}_LINKER".format(target_triple.upper().replace("-", "_"))

def _vendor_root(vendor):
    # The vendor target must be declared in the package that IS the vendor root, so
    # the directory cargo needs is just that package's path. Deriving it from the
    # label beats pointing $(location ...) at an arbitrary file the package happens
    # to own and taking its dirname.
    return paths.join(vendor.label.workspace_root, vendor.label.package)

def _impl(ctx):
    toolchain = ctx.toolchains[TOOLCHAIN_TYPE]
    if toolchain == None:
        fail(_NO_TOOLCHAIN)
    aya = toolchain.aya_ebpf

    if not ctx.files.vendor:
        fail("vendor target {} is empty; the build is offline and resolves every crate from it".format(
            ctx.attr.vendor.label,
        ))

    out = ctx.actions.declare_file(ctx.attr.out or (ctx.label.name + ".o"))

    crate_dir = ctx.file.manifest.dirname
    vendor_dir = _vendor_root(ctx.attr.vendor)

    # Interpolated into a single-quoted shell assignment below, so the inner
    # quotes rustc needs around the cfg value are literal, not escaped.
    rustflags = [
        '--cfg bpf_target_arch="{}"'.format(ctx.attr.bpf_target_arch),
        "-C link-arg=--btf",
    ] + ctx.attr.rustflags

    script = """
set -euo pipefail
ROOT="$PWD"

work="$(mktemp -d "${{TMPDIR:-/tmp}}/rules_aya_ebpf.XXXXXX")"
trap 'rm -rf "$work"' EXIT
prefix="$work/toolchain"
mkdir -p "$prefix"

# 1. Assemble the nightly sysroot. Each rustup-dist component archive carries an
#    install.sh that merges that component into a shared --prefix.
for inst in {installers}; do
  bash "$ROOT/$inst" --prefix="$prefix" --disable-ldconfig >/dev/null 2>"$work/install.err" || {{
    echo "component install failed: $inst" >&2; cat "$work/install.err" >&2; exit 1; }}
done

cargo_bin="$prefix/bin/cargo"
rustc_bin="$prefix/bin/rustc"
[ -x "$cargo_bin" ] && [ -x "$rustc_bin" ] || {{
  echo "assembled toolchain has no cargo/rustc" >&2; ls -R "$prefix/bin" >&2 || true; exit 1; }}
# -Z build-std compiles core from source, so the sources must be in the sysroot.
[ -d "$prefix/lib/rustlib/src/rust/library/core" ] || {{
  echo "rust-src missing from the sysroot; -Z build-std=core cannot work" >&2; exit 1; }}

# 2. Stage the crate as an isolated workspace pointed at the vendored crates.
src="$work/crate"
mkdir -p "$src"
cp -R "$ROOT/{crate_dir}/." "$src/"
# The crate has to resolve on its own rather than as part of an enclosing Cargo
# workspace. Declaring [workspace] in the crate's own manifest is the better place
# for it -- that is what makes plain `cargo` usable in the source directory -- so
# only add one when the author has not. Appending unconditionally would be a TOML
# duplicate-key error for exactly the crates that got it right.
if ! grep -qE '^[[:space:]]*\\[workspace\\][[:space:]]*$' "$src/Cargo.toml"; then
  printf '\\n[workspace]\\n' >> "$src/Cargo.toml"
fi
mkdir -p "$src/.cargo"
cat > "$src/.cargo/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$ROOT/{vendor_dir}"
EOF

# 3. Build offline against the vendored crates, linking with bpf-linker.
export PATH="$prefix/bin:/usr/bin:/bin"
export CARGO_HOME="$work/cargo-home"
export CARGO_TARGET_DIR="$work/target"
export RUSTC="$rustc_bin"
export LD_LIBRARY_PATH="$prefix/lib:${{LD_LIBRARY_PATH:-}}"
export {linker_var}="$ROOT/{bpf_linker}"
export RUSTFLAGS='{rustflags}'
mkdir -p "$CARGO_HOME"

# cargo finds .cargo/config.toml by walking up from the working directory, so the
# vendored-source replacement only applies from inside the staged crate.
cd "$src"
"$cargo_bin" build \\
  --offline \\
  --locked \\
  --target {target_triple} \\
  -Z build-std=core \\
  --release \\
  --bin {bin_name}

cp "$CARGO_TARGET_DIR/{target_triple}/release/{bin_name}" "$ROOT/{out}"
""".format(
        installers = " ".join([shell.quote(f.path) for f in aya.installers]),
        crate_dir = crate_dir,
        vendor_dir = vendor_dir,
        linker_var = _linker_env_var(aya.target_triple),
        bpf_linker = aya.bpf_linker.path,
        rustflags = " ".join(rustflags),
        target_triple = aya.target_triple,
        bin_name = ctx.attr.bin_name,
        out = out.path,
    )

    ctx.actions.run_shell(
        inputs = depset(
            direct = ctx.files.srcs + ctx.files.vendor + [ctx.file.manifest],
            transitive = [aya.component_files],
        ),
        tools = [aya.bpf_linker],
        outputs = [out],
        command = script,
        mnemonic = "AyaEbpfObject",
        progress_message = "Building eBPF object %{label}",
    )

    return [DefaultInfo(files = depset([out]))]

ebpf_object = rule(
    implementation = _impl,
    doc = """Build a Rust aya eBPF program into a BPF object file.

Every input is Bazel-declared -- the nightly toolchain and linker come from the
resolved toolchain, the crates from a committed vendor tree -- so the action reads
nothing from the system PATH and needs no network. That is what makes it work
identically locally, in CI, and on remote execution.
""",
    attrs = {
        "manifest": attr.label(
            allow_single_file = ["Cargo.toml"],
            mandatory = True,
            doc = "The crate's Cargo.toml. Its directory is staged as the build root.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Crate sources: Cargo.lock, src/**, and any headers.",
        ),
        "vendor": attr.label(
            mandatory = True,
            doc = "Vendored crate tree for the offline build. Must be declared in the " +
                  "package that is the vendor root -- that package's path is what cargo " +
                  "gets as `[source.vendored-sources] directory`. Note that `-Z build-std` " +
                  "resolves the whole sysroot, so this has to include the std workspace's " +
                  "own crates.io dependencies, not just the program's.",
        ),
        "bin_name": attr.string(
            mandatory = True,
            doc = "The `[[bin]]` target to build.",
        ),
        "bpf_target_arch": attr.string(
            default = "x86_64",
            doc = "Value of the `bpf_target_arch` cfg aya switches its bindings on. This " +
                  "is the one genuinely arch-specific input to an otherwise portable object.",
        ),
        "rustflags": attr.string_list(
            doc = "Extra RUSTFLAGS, appended after the cfg and BTF flags.",
        ),
        "out": attr.string(
            doc = "Output filename. Defaults to <name>.o.",
        ),
    },
    # Optional so a missing toolchain is an authored explanation rather than
    # Bazel's bare "no matching toolchains found".
    toolchains = [config_common.toolchain_type(TOOLCHAIN_TYPE, mandatory = False)],
)
