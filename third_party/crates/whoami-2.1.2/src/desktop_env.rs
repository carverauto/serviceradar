use alloc::string::String;
use core::fmt::{self, Display, Formatter};

/// The desktop environment of a system
#[derive(Debug, PartialEq, Eq, Clone)]
#[non_exhaustive]
pub enum DesktopEnvironment {
    /// Unknown desktop environment
    Unknown(String),
    /// Running as Web Assembly on a web page
    WebBrowser(String),
    /// Popular GTK-based desktop environment on Linux
    Gnome,
    /// One of the desktop environments for a specific version of Windows
    Windows,
    /// Linux desktop environment optimized for low resource requirements
    Lxde,
    /// Stacking window manager for X Windows on Linux
    Openbox,
    /// Desktop environment for Linux, BSD and illumos
    Mate,
    /// Lightweight desktop enivornment for unix-like operating systems
    Xfce,
    /// KDE Plasma desktop enviroment
    Plasma,
    /// Default desktop environment on Linux Mint
    Cinnamon,
    /// Tiling window manager for Linux
    I3,
    /// Desktop environment for MacOS
    Aqua,
    /// Desktop environment for iOS
    Ios,
    /// Desktop environment for Android
    Android,
    /// A desktop environment for a video game console
    Console,
    /// Ubuntu-branded GNOME
    Ubuntu,
    /// Default shell for Fuchsia
    Ermine,
    /// Default desktop environment for Redox
    Orbital,
    /// Wayland scrolling window manager for Linux
    Niri,
    /// Wayland tiling window manager for Linux
    Hyprland,
    /// Rust based desktop environment on Linux
    Cosmic,
}

impl Display for DesktopEnvironment {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        if let Self::Unknown(_) = self {
            f.write_str("Unknown: ")?;
        }

        f.write_str(match self {
            Self::Unknown(de) => de,
            Self::WebBrowser(de) => return write!(f, "WebBrowser ({de})"),
            Self::Gnome => "Gnome",
            Self::Windows => "Windows",
            Self::Lxde => "LXDE",
            Self::Openbox => "Openbox",
            Self::Mate => "Mate",
            Self::Xfce => "XFCE",
            Self::Plasma => "KDE Plasma",
            Self::Cinnamon => "Cinnamon",
            Self::I3 => "I3",
            Self::Aqua => "Aqua",
            Self::Ios => "IOS",
            Self::Android => "Android",
            Self::Console => "Console",
            Self::Ubuntu => "Ubuntu",
            Self::Ermine => "Ermine",
            Self::Orbital => "Orbital",
            Self::Niri => "Niri",
            Self::Hyprland => "Hyprland",
            Self::Cosmic => "Cosmic",
        })
    }
}

impl DesktopEnvironment {
    /// Returns true if the desktop environment is based on GTK.
    #[must_use]
    pub const fn is_gtk(&self) -> bool {
        matches!(
            self,
            Self::Gnome
                | Self::Ubuntu
                | Self::Cinnamon
                | Self::Lxde
                | Self::Mate
                | Self::Xfce
                | Self::Niri
        )
    }

    /// Returns true if the desktop environment is based on KDE.
    #[must_use]
    pub const fn is_kde(&self) -> bool {
        matches!(self, Self::Plasma)
    }
}
