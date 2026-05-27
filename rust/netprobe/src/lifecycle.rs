use anyhow::Result;

use crate::{capabilities, capture::CaptureHandles, config::Config};

pub trait StartupOps {
    type Captures;

    fn assert_phase1_capabilities(&mut self) -> Result<()>;
    fn open_capture_handles(&mut self, config: &Config) -> Result<Self::Captures>;
    fn drop_privileges(&mut self, user: Option<&str>, allow_root: bool) -> Result<()>;
}

pub struct SystemStartupOps;

impl StartupOps for SystemStartupOps {
    type Captures = CaptureHandles;

    fn assert_phase1_capabilities(&mut self) -> Result<()> {
        capabilities::assert_phase1_capabilities()
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
    if !skip_cap_check {
        ops.assert_phase1_capabilities()?;
    }

    let captures = ops.open_capture_handles(config)?;
    ops.drop_privileges(drop_user, allow_root)?;

    Ok(captures)
}

#[cfg(test)]
mod tests {
    use anyhow::Result;

    use super::{initialize_privileged_resources, StartupOps};
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
            ["assert_caps", "open_captures", "drop_privileges"]
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
