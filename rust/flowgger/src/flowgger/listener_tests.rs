use super::{Config, configured_listeners, start_pipeline};
use std::fs;
use std::io::Write;
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::{NamedTempFile, TempDir};

const CHILD_CONFIG: &str = "FLOWGGER_LISTENER_TEST_CONFIG";
const UDP_MESSAGE: &[u8] =
    b"<13>1 2025-01-01T00:00:00Z host01.example.com demo 42 - - udp-synthetic";

struct Pipeline {
    child: Child,
    output: NamedTempFile,
    _config_dir: TempDir,
}

impl Pipeline {
    fn start(config: &str) -> Self {
        let config_dir = tempfile::tempdir().unwrap();
        let config_path = config_dir.path().join("flowgger.toml");
        fs::write(&config_path, config).unwrap();
        let output = NamedTempFile::new().unwrap();
        let child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "flowgger::listener_tests::pipeline_child",
                "--nocapture",
            ])
            .env(CHILD_CONFIG, &config_path)
            .stdin(Stdio::null())
            .stdout(output.as_file().try_clone().unwrap())
            .stderr(output.as_file().try_clone().unwrap())
            .spawn()
            .unwrap();
        Self {
            child,
            output,
            _config_dir: config_dir,
        }
    }

    fn output(&self) -> String {
        fs::read_to_string(self.output.path()).unwrap()
    }

    fn wait_until(&mut self, mut condition: impl FnMut(&str) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let output = self.output();
            if condition(&output) {
                return;
            }
            assert!(self.child.try_wait().unwrap().is_none(), "{output}");
            assert!(Instant::now() < deadline, "Timed out: {output}");
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn expect_failure(&mut self, message: &str) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                let output = self.output();
                assert!(!status.success(), "Pipeline succeeded: {output}");
                assert!(output.contains(message), "{output}");
                return;
            }
            assert!(
                Instant::now() < deadline,
                "Pipeline stayed alive: {}",
                self.output()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Pipeline {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
#[ignore = "subprocess entry point for bounded listener lifecycle tests"]
fn pipeline_child() {
    start_pipeline(&std::env::var(CHILD_CONFIG).unwrap());
}

fn output_config() -> &'static str {
    "[output]\ntype = 'debug'\nformat = 'gelf'\nframing = 'line'\n"
}

fn has_message(output: &str, message: &str) -> bool {
    output.lines().any(|line| {
        serde_json::from_str::<serde_json::Value>(line)
            .is_ok_and(|record| record["short_message"] == message)
    })
}

#[test]
fn udp_and_tcp_use_independent_codecs_and_one_output() {
    let reserved_tcp = TcpListener::bind("127.0.0.1:0").unwrap();
    let listen = reserved_tcp.local_addr().unwrap();
    let reserved_udp = UdpSocket::bind(listen).unwrap();
    let config = format!(
        "[input]\nqueuesize = 8\ntype = 'udp'\nlisten = '{listen}'\nformat = 'rfc5424'\n\
         [[inputs]]\ntype = 'tcp'\nlisten = '{listen}'\nformat = 'gelf'\nframing = 'nul'\n{}",
        output_config()
    );
    drop((reserved_tcp, reserved_udp));
    let mut pipeline = Pipeline::start(&config);
    let sender = UdpSocket::bind("127.0.0.1:0").unwrap();
    pipeline.wait_until(|output| {
        sender.send_to(UDP_MESSAGE, listen).unwrap();
        has_message(output, "udp-synthetic")
    });
    let mut stream = None;
    pipeline.wait_until(|_| {
        stream = TcpStream::connect(listen).ok();
        stream.is_some()
    });
    stream
        .unwrap()
        .write_all(b"{\"version\":\"1.1\",\"host\":\"host02.example.com\",\"short_message\":\"tcp-synthetic\",\"timestamp\":1735689600}\0")
        .unwrap();
    pipeline.wait_until(|output| has_message(output, "tcp-synthetic"));
    assert!(has_message(&pipeline.output(), "udp-synthetic"));
}

#[test]
fn primary_udp_without_additional_inputs_still_delivers() {
    let reserved = UdpSocket::bind("127.0.0.1:0").unwrap();
    let listen = reserved.local_addr().unwrap();
    let config = format!(
        "[input]\nqueuesize = 8\ntype = 'udp'\nlisten = '{listen}'\nformat = 'rfc5424'\n{}",
        output_config()
    );
    drop(reserved);
    let mut pipeline = Pipeline::start(&config);
    let sender = UdpSocket::bind("127.0.0.1:0").unwrap();
    pipeline.wait_until(|output| {
        sender.send_to(UDP_MESSAGE, listen).unwrap();
        has_message(output, "udp-synthetic")
    });
}

#[test]
fn additional_listener_bind_failure_terminates_pipeline() {
    let occupied = TcpListener::bind("127.0.0.1:0").unwrap();
    let config = format!(
        "[input]\nqueuesize = 8\ntype = 'udp'\nlisten = '127.0.0.1:0'\n\
         [[inputs]]\ntype = 'tcp'\nlisten = '{}'\n{}",
        occupied.local_addr().unwrap(),
        output_config()
    );
    Pipeline::start(&config).expect_failure("Unable to listen to");
}

#[test]
fn additional_listener_return_terminates_pipeline() {
    let config = format!(
        "[input]\nqueuesize = 8\ntype = 'udp'\nlisten = '127.0.0.1:0'\n\
         [[inputs]]\ntype = 'stdin'\n{}",
        output_config()
    );
    Pipeline::start(&config).expect_failure("Input listener stdin exited unexpectedly");
}

#[test]
fn additional_inputs_inherit_only_the_global_timezone() {
    let config = Config::from_string(
        "[input]\ntype = 'udp'\nformat = 'rfc5424'\n\
         rfc3164_timezone = 'UTC'\ntimeout = 7\n\
         [[inputs]]\ntype = 'tcp'\nformat = 'rfc3164'\n\
         rfc3164_timezone = 'America/New_York'\nframing = 'syslen'",
    )
    .unwrap();
    let configs = config.input_configs().unwrap();
    assert_eq!(
        configs[0].lookup("input.type").unwrap().as_str(),
        Some("udp")
    );
    assert_eq!(
        configs[1].lookup("input.type").unwrap().as_str(),
        Some("tcp")
    );
    assert_eq!(
        configs[1].lookup("input.format").unwrap().as_str(),
        Some("rfc3164")
    );
    assert_eq!(
        configs[1].lookup("input.framing").unwrap().as_str(),
        Some("syslen")
    );
    assert_eq!(
        configs[1]
            .lookup("input.rfc3164_timezone")
            .unwrap()
            .as_str(),
        Some("UTC")
    );
    assert!(configs[1].lookup("input.timeout").is_none());
}

#[test]
#[should_panic(expected = "Duplicate input listener: tcp 127.0.0.1:1514")]
fn duplicate_listener_alias_is_rejected() {
    let config = Config::from_string(
        "[input]\ntype = 'tcp'\nlisten = '127.0.0.1:1514'\n\
         [[inputs]]\ntype = 'syslog-tcp'\nlisten = '127.0.0.1:1514'",
    )
    .unwrap();
    configured_listeners(&config);
}

#[test]
#[should_panic(expected = "Invalid input type: unknown")]
fn unknown_additional_listener_is_rejected() {
    let config =
        Config::from_string("[input]\ntype = 'udp'\n[[inputs]]\ntype = 'unknown'").unwrap();
    configured_listeners(&config);
}
