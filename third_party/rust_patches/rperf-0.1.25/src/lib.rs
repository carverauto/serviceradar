extern crate log;

pub mod client;
pub mod protocol;
pub mod server;
pub mod stream;
pub mod utils;

use crate::client::{execute, state::ClientRunState};
use crate::server::state::ServerRunState;
use anyhow::Result;
use clap::{App, Arg, ArgMatches};
use std::error::Error;
use std::sync::{Arc, Mutex};

type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

// Public API for running the client
pub fn run_client(args: ArgMatches) -> BoxResult<()> {
    let output = Arc::new(Mutex::new(Vec::new()));
    let run_state = ClientRunState::new();
    client::execute(args, output, run_state)
}

// Public API for running the server
pub fn run_server(args: ArgMatches) -> BoxResult<()> {
    let run_state = ServerRunState::new(); // Create a new ServerRunState
    server::serve(args, run_state) // Pass run_state
}

pub fn run_client_with_output(args: Vec<&str>, output: Arc<Mutex<Vec<u8>>>) -> BoxResult<()> {
    let matches = App::new("rperf")
        .about(clap::crate_description!())
        .author("https://github.com/mfreeman451/rperf")
        .name(clap::crate_name!())
        .version(clap::crate_version!())
        .arg(
            Arg::with_name("port")
                .help("the port used for client-server interactions")
                .takes_value(true)
                .long("port")
                .short("p")
                .required(false)
                .default_value("5199")
        )
        .arg(
            Arg::with_name("affinity")
                .help("specify logical CPUs, delimited by commas, across which to round-robin affinity; not supported on all systems")
                .takes_value(true)
                .long("affinity")
                .short("A")
                .required(false)
                .multiple(true)
                .default_value("")
        )
        .arg(
            Arg::with_name("debug")
                .help("emit debug-level logging on stderr; default is info and above")
                .takes_value(false)
                .long("debug")
                .short("d")
                .required(false)
        )
        .arg(
            Arg::with_name("server")
                .help("run in server mode")
                .takes_value(false)
                .long("server")
                .short("s")
                .required(false)
        )
        .arg(
            Arg::with_name("version6")
                .help("enable IPv6 on the server (on most hosts, this will allow both IPv4 and IPv6, but it might limit to just IPv6 on some)")
                .takes_value(false)
                .long("version6")
                .short("6")
                .required(false)
        )
        .arg(
            Arg::with_name("client_limit")
                .help("limit the number of concurrent clients that can be processed by a server; any over this count will be immediately disconnected")
                .takes_value(true)
                .long("client-limit")
                .required(false)
                .default_value("0")
        )
        .arg(
            Arg::with_name("client")
                .help("run in client mode; value is the server's address")
                .takes_value(true)
                .long("client")
                .short("c")
                .required(false)
        )
        .arg(
            Arg::with_name("reverse")
                .help("run in reverse-mode (server sends, client receives)")
                .takes_value(false)
                .long("reverse")
                .short("R")
                .required(false)
        )
        .arg(
            Arg::with_name("format")
                .help("the format in which to display information (json, megabit/sec, megabyte/sec)")
                .takes_value(true)
                .long("format")
                .short("f")
                .required(false)
                .default_value("megabit")
                .possible_values(&["json", "megabit", "megabyte"])
        )
        .arg(
            Arg::with_name("udp")
                .help("use UDP rather than TCP")
                .takes_value(false)
                .long("udp")
                .short("u")
                .required(false)
        )
        .arg(
            Arg::with_name("bandwidth")
                .help("target bandwidth in bytes/sec; this value is applied to each stream, with a default target of 1 megabit/second for all protocols")
                .takes_value(true)
                .long("bandwidth")
                .short("b")
                .required(false)
                .default_value("125000")
        )
        .arg(
            Arg::with_name("time")
                .help("the time in seconds for which to transmit")
                .takes_value(true)
                .long("time")
                .short("t")
                .required(false)
                .default_value("10.0")
        )
        .arg(
            Arg::with_name("send_interval")
                .help("the interval at which to send batches of data, in seconds, between [0.0 and 1.0)")
                .takes_value(true)
                .long("send-interval")
                .required(false)
                .default_value("0.05")
        )
        .arg(
            Arg::with_name("length")
                .help("length of the buffer to exchange; for TCP, this defaults to 32 kibibytes; for UDP, it's 1024 bytes")
                .takes_value(true)
                .long("length")
                .short("l")
                .required(false)
                .default_value("0")
        )
        .arg(
            Arg::with_name("send_buffer")
                .help("send_buffer, in bytes")
                .takes_value(true)
                .long("send-buffer")
                .required(false)
                .default_value("0")
        )
        .arg(
            Arg::with_name("receive_buffer")
                .help("receive_buffer, in bytes")
                .takes_value(true)
                .long("receive-buffer")
                .required(false)
                .default_value("0")
        )
        .arg(
            Arg::with_name("parallel")
                .help("the number of parallel data-streams to use")
                .takes_value(true)
                .long("parallel")
                .short("P")
                .required(false)
                .default_value("1")
        )
        .arg(
            Arg::with_name("omit")
                .help("omit a number of seconds from the start of calculations")
                .takes_value(true)
                .long("omit")
                .short("O")
                .default_value("0")
                .required(false)
        )
        .arg(
            Arg::with_name("no_delay")
                .help("use no-delay mode for TCP tests, disabling Nagle's Algorithm")
                .takes_value(false)
                .long("no-delay")
                .short("N")
                .required(false)
        )
        .arg(
            Arg::with_name("tcp_port_pool")
                .help("an optional pool of IPv4 TCP ports over which data will be accepted")
                .takes_value(true)
                .long("tcp-port-pool")
                .required(false)
                .default_value("")
        )
        .arg(
            Arg::with_name("tcp6_port_pool")
                .help("an optional pool of IPv6 TCP ports over which data will be accepted")
                .takes_value(true)
                .long("tcp6-port-pool")
                .required(false)
                .default_value("")
        )
        .arg(
            Arg::with_name("udp_port_pool")
                .help("an optional pool of IPv4 UDP ports over which data will be accepted")
                .takes_value(true)
                .long("udp-port-pool")
                .required(false)
                .default_value("")
        )
        .arg(
            Arg::with_name("udp6_port_pool")
                .help("an optional pool of IPv6 UDP ports over which data will be accepted")
                .takes_value(true)
                .long("udp6-port-pool")
                .required(false)
                .default_value("")
        )
        .get_matches_from(args);

    {
        let mut output_guard = output.lock().unwrap();
        output_guard.clear();
    }

    let run_state = ClientRunState::new();
    execute(matches, output, run_state)?;

    Ok(())
}

// Re-export key types for convenience
pub use protocol::results::{TcpTestResults, TestResults, UdpTestResults};
pub use stream::{tcp, udp, TestStream};
