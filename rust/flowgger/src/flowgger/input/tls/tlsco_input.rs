use super::*;
use crate::flowgger::config::Config;
use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use crate::flowgger::splitter::{
    CapnpSplitter, LineSplitter, NulSplitter, Splitter, SyslenSplitter,
};
use may::net::{TcpListener, TcpStream};
use std::io::{stderr, BufReader, Write};
use std::net::SocketAddr;
use std::sync::mpsc::SyncSender;

pub struct TlsCoInput {
    listen: String,
    tls_config: TlsConfig,
}

impl TlsCoInput {
    pub fn new(config: &Config) -> TlsCoInput {
        let (tls_config, listen, _timeout) = config_parse(&config);
        TlsCoInput { listen, tls_config }
    }
}

impl Input for TlsCoInput {
    fn accept(
        &self,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<Decoder + Send>,
        encoder: Box<Encoder + Send>,
    ) {
        let tls_config = self.tls_config.clone();
        may::config().set_io_workers(tls_config.threads);

        let listen: SocketAddr = self.listen.parse().unwrap();
        let listener = TcpListener::bind(&listen).unwrap();

        while let Ok((socket, _)) = listener.accept() {
            let tx = tx.clone();
            let (decoder, encoder) = (decoder.clone_boxed(), encoder.clone_boxed());
            let tls_config = tls_config.clone();
            go!(move || {
                handle_client(socket, tx, decoder, encoder, tls_config);
            });
        }
    }
}

fn handle_client(
    client: TcpStream,
    tx: SyncSender<Vec<u8>>,
    decoder: Box<Decoder>,
    encoder: Box<Encoder>,
    tls_config: TlsConfig,
) {
    if let Ok(peer_addr) = client.peer_addr() {
        println!("Connection over TLS<coroutines> from [{}]", peer_addr);
    }
    let sslclient = match tls_config.acceptor.accept(client) {
        Err(_) => {
            let _ = writeln!(stderr(), "SSL handshake aborted by the client");
            return;
        }
        Ok(sslclient) => sslclient,
    };
    let reader = BufReader::new(sslclient);
    let splitter = match &tls_config.framing as &str {
        "capnp" => Box::new(CapnpSplitter) as Box<Splitter<_>>,
        "line" => Box::new(LineSplitter) as Box<Splitter<_>>,
        "syslen" => Box::new(SyslenSplitter) as Box<Splitter<_>>,
        "nul" => Box::new(NulSplitter) as Box<Splitter<_>>,
        _ => panic!("Unsupported framing scheme"),
    };
    splitter.run(reader, tx, decoder, encoder);
}
