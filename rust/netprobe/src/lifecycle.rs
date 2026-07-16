use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use crate::{capabilities, capture::CaptureHandles, config::Config};

pub const DEFAULT_BPF_PIN_DIR: &str = "/sys/fs/bpf/serviceradar/netprobe";

pub trait StartupOps {
    type Captures;

    fn assert_phase1_capabilities(&mut self) -> Result<()>;
    fn prepare_bpf_pin_directory(&mut self, path: &Path) -> Result<()>;
    fn open_capture_handles(&mut self, config: &Config) -> Result<Self::Captures>;
    fn drop_privileges(&mut self, user: Option<&str>, allow_root: bool) -> Result<()>;
}

pub struct SystemStartupOps;

impl StartupOps for SystemStartupOps {
    type Captures = CaptureHandles;

    fn assert_phase1_capabilities(&mut self) -> Result<()> {
        capabilities::assert_phase1_capabilities()
    }

    fn prepare_bpf_pin_directory(&mut self, path: &Path) -> Result<()> {
        prepare_bpf_pin_directory(path)
    }

    fn open_capture_handles(&mut self, config: &Config) -> Result<Self::Captures> {
        CaptureHandles::open(config)
    }

    fn drop_privileges(&mut self, user: Option<&str>, allow_root: bool) -> Result<()> {
        capabilities::drop_privileges_or_allow_root(user, allow_root)
    }
}

pub fn initialize_privileged_resources<O>(
    ops: &mut O,
    config: &Config,
    drop_user: Option<&str>,
    skip_cap_check: bool,
    allow_root: bool,
) -> Result<O::Captures>
where
    O: StartupOps,
{
    if config.enabled && !skip_cap_check {
        ops.assert_phase1_capabilities()?;
        ops.prepare_bpf_pin_directory(&PathBuf::from(DEFAULT_BPF_PIN_DIR))?;
    }

    let captures = ops.open_capture_handles(config)?;
    ops.drop_privileges(drop_user, allow_root)?;

    Ok(captures)
}

#[cfg(target_os = "linux")]
pub fn prepare_ebpf_privileged_resources<O>(
    ops: &mut O,
    config: &Config,
    skip_cap_check: bool,
) -> Result<()>
where
    O: StartupOps,
{
    if config.enabled && !skip_cap_check {
        ops.assert_phase1_capabilities()?;
        ops.prepare_bpf_pin_directory(&PathBuf::from(DEFAULT_BPF_PIN_DIR))?;
    }

    Ok(())
}

#[cfg(target_os = "linux")]
pub fn drop_runtime_privileges<O>(ops: &mut O, user: Option<&str>, allow_root: bool) -> Result<()>
where
    O: StartupOps,
{
    ops.drop_privileges(user, allow_root)
}

fn prepare_bpf_pin_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)
        .with_context(|| format!("failed to create BPF pin directory {}", path.display()))?;

    #[cfg(unix)]
    for dir in bpf_pin_directory_chain(path) {
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("failed to chmod BPF pin directory {}", dir.display()))?;
    }

    Ok(())
}

#[cfg(unix)]
fn bpf_pin_directory_chain(path: &Path) -> Vec<PathBuf> {
    let mut dirs = Vec::with_capacity(2);
    if let Some(parent) = path.parent() {
        dirs.push(parent.to_path_buf());
    }
    dirs.push(path.to_path_buf());
    dirs
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use anyhow::Result;

    use super::{StartupOps, initialize_privileged_resources};
    use crate::config::Config;

    #[derive(Default)]
    struct FakeStartupOps {
        calls: Vec<&'static str>,
        drop_user: Option<String>,
        allow_root: bool,
    }

    impl StartupOps for FakeStartupOps {
        type Captures = usize;

        fn assert_phase1_capabilities(&mut self) -> Result<()> {
            self.calls.push("assert_caps");
            Ok(())
        }

        fn prepare_bpf_pin_directory(&mut self, _path: &Path) -> Result<()> {
            self.calls.push("prepare_bpf_pin_dir");
            Ok(())
        }

        fn open_capture_handles(&mut self, _config: &Config) -> Result<Self::Captures> {
            self.calls.push("open_captures");
            Ok(2)
        }

        fn drop_privileges(&mut self, user: Option<&str>, allow_root: bool) -> Result<()> {
            self.calls.push("drop_privileges");
            self.drop_user = user.map(str::to_string);
            self.allow_root = allow_root;
            Ok(())
        }
    }

    #[test]
    fn opens_captures_before_dropping_privileges() {
        let config = Config::default();
        let mut ops = FakeStartupOps::default();

        let captures =
            initialize_privileged_resources(&mut ops, &config, Some("serviceradar"), false, false)
                .unwrap();

        assert_eq!(captures, 2);
        assert_eq!(
            ops.calls,
            [
                "assert_caps",
                "prepare_bpf_pin_dir",
                "open_captures",
                "drop_privileges"
            ]
        );
        assert_eq!(ops.drop_user.as_deref(), Some("serviceradar"));
        assert!(!ops.allow_root);
    }

    #[test]
    fn can_skip_capability_assertion_for_development() {
        let config = Config::default();
        let mut ops = FakeStartupOps::default();

        initialize_privileged_resources(&mut ops, &config, None, true, true).unwrap();

        assert_eq!(ops.calls, ["open_captures", "drop_privileges"]);
        assert!(ops.allow_root);
    }
}
