//! Actual Elixir worker, packaged NIF and Ash publication against owned fixtures.

use std::process::Stdio;
use std::time::Duration;

use dgraph_migrate::{Mode, run_with_client};
use dgraph_topology::schema_spec;
use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;
use runfiles::Runfiles;
use tokio::process::Command;

#[path = "support/fixture.rs"]
mod fixture;

#[tokio::test]
async fn real_worker_publishes_pages_and_coalesces_a_later_source_change() {
    fixture::with_scratch(Duration::from_secs(900), |client, target| async move {
        run_with_client(&client, schema_spec(), Mode::Migrate)
            .await
            .expect("apply the owned namespace schema");

        let runfiles = Runfiles::create().expect("declared worker runner runfiles");
        let executable = runfiles
            .rlocation_from(
                "serviceradar/elixir/serviceradar_core/world_worker_fixture_runner",
                "",
            )
            .expect("declared ExUnit worker runner");

        let mut child = Command::new(executable)
            .env("DGRAPH_URL", target)
            .stdin(Stdio::null())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .process_group(0)
            .kill_on_drop(true)
            .spawn()
            .expect("start the actual worker test executable");
        let mut group = OwnedProcessGroup(Some(Pid::from_raw(
            i32::try_from(child.id().expect("running child identifier"))
                .expect("process identifier fits the platform pid"),
        )));
        let status = tokio::time::timeout(Duration::from_secs(840), child.wait()).await;
        // The generated runner may have a BEAM child. Terminate the entire
        // owned group before the outer fixture deletes its namespace, even
        // when the runner exits early or the enclosing future is cancelled.
        group
            .terminate()
            .expect("terminate the owned worker process group");
        let status = match status {
            Ok(status) => status.expect("wait for the worker test executable"),
            Err(_) => {
                let _ = child.wait().await;
                panic!("worker fixture exceeded its bounded deadline");
            }
        };
        assert!(status.success(), "actual worker fixture failed: {status}");
    })
    .await;
}

struct OwnedProcessGroup(Option<Pid>);

impl OwnedProcessGroup {
    fn terminate(&mut self) -> Result<(), nix::errno::Errno> {
        let Some(group) = self.0 else {
            return Ok(());
        };
        match killpg(group, Signal::SIGKILL) {
            Ok(()) | Err(nix::errno::Errno::ESRCH) => {
                self.0 = None;
                Ok(())
            }
            Err(error) => Err(error),
        }
    }
}

impl Drop for OwnedProcessGroup {
    fn drop(&mut self) {
        let _ = self.terminate();
    }
}
