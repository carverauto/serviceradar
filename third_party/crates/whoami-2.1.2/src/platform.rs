use alloc::string::String;
use core::fmt::{self, Display, Formatter};

/// The underlying platform for a system
#[allow(missing_docs)]
#[derive(Debug, PartialEq, Eq, Clone)]
#[non_exhaustive]
pub enum Platform {
    Unknown(String),
    Linux,
    Bsd,
    Windows,
    Mac,
    Illumos,
    Ios,
    Android,
    Nintendo3ds,
    PlayStation,
    Fuchsia,
    Redox,
    Hurd,
}

impl Display for Platform {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        if let Self::Unknown(_) = self {
            f.write_str("Unknown: ")?;
        }

        f.write_str(match self {
            Self::Unknown(a) => a,
            Self::Linux => "Linux",
            Self::Bsd => "BSD",
            Self::Windows => "Windows",
            Self::Mac => "macOS",
            Self::Illumos => "illumos",
            Self::Ios => "iOS",
            Self::Android => "Android",
            Self::Nintendo3ds => "Nintendo 3DS",
            Self::PlayStation => "PlayStation",
            Self::Fuchsia => "Fuchsia",
            Self::Redox => "Redox",
            Self::Hurd => "GNU Hurd",
        })
    }
}
