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

pub fn drop_privileges(user: Option<&str>) -> Result<()> {
    #[cfg(unix)]
    {
        use nix::unistd::{setgid, setuid, User};

        let Some(user) = user else {
            return Ok(());
        };

        let Some(target) =
            User::from_name(user).with_context(|| format!("failed to resolve user {user}"))?
        else {
            anyhow::bail!("user {user} does not exist");
        };

        setgid(target.gid).with_context(|| format!("failed to set gid for {user}"))?;
        setuid(target.uid).with_context(|| format!("failed to set uid for {user}"))?;
    }

    Ok(())
}
