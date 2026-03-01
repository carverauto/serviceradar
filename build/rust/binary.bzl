load("@rules_rust//rust:defs.bzl", "rust_binary")

def build_binary_opt(name, srcs, deps = [], visibility = ["//visibility:public"]):
    # Build optimized Rust binary
    rust_binary(
        name = name,
        srcs = srcs,
        crate_root = "src/main.rs",
        rustc_flags = select({
            "//:release": [
                #  Somehow the standard Rust lto flag doesn't work anymore beginning with rules rust 0.56.0
                "-Clink-arg=-flto",
                "-Clink-arg=-s",
                "-Ccodegen-units=1",
                "-Cpanic=abort",
                "-Copt-level=3",
                "-Cstrip=symbols",
                # "-Ctarget-cpu=native", # Only use this when the build CPU is the same as the target CPU
            ],
            "//conditions:default": [
                "-Copt-level=0",
            ],
        }),
        tags = [
            name,
            "binary",
        ],
        deps = deps,
        visibility = visibility,
    )
