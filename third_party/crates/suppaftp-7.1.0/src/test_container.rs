#![allow(dead_code)]

use std::borrow::Cow;

use testcontainers::core::{CmdWaitFor, ExecCommand, WaitFor};
use testcontainers::{Container, ContainerAsync, Image};

#[derive(Debug, Default, Clone)]
struct PureFtpImage {
    _priv: (),
}

impl Image for PureFtpImage {
    fn name(&self) -> &str {
        "stilliard/pure-ftpd"
    }

    fn tag(&self) -> &str {
        "latest"
    }

    fn ready_conditions(&self) -> Vec<WaitFor> {
        vec![WaitFor::message_on_stdout("Starting Pure-FTPd")]
    }

    fn env_vars(
        &self,
    ) -> impl IntoIterator<Item = (impl Into<Cow<'_, str>>, impl Into<Cow<'_, str>>)> {
        vec![
            ("PUBLICHOST", "localhost"),
            ("FTP_USER_NAME", "test"),
            ("FTP_USER_PASS", "test"),
            ("FTP_USER_HOME", "/home/test"),
        ]
    }
}

pub struct AsyncPureFtpRunner {
    container: ContainerAsync<PureFtpImage>,
}

impl AsyncPureFtpRunner {
    pub async fn start() -> Self {
        use testcontainers::runners::AsyncRunner;
        let container = PureFtpImage::default()
            .start()
            .await
            .expect("Failed to start container");
        let resp = container
            .exec(
                ExecCommand::new(["/bin/mkdir", "-p", "/home/test/invalid-utf8"])
                    .with_cmd_ready_condition(CmdWaitFor::Exit { code: Some(0) }),
            )
            .await
            .expect("Failed to create directory");
        assert_eq!(
            resp.exit_code()
                .await
                .expect("failed to get exit code for mkdir")
                .expect("no exit code for mkdir"),
            0
        );
        let resp = container
            .exec(
                ExecCommand::new([
                    "/usr/bin/touch",
                    "/home/test/invalid-utf8/caf\\303\\251.txt",
                ])
                .with_cmd_ready_condition(CmdWaitFor::Exit { code: Some(0) }),
            )
            .await
            .expect("Failed to create file");
        assert_eq!(
            resp.exit_code()
                .await
                .expect("failed to get exit code for touch")
                .expect("no exit code for touch"),
            0
        );
        Self { container }
    }

    pub async fn get_ftp_port(&self) -> u16 {
        self.container.get_host_port_ipv4(21).await.unwrap()
    }

    pub async fn get_mapped_port(&self, port: u16) -> u16 {
        self.container.get_host_port_ipv4(port).await.unwrap()
    }
}

pub struct SyncPureFtpRunner {
    container: Container<PureFtpImage>,
}

impl SyncPureFtpRunner {
    pub fn start() -> Self {
        use testcontainers::runners::SyncRunner;
        let container = PureFtpImage::default()
            .start()
            .expect("Failed to start container");

        let resp = container
            .exec(
                ExecCommand::new(["/bin/mkdir", "-p", "/home/test/invalid-utf8"])
                    .with_cmd_ready_condition(CmdWaitFor::Exit { code: Some(0) }),
            )
            .expect("Failed to create directory");
        assert_eq!(
            resp.exit_code()
                .expect("failed to get exit code for mkdir")
                .expect("no exit code for mkdir"),
            0
        );
        let resp = container
            .exec(
                ExecCommand::new([
                    "/usr/bin/touch",
                    "/home/test/invalid-utf8/caf\\303\\251.txt",
                ])
                .with_cmd_ready_condition(CmdWaitFor::Exit { code: Some(0) }),
            )
            .expect("Failed to create file");
        assert_eq!(
            resp.exit_code()
                .expect("failed to get exit code for touch")
                .expect("no exit code for touch"),
            0
        );

        Self { container }
    }

    pub fn get_ftp_port(&self) -> u16 {
        self.container.get_host_port_ipv4(21).unwrap()
    }

    pub fn get_mapped_port(&self, port: u16) -> u16 {
        self.container.get_host_port_ipv4(port).unwrap()
    }
}
