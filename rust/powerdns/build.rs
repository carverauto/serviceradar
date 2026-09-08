fn main() {
    prost_build::Config::new()
        .compile_protos(&["proto/dnsmessage.proto"], &["proto"])
        .expect("compile PowerDNS dnsmessage.proto");
}
