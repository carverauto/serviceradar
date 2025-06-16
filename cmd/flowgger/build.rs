#[cfg(feature = "capnp-recompile")]
extern crate capnpc;

#[cfg(feature = "capnp-recompile")]
fn main() {
    ::capnpc::CompilerCommand::new()
        .src_prefix("src/flowgger")
        .file("record.capnp")
        .run()
        .expect("schema compiled comand");
}

#[cfg(not(feature = "capnp-recompile"))]
fn main() {}
