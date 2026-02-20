use super::*;
use crate::flowgger::config::Config;
use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use crate::flowgger::splitter::{
    CapnpSplitter, LineSplitter, NulSplitter, Splitter, SyslenSplitter,
};
use may::net::{TcpListener, TcpStream};
use std::io::BufReader;
use std::net::SocketAddr;
use std::sync::mpsc::SyncSender;

pub struct TcpCoInput {
    listen: String,
    tcp_config: TcpConfig,
}

impl TcpCoInput {
    pub fn new(config: &Config) -> TcpCoInput {
        let (tcp_config, listen, _timeout) = config_parse(&config);
        TcpCoInput { listen, tcp_config }
    }
}

impl Input for TcpCoInput {
    fn accept(
        &self,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<Decoder + Send>,
        encoder: Box<Encoder + Send>,
    ) {
        let tcp_config = self.tcp_config.clone();
        may::config().set_workers(tcp_config.threads);

        let listen: SocketAddr = self.listen.parse().unwrap();
        let listener = TcpListener::bind(&listen).unwrap();

        while let Ok((socket, _)) = listener.accept() {
            let tx = tx.clone();
            let (decoder, encoder) = (decoder.clone_boxed(), encoder.clone_boxed());
            let tcp_config = tcp_config.clone();
            go!(move || {
                handle_client(socket, tx, decoder, encoder, tcp_config);
            });
        }
    }
}

fn handle_client(
    client: TcpStream,
    tx: SyncSender<Vec<u8>>,
    decoder: Box<Decoder>,
    encoder: Box<Encoder>,
    tcp_config: TcpConfig,
) {
    if let Ok(peer_addr) = client.peer_addr() {
        println!("Connection over TCP from [{}]", peer_addr);
    }
    let reader = BufReader::new(client);
    let splitter = match &tcp_config.framing as &str {
        "capnp" => Box::new(CapnpSplitter) as Box<Splitter<_>>,
        "line" => Box::new(LineSplitter) as Box<Splitter<_>>,
        "syslen" => Box::new(SyslenSplitter) as Box<Splitter<_>>,
        "nul" => Box::new(NulSplitter) as Box<Splitter<_>>,
        _ => panic!("Unsupported framing scheme"),
    };
    splitter.run(reader, tx, decoder, encoder);
}
