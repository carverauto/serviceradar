use anyhow::{Context, Result};

pub fn assert_phase1_capabilities() -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        if has_effective_cap_net_raw()? {
            return Ok(());
        }

        anyhow::bail!("CAP_NET_RAW is required before opening capture interfaces");
    }

    #[cfg(not(target_os = "linux"))]
    {
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn has_effective_cap_net_raw() -> Result<bool> {
    // CAP_NET_RAW is 13 in <linux/capability.h>; see capabilities(7).
    const CAP_NET_RAW: u64 = 13;

    let status =
        std::fs::read_to_string("/proc/self/status").context("failed to read /proc/self/status")?;
    let cap_eff = status
        .lines()
        .find_map(|line| line.strip_prefix("CapEff:"))
        .context("CapEff not present in /proc/self/status")?
        .trim();
    let bits = u64::from_str_radix(cap_eff, 16).context("failed to parse CapEff")?;

    Ok(bits & (1u64 << CAP_NET_RAW) != 0)
}

pub fn drop_privileges_or_allow_root(user: Option<&str>, allow_root: bool) -> Result<()> {
    #[cfg(unix)]
    {
        drop_privileges_unix(user, allow_root)?;
    }

    #[cfg(not(unix))]
    {
        let _ = (user, allow_root);
    }

    Ok(())
}

pub fn running_as_root() -> bool {
    #[cfg(unix)]
    {
        nix::unistd::Uid::current().is_root()
    }

    #[cfg(not(unix))]
    {
        false
    }
}

#[cfg(unix)]
fn drop_privileges_unix(user: Option<&str>, allow_root: bool) -> Result<()> {
    use std::ffi::CString;

    use nix::unistd::{Uid, User, setgid, setuid};

    let Some(user) = user else {
        if Uid::current().is_root() && !allow_root {
            anyhow::bail!(
                "serviceradar-netprobe refuses to serve IPC as root; configure --drop-user or set --allow-root for development only"
            );
        }
        if Uid::current().is_root() && allow_root {
            log::warn!(
                "serviceradar-netprobe continuing as root because --allow-root was set; do not use this in production"
            );
        }

        return Ok(());
    };

    let Some(target) =
        User::from_name(user).with_context(|| format!("failed to resolve user {user}"))?
    else {
        anyhow::bail!("user {user} does not exist");
    };

    let c_user = CString::new(user).context("drop user contains an embedded NUL byte")?;
    initialize_supplementary_groups(&c_user, target.gid)
        .with_context(|| format!("failed to initialize supplementary groups for {user}"))?;
    setgid(target.gid).with_context(|| format!("failed to set gid for {user}"))?;
    setuid(target.uid).with_context(|| format!("failed to set uid for {user}"))?;

    Ok(())
}

#[cfg(all(unix, target_os = "linux"))]
fn initialize_supplementary_groups(user: &std::ffi::CStr, gid: nix::unistd::Gid) -> Result<()> {
    use nix::unistd::initgroups;

    initgroups(user, gid)?;

    Ok(())
}

#[cfg(all(unix, not(target_os = "linux")))]
fn initialize_supplementary_groups(_user: &std::ffi::CStr, _gid: nix::unistd::Gid) -> Result<()> {
    Ok(())
}
