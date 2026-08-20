//! Which run this is.

/// Where `//build:run_id_file` lands in runfiles, when a target declares it as `data`.
const RUN_ID_RUNFILE: &str = "build/run_id_file.txt";
const THIS_REPO: &str = "_main";

/// A correlation id for one test run.
///
/// CI supplies it as `--//build:run_id=$RUN_ID`, repeated across every invocation of the
/// integration lifecycle so six separate Bazel processes agree on one name. It arrives as a
/// declared input rather than an environment variable, which keeps it out of ambient state
/// (see `//build/run_id.bzl`).
///
/// A LOCAL RUN HAS NO SUCH ID. The flag deliberately has no default -- a constant fallback is
/// what once let two concurrent runs share one fixture and tear down each other's data -- so an
/// unset flag writes an EMPTY file. A local run therefore synthesises its own id and says so,
/// rather than borrowing a name that means "the CI run".
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RunId {
    value: String,
    supplied: bool,
}

impl RunId {
    /// The supplied id when there is one, otherwise a synthesised local id.
    ///
    /// Infallible on purpose: a missing correlation id must not fail a test that would otherwise
    /// have run. The distinction is reported by [`Self::is_supplied`] instead, so a log line
    /// cannot quietly imply CI provenance for a local run.
    pub fn resolve() -> Self {
        match Self::from_runfiles() {
            Some(value) if !value.trim().is_empty() => Self {
                value: value.trim().to_string(),
                supplied: true,
            },
            // The pid keeps two suites started on one machine from claiming the same id.
            _ => Self {
                value: format!("local-{}", std::process::id()),
                supplied: false,
            },
        }
    }

    fn from_runfiles() -> Option<String> {
        let runfiles = runfiles::Runfiles::create().ok()?;
        let path = runfiles.rlocation_from(format!("{THIS_REPO}/{RUN_ID_RUNFILE}"), THIS_REPO)?;
        std::fs::read_to_string(path).ok()
    }

    pub fn as_str(&self) -> &str {
        &self.value
    }

    /// True when CI supplied the id; false for a synthesised local one.
    pub fn is_supplied(&self) -> bool {
        self.supplied
    }
}
