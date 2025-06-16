use super::Input;
use crate::flowgger::config::Config;
use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use flate2::read::{GzDecoder, ZlibDecoder};
use std::io::{stderr, Read, Write};
use std::net::SocketAddr;
use std::net::UdpSocket;
use std::str;
use std::sync::mpsc::SyncSender;

const DEFAULT_LISTEN: &str = "0.0.0.0:514";
const MAX_UDP_PACKET_SIZE: usize = 65_527;
const MAX_COMPRESSION_RATIO: usize = 5;

/// UDP input structure for flowgger
/// It will receive messages from the network, decode them and reencoded them as configured
/// in the [`Config`][] object it takes as input
///
/// [`Config`]: ../config/struct.Config.html
pub struct UdpInput {
    listen: SocketAddr,
}

impl UdpInput {
    /// Attemps to create a new UdpInput instance by parsing the a Config object in the toml format
    /// the only field needed for this to work in input.listen, if input.listen is missing it will
    /// bind itself to a default ip:port address `0.0.0.0:514`
    ///
    /// # Parameters
    /// `config`: Configuration object in toml format
    ///
    /// # Panic
    /// `input.listen must be an ip:port string`:  input.listen is not parsable as a string
    /// `Unable to parse ip:port string from input.listen` input.listen is not a valid ip:port
    pub fn new(config: &Config) -> UdpInput {
        let listen = config
            .lookup("input.listen")
            .map_or(DEFAULT_LISTEN, |x| {
                x.as_str().expect("input.listen must be an ip:port string")
            })
            .to_owned();
        let bind_address: SocketAddr = listen
            .parse()
            .expect("unable to parse ip:port string from input.listen");
        UdpInput {
            listen: bind_address,
        }
    }
}

impl Input for UdpInput {
    /// Bind a [`UdpSocket`][] to the configured listen address and starts a loop for accepting
    /// incoming upd packets
    ///
    /// [`UdpSocket`]: https://doc.rust-lang.org/std/net/struct.UdpSocket.html
    ///
    /// # Parameters
    /// `tx`: Sender channel
    /// `decoder`: Box containing a dynamically allocated Decoder
    /// `encoder`: Box containing a dynamically allocated Encoder
    ///
    /// # Panics
    /// `Unable to listen to <socket>`: Socket is already open by another program or current
    /// permissions are insufficent to open the specified socket
    fn accept(
        &self,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder + Send>,
        encoder: Box<dyn Encoder + Send>,
    ) {
        let socket = UdpSocket::bind(&self.listen)
            .unwrap_or_else(|_| panic!("Unable to listen to {}", self.listen));
        let tx = tx.clone();
        let (decoder, encoder): (Box<dyn Decoder>, Box<dyn Encoder>) =
            (decoder.clone_boxed(), encoder.clone_boxed());
        let mut buf = [0; MAX_UDP_PACKET_SIZE];
        loop {
            let (length, _src) = match socket.recv_from(&mut buf) {
                Ok(res) => res,
                Err(_) => continue,
            };
            let line = &buf[..length];
            if let Err(e) = handle_record_maybe_compressed(line, &tx, &decoder, &encoder) {
                let _ = writeln!(stderr(), "{}", e);
            }
        }
    }
}

/// Handle a line that could be compressed in the Zlib or Gz format, uncompress it if compressed
/// with a known algoritm and passed it to handle_record to decoded it from the input format to the
/// output one and send it over for being sent in output
///
/// # Errors
/// `Corrupted compressed (gzip/zlib) record`: The record has been identified as a compressed record in a known format
/// but could not be handled
/// `Invalid UTF-8 input`: Bubble up from handle_record, the record is not in a valid utf-8 format, it could be a non
/// supported compression format
pub fn handle_record_maybe_compressed(
    line: &[u8],
    tx: &SyncSender<Vec<u8>>,
    decoder: &Box<dyn Decoder>,
    encoder: &Box<dyn Encoder>,
) -> Result<(), &'static str> {
    if line.len() >= 8
        && (line[0] == 0x78 && (line[1] == 0x01 || line[1] == 0x9c || line[1] == 0xda))
    {
        let mut decompressed = Vec::with_capacity(MAX_UDP_PACKET_SIZE * MAX_COMPRESSION_RATIO);
        match ZlibDecoder::new(line).read_to_end(&mut decompressed) {
            Ok(_) => handle_record(&decompressed, tx, decoder, encoder),
            Err(_) => Err("Corrupted compressed (zlib) record"),
        }
    } else if line.len() >= 24 && (line[0] == 0x1f && line[1] == 0x8b && line[2] == 0x08) {
        let mut decompressed = Vec::with_capacity(MAX_UDP_PACKET_SIZE * MAX_COMPRESSION_RATIO);
        match GzDecoder::new(line).read_to_end(&mut decompressed) {
            Ok(_) => handle_record(&decompressed, tx, decoder, encoder),
            Err(_) => Err("Corrupted compressed (gzip) record"),
        }
    } else {
        handle_record(line, tx, decoder, encoder)
    }
}

/// Decode a byte line in a valid utf-8 format, encodes it and sends it over throught a channel
///
/// # Errors
/// `Invalid UTF-8 input`: The record is not in a valid utf-8 format, it could be a non supported compression format
fn handle_record(
    line: &[u8],
    tx: &SyncSender<Vec<u8>>,
    decoder: &Box<dyn Decoder>,
    encoder: &Box<dyn Encoder>,
) -> Result<(), &'static str> {
    let line = match str::from_utf8(line) {
        Err(_) => return Err("Invalid UTF-8 input"),
        Ok(line) => line,
    };
    let decoded = decoder.decode(line)?;
    let reencoded = encoder.encode(decoded)?;
    tx.send(reencoded).unwrap();
    Ok(())
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::flowgger::config::Config;
    use crate::flowgger::get_decoder_rfc3164;
    use crate::flowgger::get_encoder_rfc3164;
    use flate2::write::{GzEncoder, ZlibEncoder};
    use flate2::Compression;
    use std::sync::mpsc::{sync_channel, Receiver};

    const DEFAULT_QUEUE_SIZE: usize = 10_000_000;

    #[test]
    fn test_udp_input_constructor() {
        let listen_ip = "127.0.0.1:5000";
        let config =
            Config::from_string(format!("[input]\nlisten = \"{}\"", listen_ip).as_str()).unwrap();
        let input = UdpInput::new(&config);
        let listen_addr: SocketAddr = listen_ip.parse().unwrap();
        assert_eq!(input.listen, listen_addr);
    }

    #[test]
    #[should_panic(expected = "unable to parse ip:port string from input.listen")]
    fn test_udp_input_constructor_bad_input() {
        let config = Config::from_string("[input]\nlisten = \"wrongaddress\"").unwrap();
        UdpInput::new(&config);
    }

    #[test]
    fn test_udp_input_default_constructor() {
        let config = Config::from_string("").unwrap();
        let input = UdpInput::new(&config);
        let default_addr: SocketAddr = DEFAULT_LISTEN.parse().unwrap();
        assert_eq!(input.listen, default_addr);
    }

    fn handle_record_set_up() -> (
        &'static str,
        SyncSender<Vec<u8>>,
        Receiver<Vec<u8>>,
        Box<dyn Decoder>,
        Box<dyn Encoder>,
    ) {
        let line = "Aug  6 11:15:24 testhostname appname 69 42 [origin@123 software=\"te\\st sc\"ript\" swVersion=\"0.0.1\"] test message";
        let (tx, rx): (SyncSender<Vec<u8>>, Receiver<Vec<u8>>) = sync_channel(DEFAULT_QUEUE_SIZE);
        let config = Config::from_string("").unwrap();
        let encoder = get_encoder_rfc3164(&config);
        let decoder = get_decoder_rfc3164(&config);
        let (decoder, encoder): (Box<dyn Decoder>, Box<dyn Encoder>) =
            (decoder.clone_boxed(), encoder.clone_boxed());
        (line, tx, rx, decoder, encoder)
    }

    #[test]
    fn test_udp_input_handle_record_uncompressed() {
        let (line, tx, rx, decoder, encoder) = handle_record_set_up();
        handle_record_maybe_compressed(line.as_bytes(), &tx, &decoder, &encoder).unwrap();
        let transmitted = rx.recv().unwrap();
        assert_eq!(str::from_utf8(&transmitted).unwrap(), line);
    }

    #[test]
    fn test_handle_record_compressed_zlib() {
        let (line, tx, rx, decoder, encoder) = handle_record_set_up();
        let mut compressor = ZlibEncoder::new(Vec::new(), Compression::default());
        match compressor.write_all(line.as_bytes()) {
            Ok(e) => e,
            Err(e) => panic!("Compressing line {}, raised Error {:?}", line, e),
        }
        let compressed_line = compressor.finish().unwrap();
        handle_record_maybe_compressed(&compressed_line, &tx, &decoder, &encoder).unwrap();
        let transmitted = rx.recv().unwrap();
        assert_eq!(str::from_utf8(&transmitted).unwrap(), line);
    }

    #[test]
    fn test_handle_record_compressed_gz() {
        let (line, tx, rx, decoder, encoder) = handle_record_set_up();
        let mut compressor = GzEncoder::new(Vec::new(), Compression::default());
        match compressor.write_all(line.as_bytes()) {
            Ok(e) => e,
            Err(e) => panic!("Compressing line {}, raised Error {:?}", line, e),
        }
        let compressed_line = compressor.finish().unwrap();
        handle_record_maybe_compressed(&compressed_line, &tx, &decoder, &encoder).unwrap();
        let transmitted = rx.recv().unwrap();
        assert_eq!(str::from_utf8(&transmitted).unwrap(), line);
    }

    #[test]
    #[should_panic(expected = "Invalid UTF-8 input")]
    fn test_handle_record_bad_record() {
        let (line, tx, _rx, decoder, encoder) = handle_record_set_up();
        let mut compressor = GzEncoder::new(Vec::new(), Compression::default());
        match compressor.write_all(line.as_bytes()) {
            Ok(e) => e,
            Err(e) => panic!("Compressing line {}, raised Error {:?}", line, e),
        }
        let mut compressed_line = compressor.finish().unwrap();
        compressed_line.truncate(5);
        handle_record_maybe_compressed(&compressed_line, &tx, &decoder, &encoder).unwrap();
    }
}
