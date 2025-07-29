#[cfg(feature = "ebpf")]
use std::env;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Compile protobuf files
    tonic_build::configure()
        .disable_comments(".") // Disable comments to avoid doctest issues
        .compile_protos(
            &["proto/profiler/profiler.proto"],
            &["proto"],
        )?;

    // Compile eBPF program if the ebpf feature is enabled
    #[cfg(feature = "ebpf")]
    {
        compile_ebpf_program()?;
    }

    Ok(())
}

#[cfg(feature = "ebpf")]
fn compile_ebpf_program() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = env::var("OUT_DIR")?;
    let src_dir = env::var("CARGO_MANIFEST_DIR")?;
    
    println!("cargo:rerun-if-changed=src/bpf/profiler.rs");
    
    // Try to compile the eBPF program using bpf-linker if available
    let _ebpf_src = format!("{src_dir}/src/bpf/profiler.rs");
    let ebpf_out = format!("{out_dir}/profiler");
    
    // Check if we're on a Linux system with eBPF support
    if cfg!(target_os = "linux") {
        println!("cargo:warning=Compiling eBPF program for Linux target");
        
        // For now, we'll create a minimal eBPF bytecode placeholder
        // In a full implementation, you'd use tools like:
        // - bpf-linker to link eBPF programs
        // - llvm/clang to compile to eBPF bytecode
        // - aya-gen to generate bindings
        
        // Create a minimal placeholder eBPF program
        let placeholder_program = vec![0u8; 64]; // Minimal valid ELF header
        std::fs::write(&ebpf_out, placeholder_program)?;
        
        println!("cargo:warning=Created placeholder eBPF program at {ebpf_out}");
    } else {
        println!("cargo:warning=Not on Linux - creating empty eBPF placeholder");
        std::fs::write(&ebpf_out, [])?;
    }
    
    Ok(())
}