use anyhow::Result;

use crate::{capabilities, capture::CaptureHandles, config::Config};

pub trait StartupOps {
    type Captures;

    fn assert_phase1_capabilities(&mut self) -> Result<()>;
    fn open_capture_handles(&mut self, config: &Config) -> Result<Self::Captures>;
    fn drop_privileges(&mut self, user: Option<&str>) -> Result<()>;
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

    fn drop_privileges(&mut self, user: Option<&str>) -> Result<()> {
        capabilities::drop_privileges(user)
    }
}

pub fn initialize_privileged_resources<O>(
    ops: &mut O,
    config: &Config,
    drop_user: Option<&str>,
    skip_cap_check: bool,
) -> Result<O::Captures>
where
    O: StartupOps,
{
    if !skip_cap_check {
        ops.assert_phase1_capabilities()?;
    }

    let captures = ops.open_capture_handles(config)?;
    ops.drop_privileges(drop_user)?;

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

        fn drop_privileges(&mut self, _user: Option<&str>) -> Result<()> {
            self.calls.push("drop_privileges");
            Ok(())
        }
    }

    #[test]
    fn opens_captures_before_dropping_privileges() {
        let config = Config::default();
        let mut ops = FakeStartupOps::default();

        let captures =
            initialize_privileged_resources(&mut ops, &config, Some("serviceradar"), false)
                .unwrap();

        assert_eq!(captures, 2);
        assert_eq!(
            ops.calls,
            ["assert_caps", "open_captures", "drop_privileges"]
        );
    }

    #[test]
    fn can_skip_capability_assertion_for_development() {
        let config = Config::default();
        let mut ops = FakeStartupOps::default();

        initialize_privileged_resources(&mut ops, &config, None, true).unwrap();

        assert_eq!(ops.calls, ["open_captures", "drop_privileges"]);
    }
}
