use std::{
    env,
    error::Error,
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn main() -> Result<(), Box<dyn Error>> {
    tonic_build::compile_protos("../proto/profiler/profiler.proto")?;

    let out_dir = PathBuf::from(env::var("OUT_DIR")?);
    let ebpf_dest = out_dir.join("profiler.bpf.o");

    println!("cargo:rerun-if-changed=../proto/profiler/profiler.proto");
    println!("cargo:rerun-if-changed=../ebpf_placeholder.o");
    println!("cargo:rerun-if-changed=../profiler-common/src");
    println!("cargo:rerun-if-changed=../profiler-ebpf/src");

    if let Some(explicit) = env::var_os("SERVICERADAR_EBPF_OBJECT") {
        copy_ebpf(Path::new(&explicit), &ebpf_dest)?;
    } else {
        let profile = env::var("PROFILE").unwrap_or_else(|_| "debug".to_owned());
        let release = profile == "release";
        if let Err(err) = build_ebpf(release, &ebpf_dest) {
            println!("cargo:warning=Falling back to placeholder eBPF object: {err}");
            copy_ebpf(Path::new("../ebpf_placeholder.o"), &ebpf_dest)?;
        }
    }

    println!(
        "cargo:rustc-env=SERVICERADAR_PROFILER_EBPF={}",
        ebpf_dest.display()
    );

    Ok(())
}

fn copy_ebpf(src: &Path, dest: &Path) -> Result<(), Box<dyn Error>> {
    if !src.exists() {
        return Err(format!("eBPF object not found at {}", src.display()).into());
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(src, dest)?;
    Ok(())
}

fn build_ebpf(release: bool, dest: &Path) -> Result<(), Box<dyn Error>> {
    let mut args = vec![
        "build",
        "--package",
        "profiler-ebpf",
        "--target",
        "bpfel-unknown-none",
        "-Z",
        "build-std=core",
    ];
    if release {
        args.push("--release");
    }

    let status = Command::new("cargo")
        .current_dir("..")
        .env_remove("RUSTUP_TOOLCHAIN")
        .args(&args)
        .status();

    match status {
        Ok(status) if status.success() => {
            let profile_dir = if release { "release" } else { "debug" };
            let artifact = Path::new("..")
                .join("target")
                .join("bpfel-unknown-none")
                .join(profile_dir)
                .join("profiler");
            copy_ebpf(&artifact, dest)
        }
        Ok(status) => Err(format!("cargo {:?} exited with status {}", args, status).into()),
        Err(err) => Err(Box::new(err)),
    }
}
