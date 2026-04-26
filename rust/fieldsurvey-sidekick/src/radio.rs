use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;
use tokio::process::Command as TokioCommand;
use tokio::task::JoinHandle;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RadioInterface {
    pub name: String,
    pub mac_address: Option<String>,
    pub operstate: Option<String>,
    pub driver: Option<String>,
    pub phy: Option<String>,
    pub supported_modes: Vec<String>,
    pub monitor_supported: Option<bool>,
    pub usb: Option<UsbDeviceInfo>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UsbDeviceInfo {
    pub speed_mbps: Option<u32>,
    pub version: Option<String>,
    pub manufacturer: Option<String>,
    pub product: Option<String>,
    pub vendor_id: Option<String>,
    pub product_id: Option<String>,
    pub bus_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RadioInventory {
    pub radios: Vec<RadioInterface>,
    pub iw_available: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct MonitorPrepareRequest {
    pub interface_name: String,
    pub frequency_mhz: Option<u32>,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MonitorPreparePlan {
    pub interface_name: String,
    pub commands: Vec<CommandSpec>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: String,
    pub args: Vec<String>,
    pub requires_root: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CommandExecution {
    pub command: CommandSpec,
    pub status_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MonitorPrepareExecution {
    pub plan: MonitorPreparePlan,
    pub dry_run: bool,
    pub executions: Vec<CommandExecution>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelHopRequest {
    pub interface_name: String,
    pub frequencies_mhz: Vec<u32>,
    pub interval: Duration,
}

#[derive(Debug, Clone)]
pub struct RadioDiscovery {
    sysfs_net_path: PathBuf,
    interfaces: Vec<String>,
}

impl RadioDiscovery {
    pub fn new(sysfs_net_path: PathBuf, interfaces: Vec<String>) -> Self {
        Self {
            sysfs_net_path,
            interfaces,
        }
    }

    pub fn discover(&self) -> RadioInventory {
        let iw = iw_path();
        let phy_by_interface = iw
            .as_deref()
            .and_then(run_iw_dev)
            .map(|raw| parse_iw_dev(&raw))
            .unwrap_or_default();
        let modes_by_phy = iw
            .as_deref()
            .and_then(run_iw_list)
            .map(|raw| parse_iw_list_modes(&raw))
            .unwrap_or_default();

        let mut radios = Vec::new();

        if let Ok(entries) = fs::read_dir(&self.sysfs_net_path) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if !self.should_include(&name) {
                    continue;
                }

                let iface_path = entry.path();
                let phy = phy_by_interface.get(&name).cloned();
                let supported_modes = phy
                    .as_ref()
                    .and_then(|phy| modes_by_phy.get(phy).cloned())
                    .unwrap_or_default();
                let monitor_supported = if supported_modes.is_empty() {
                    None
                } else {
                    Some(supported_modes.iter().any(|mode| mode == "monitor"))
                };

                radios.push(RadioInterface {
                    name,
                    mac_address: read_trimmed(iface_path.join("address")),
                    operstate: read_trimmed(iface_path.join("operstate")),
                    driver: driver_name(&iface_path),
                    phy,
                    supported_modes,
                    monitor_supported,
                    usb: usb_device_info(&iface_path),
                });
            }
        }

        radios.sort_by(|left, right| left.name.cmp(&right.name));

        RadioInventory {
            radios,
            iw_available: iw.is_some(),
        }
    }

    fn should_include(&self, name: &str) -> bool {
        if !self.interfaces.is_empty() {
            return self.interfaces.iter().any(|iface| iface == name);
        }

        name.starts_with("wlan")
    }
}

pub fn build_monitor_prepare_plan(
    request: MonitorPrepareRequest,
) -> Result<MonitorPreparePlan, String> {
    let interface = request.interface_name.trim();
    if interface.is_empty() {
        return Err("interface_name is required".to_string());
    }

    let mut commands = vec![
        command("ip", ["link", "set", interface, "down"]),
        command("iw", ["dev", interface, "set", "type", "monitor"]),
        command("ip", ["link", "set", interface, "up"]),
    ];

    if let Some(frequency_mhz) = request.frequency_mhz {
        validate_survey_frequency(frequency_mhz)?;

        commands.push(CommandSpec {
            program: "iw".to_string(),
            args: vec![
                "dev".to_string(),
                interface.to_string(),
                "set".to_string(),
                "freq".to_string(),
                frequency_mhz.to_string(),
            ],
            requires_root: true,
        });
    }

    Ok(MonitorPreparePlan {
        interface_name: interface.to_string(),
        commands,
    })
}

fn validate_survey_frequency(frequency_mhz: u32) -> Result<(), String> {
    if !(2_412..=7_125).contains(&frequency_mhz) {
        return Err(format!(
            "frequency_mhz {frequency_mhz} is outside supported Wi-Fi survey range"
        ));
    }

    Ok(())
}

pub async fn execute_monitor_prepare_plan(
    plan: MonitorPreparePlan,
    dry_run: bool,
) -> Result<MonitorPrepareExecution, String> {
    if dry_run {
        return Ok(MonitorPrepareExecution {
            plan,
            dry_run,
            executions: Vec::new(),
        });
    }

    let mut executions = Vec::new();

    for command in &plan.commands {
        let program = resolve_program(&command.program);
        let output = TokioCommand::new(&program)
            .args(&command.args)
            .output()
            .await
            .map_err(|err| format!("failed to run {}: {err}", command.program))?;

        let execution = CommandExecution {
            command: command.clone(),
            status_code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
            success: output.status.success(),
        };
        let success = execution.success;
        executions.push(execution);

        if !success {
            return Ok(MonitorPrepareExecution {
                plan,
                dry_run,
                executions,
            });
        }
    }

    Ok(MonitorPrepareExecution {
        plan,
        dry_run,
        executions,
    })
}

pub fn build_channel_hop_request(
    interface_name: &str,
    raw_frequencies_mhz: &str,
    interval_ms: u64,
) -> Result<Option<ChannelHopRequest>, String> {
    let interface = interface_name.trim();
    if interface.is_empty() {
        return Err("interface_name is required".to_string());
    }

    let frequencies_mhz = parse_frequency_list(raw_frequencies_mhz)?;
    if frequencies_mhz.len() < 2 {
        return Ok(None);
    }

    if interval_ms < 100 {
        return Err("hop_interval_ms must be at least 100".to_string());
    }

    Ok(Some(ChannelHopRequest {
        interface_name: interface.to_string(),
        frequencies_mhz,
        interval: Duration::from_millis(interval_ms),
    }))
}

pub fn parse_frequency_list(raw: &str) -> Result<Vec<u32>, String> {
    let mut frequencies = Vec::new();

    for token in raw.split([',', '|', ';', ' ', '\t', '\n']) {
        let trimmed = token.trim();
        if trimmed.is_empty() {
            continue;
        }

        let frequency_mhz = trimmed
            .parse::<u32>()
            .map_err(|_| format!("invalid frequency_mhz value {trimmed:?}"))?;

        validate_survey_frequency(frequency_mhz)?;

        if !frequencies.contains(&frequency_mhz) {
            frequencies.push(frequency_mhz);
        }
    }

    Ok(frequencies)
}

pub fn spawn_channel_hopper(request: ChannelHopRequest) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut index = 0usize;
        let mut interval = tokio::time::interval(request.interval);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            let frequency_mhz = request.frequencies_mhz[index % request.frequencies_mhz.len()];
            let _ = set_interface_frequency(&request.interface_name, frequency_mhz).await;
            index = index.wrapping_add(1);
            interval.tick().await;
        }
    })
}

async fn set_interface_frequency(interface_name: &str, frequency_mhz: u32) -> Result<(), String> {
    let program = resolve_program("iw");
    let output = TokioCommand::new(&program)
        .args([
            "dev",
            interface_name,
            "set",
            "freq",
            &frequency_mhz.to_string(),
        ])
        .output()
        .await
        .map_err(|err| format!("failed to run iw set freq: {err}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn command<const N: usize>(program: &str, args: [&str; N]) -> CommandSpec {
    CommandSpec {
        program: program.to_string(),
        args: args.iter().map(|arg| (*arg).to_string()).collect(),
        requires_root: true,
    }
}

fn resolve_program(program: &str) -> PathBuf {
    if program.contains('/') {
        return PathBuf::from(program);
    }

    match program {
        "iw" => ["/usr/sbin/iw", "/sbin/iw", "/usr/bin/iw", "/bin/iw"]
            .iter()
            .map(PathBuf::from)
            .find(|path| path.exists())
            .unwrap_or_else(|| PathBuf::from(program)),
        "ip" => ["/usr/sbin/ip", "/sbin/ip", "/usr/bin/ip", "/bin/ip"]
            .iter()
            .map(PathBuf::from)
            .find(|path| path.exists())
            .unwrap_or_else(|| PathBuf::from(program)),
        _ => PathBuf::from(program),
    }
}

fn read_trimmed(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn driver_name(iface_path: &Path) -> Option<String> {
    fs::read_link(iface_path.join("device/driver"))
        .ok()
        .and_then(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().to_string())
        })
}

fn usb_device_info(iface_path: &Path) -> Option<UsbDeviceInfo> {
    let mut current = fs::canonicalize(iface_path.join("device"))
        .ok()
        .or_else(|| iface_path.parent()?.parent().map(Path::to_path_buf))?;
    loop {
        let speed_mbps = read_trimmed(current.join("speed")).and_then(|value| value.parse().ok());
        let vendor_id = read_trimmed(current.join("idVendor"));
        let product_id = read_trimmed(current.join("idProduct"));
        let product = read_trimmed(current.join("product"));

        if speed_mbps.is_some() || vendor_id.is_some() || product_id.is_some() || product.is_some()
        {
            return Some(UsbDeviceInfo {
                speed_mbps,
                version: read_trimmed(current.join("version")),
                manufacturer: read_trimmed(current.join("manufacturer")),
                product,
                vendor_id,
                product_id,
                bus_path: current
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string()),
            });
        }

        if !current.pop() {
            return None;
        }
    }
}

fn iw_path() -> Option<PathBuf> {
    std::env::var_os("SERVICERADAR_SIDEKICK_IW")
        .map(PathBuf::from)
        .filter(|path| path.exists())
        .or_else(|| {
            ["/usr/sbin/iw", "/sbin/iw", "/usr/bin/iw", "/bin/iw"]
                .iter()
                .map(PathBuf::from)
                .find(|path| path.exists())
        })
}

fn run_iw_dev(path: &Path) -> Option<String> {
    Command::new(path)
        .arg("dev")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).to_string())
}

fn run_iw_list(path: &Path) -> Option<String> {
    Command::new(path)
        .arg("list")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).to_string())
}

pub fn parse_iw_dev(raw: &str) -> HashMap<String, String> {
    let mut result = HashMap::new();
    let mut current_phy: Option<String> = None;

    for line in raw.lines() {
        let trimmed = line.trim();
        if let Some(phy) = trimmed.strip_prefix("phy#") {
            current_phy = Some(format!("phy{}", phy.trim()));
            continue;
        }

        if let Some(interface) = trimmed.strip_prefix("Interface ")
            && let Some(phy) = &current_phy
        {
            result.insert(interface.trim().to_string(), phy.clone());
        }
    }

    result
}

pub fn parse_iw_list_modes(raw: &str) -> HashMap<String, Vec<String>> {
    let mut result: HashMap<String, Vec<String>> = HashMap::new();
    let mut current_phy: Option<String> = None;
    let mut in_modes = false;

    for line in raw.lines() {
        let trimmed = line.trim();

        if let Some(phy) = trimmed.strip_prefix("Wiphy ") {
            current_phy = Some(phy.trim().to_string());
            in_modes = false;
            continue;
        }

        if trimmed == "Supported interface modes:" {
            in_modes = true;
            continue;
        }

        if in_modes {
            if let Some(mode) = trimmed.strip_prefix("* ") {
                if let Some(phy) = &current_phy {
                    result
                        .entry(phy.clone())
                        .or_default()
                        .push(mode.trim().to_string());
                }
                continue;
            }

            if !trimmed.is_empty() {
                in_modes = false;
            }
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use tempfile::TempDir;

    #[test]
    fn parses_iw_dev_interfaces_to_phys() {
        let raw = r#"
phy#0
	Interface wlan2
		ifindex 5
phy#2
	Interface wlan1
		ifindex 4
"#;

        let parsed = parse_iw_dev(raw);
        assert_eq!(parsed.get("wlan2"), Some(&"phy0".to_string()));
        assert_eq!(parsed.get("wlan1"), Some(&"phy2".to_string()));
    }

    #[test]
    fn parses_monitor_mode_from_iw_list() {
        let raw = r#"
Wiphy phy0
	Supported interface modes:
		 * IBSS
		 * managed
		 * monitor
	Band 1:
Wiphy phy1
	Supported interface modes:
		 * managed
		 * AP
	Band 1:
"#;

        let parsed = parse_iw_list_modes(raw);
        assert!(parsed["phy0"].contains(&"monitor".to_string()));
        assert!(!parsed["phy1"].contains(&"monitor".to_string()));
    }

    #[test]
    fn discovers_wlan_interfaces_from_sysfs_fixture() {
        let temp = TempDir::new().unwrap();
        let net = temp.path().join("net");
        let wlan = net.join("wlan9");
        let driver_target = temp.path().join("drivers").join("mt76x2u");
        fs::create_dir_all(wlan.join("device")).unwrap();
        fs::create_dir_all(&driver_target).unwrap();
        fs::write(wlan.join("address"), "00:11:22:33:44:55\n").unwrap();
        fs::write(wlan.join("operstate"), "down\n").unwrap();
        symlink(&driver_target, wlan.join("device/driver")).unwrap();

        let inventory = RadioDiscovery::new(net, Vec::new()).discover();
        assert_eq!(inventory.radios.len(), 1);
        assert_eq!(inventory.radios[0].name, "wlan9");
        assert_eq!(inventory.radios[0].driver.as_deref(), Some("mt76x2u"));
    }

    #[test]
    fn discovers_usb_metadata_from_sysfs_ancestor() {
        let temp = TempDir::new().unwrap();
        let usb = temp.path().join("usb2").join("2-1");
        let iface = usb.join("2-1:1.0");
        let net = iface.join("net");
        let wlan = net.join("wlan7");
        fs::create_dir_all(&wlan).unwrap();
        fs::write(wlan.join("address"), "00:11:22:33:44:55\n").unwrap();
        fs::write(wlan.join("operstate"), "up\n").unwrap();
        fs::write(usb.join("speed"), "5000\n").unwrap();
        fs::write(usb.join("version"), " 3.00\n").unwrap();
        fs::write(usb.join("manufacturer"), "MediaTek Inc.\n").unwrap();
        fs::write(usb.join("product"), "Wireless\n").unwrap();
        fs::write(usb.join("idVendor"), "0e8d\n").unwrap();
        fs::write(usb.join("idProduct"), "7612\n").unwrap();

        let inventory = RadioDiscovery::new(net, Vec::new()).discover();
        let usb = inventory.radios[0].usb.as_ref().unwrap();

        assert_eq!(usb.speed_mbps, Some(5_000));
        assert_eq!(usb.version.as_deref(), Some("3.00"));
        assert_eq!(usb.manufacturer.as_deref(), Some("MediaTek Inc."));
        assert_eq!(usb.vendor_id.as_deref(), Some("0e8d"));
        assert_eq!(usb.product_id.as_deref(), Some("7612"));
    }

    #[test]
    fn builds_monitor_prepare_plan() {
        let plan = build_monitor_prepare_plan(MonitorPrepareRequest {
            interface_name: "wlan2".to_string(),
            frequency_mhz: Some(5_180),
            dry_run: false,
        })
        .unwrap();

        assert_eq!(plan.interface_name, "wlan2");
        assert_eq!(plan.commands.len(), 4);
        assert_eq!(plan.commands[1].program, "iw");
        assert_eq!(
            plan.commands[1].args,
            ["dev", "wlan2", "set", "type", "monitor"]
        );
        assert_eq!(plan.commands[2].args, ["link", "set", "wlan2", "up"]);
        assert_eq!(
            plan.commands[3].args,
            ["dev", "wlan2", "set", "freq", "5180"]
        );
    }

    #[test]
    fn rejects_empty_monitor_interface() {
        let err = build_monitor_prepare_plan(MonitorPrepareRequest {
            interface_name: " ".to_string(),
            frequency_mhz: None,
            dry_run: false,
        })
        .unwrap_err();

        assert!(err.contains("interface_name"));
    }

    #[test]
    fn parses_channel_hop_frequency_list() {
        let frequencies = parse_frequency_list("2412, 2437|2462;5180 5200 2412").unwrap();

        assert_eq!(frequencies, vec![2_412, 2_437, 2_462, 5_180, 5_200]);
    }

    #[test]
    fn builds_channel_hop_request_for_multiple_frequencies() {
        let request = build_channel_hop_request("wlan2", "5180,5200", 250)
            .unwrap()
            .unwrap();

        assert_eq!(request.interface_name, "wlan2");
        assert_eq!(request.frequencies_mhz, vec![5_180, 5_200]);
        assert_eq!(request.interval, Duration::from_millis(250));
    }

    #[test]
    fn skips_channel_hop_request_for_single_frequency() {
        assert!(
            build_channel_hop_request("wlan2", "5180", 250)
                .unwrap()
                .is_none()
        );
    }
}
