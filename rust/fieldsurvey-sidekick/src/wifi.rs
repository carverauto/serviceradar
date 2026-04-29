use crate::radio::CommandSpec;
use crate::runtime_config::{WifiUplinkConfig, sanitize_country_code};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::process::Command as TokioCommand;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct WifiUplinkRequest {
    #[serde(default = "default_uplink_interface")]
    pub interface_name: String,
    pub ssid: String,
    pub psk: Option<String>,
    pub country_code: Option<String>,
    #[serde(default = "default_dry_run")]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WifiUplinkPlan {
    pub commands: Vec<CommandSpec>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WifiUplinkExecution {
    pub plan: WifiUplinkPlan,
    pub dry_run: bool,
    pub executions: Vec<WifiCommandExecution>,
    pub saved_config: Option<WifiUplinkConfig>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WifiCommandExecution {
    pub command: CommandSpec,
    pub status_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ExecutableCommand {
    display: CommandSpec,
    actual_args: Vec<String>,
    allow_failure: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ExecutableWifiUplinkPlan {
    display: WifiUplinkPlan,
    commands: Vec<ExecutableCommand>,
}

pub fn build_wifi_uplink_plan(request: &WifiUplinkRequest) -> Result<WifiUplinkPlan, String> {
    Ok(build_executable_wifi_uplink_plan(request)?.display)
}

pub async fn execute_wifi_uplink_plan(
    request: WifiUplinkRequest,
) -> Result<WifiUplinkExecution, String> {
    let dry_run = request.dry_run;
    let executable_plan = build_executable_wifi_uplink_plan(&request)?;

    if dry_run {
        return Ok(WifiUplinkExecution {
            plan: executable_plan.display,
            dry_run,
            executions: Vec::new(),
            saved_config: None,
        });
    }

    let mut executions = Vec::new();

    for command in &executable_plan.commands {
        let program = resolve_program(&command.display.program);
        let output = TokioCommand::new(&program)
            .args(&command.actual_args)
            .output()
            .await
            .map_err(|err| format!("failed to run {}: {err}", command.display.program))?;

        let execution = WifiCommandExecution {
            command: command.display.clone(),
            status_code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
            success: output.status.success(),
        };
        let success = execution.success;
        let allow_failure = command.allow_failure;
        executions.push(execution);

        if !success && !allow_failure {
            return Ok(WifiUplinkExecution {
                plan: executable_plan.display,
                dry_run,
                executions,
                saved_config: None,
            });
        }
    }

    Ok(WifiUplinkExecution {
        plan: executable_plan.display,
        dry_run,
        executions,
        saved_config: Some(request.to_saved_config()),
    })
}

impl WifiUplinkRequest {
    pub fn to_saved_config(&self) -> WifiUplinkConfig {
        WifiUplinkConfig {
            interface_name: self.interface_name.trim().to_string(),
            ssid: self.ssid.trim().to_string(),
            country_code: sanitize_country_code(self.country_code.clone()),
            psk_configured: self.psk.as_deref().is_some_and(|psk| !psk.is_empty()),
        }
    }
}

fn build_executable_wifi_uplink_plan(
    request: &WifiUplinkRequest,
) -> Result<ExecutableWifiUplinkPlan, String> {
    let interface_name = request.interface_name.trim();
    if interface_name.is_empty() {
        return Err("interface_name is required".to_string());
    }

    let ssid = request.ssid.trim();
    if ssid.is_empty() {
        return Err("ssid is required".to_string());
    }

    let mut commands = Vec::new();

    if let Some(country_code) = sanitize_country_code(request.country_code.clone()) {
        commands.push(command(
            "iw",
            vec!["reg".to_string(), "set".to_string(), country_code],
            None,
        ));
    }

    commands.push(command(
        "nmcli",
        vec!["radio".to_string(), "wifi".to_string(), "on".to_string()],
        None,
    ));

    commands.push(command(
        "nmcli",
        vec![
            "device".to_string(),
            "wifi".to_string(),
            "rescan".to_string(),
            "ifname".to_string(),
            interface_name.to_string(),
        ],
        None,
    ));

    let connection_name = format!("fieldsurvey-uplink-{interface_name}");

    commands.push(command_allow_failure(
        "nmcli",
        vec![
            "connection".to_string(),
            "delete".to_string(),
            connection_name.clone(),
        ],
        None,
    ));

    commands.push(command(
        "nmcli",
        vec![
            "connection".to_string(),
            "add".to_string(),
            "type".to_string(),
            "wifi".to_string(),
            "ifname".to_string(),
            interface_name.to_string(),
            "con-name".to_string(),
            connection_name.clone(),
            "ssid".to_string(),
            ssid.to_string(),
        ],
        None,
    ));

    if let Some(psk) = request
        .psk
        .as_deref()
        .map(str::trim)
        .filter(|psk| !psk.is_empty())
    {
        commands.push(command(
            "nmcli",
            vec![
                "connection".to_string(),
                "modify".to_string(),
                connection_name.clone(),
                "wifi-sec.key-mgmt".to_string(),
                "wpa-psk".to_string(),
                "wifi-sec.psk".to_string(),
                psk.to_string(),
            ],
            Some(vec![
                "connection".to_string(),
                "modify".to_string(),
                connection_name.clone(),
                "wifi-sec.key-mgmt".to_string(),
                "wpa-psk".to_string(),
                "wifi-sec.psk".to_string(),
                "********".to_string(),
            ]),
        ));
    }

    commands.push(command(
        "nmcli",
        vec![
            "connection".to_string(),
            "modify".to_string(),
            connection_name.clone(),
            "connection.autoconnect".to_string(),
            "yes".to_string(),
        ],
        None,
    ));

    commands.push(command(
        "nmcli",
        vec![
            "--wait".to_string(),
            "20".to_string(),
            "connection".to_string(),
            "up".to_string(),
            connection_name,
            "ifname".to_string(),
            interface_name.to_string(),
        ],
        None,
    ));

    let display = WifiUplinkPlan {
        commands: commands
            .iter()
            .map(|command| command.display.clone())
            .collect(),
    };

    Ok(ExecutableWifiUplinkPlan { display, commands })
}

fn command(
    program: &str,
    actual_args: Vec<String>,
    display_args: Option<Vec<String>>,
) -> ExecutableCommand {
    ExecutableCommand {
        display: CommandSpec {
            program: program.to_string(),
            args: display_args.unwrap_or_else(|| actual_args.clone()),
            requires_root: true,
        },
        actual_args,
        allow_failure: false,
    }
}

fn command_allow_failure(
    program: &str,
    actual_args: Vec<String>,
    display_args: Option<Vec<String>>,
) -> ExecutableCommand {
    ExecutableCommand {
        display: CommandSpec {
            program: program.to_string(),
            args: display_args.unwrap_or_else(|| actual_args.clone()),
            requires_root: true,
        },
        actual_args,
        allow_failure: true,
    }
}

fn resolve_program(program: &str) -> PathBuf {
    match program {
        "iw" => ["/usr/sbin/iw", "/sbin/iw", "/usr/bin/iw", "/bin/iw"],
        "nmcli" => [
            "/usr/bin/nmcli",
            "/bin/nmcli",
            "/usr/sbin/nmcli",
            "/sbin/nmcli",
        ],
        _ => return PathBuf::from(program),
    }
    .iter()
    .map(PathBuf::from)
    .find(|path| path.exists())
    .unwrap_or_else(|| PathBuf::from(program))
}

fn default_uplink_interface() -> String {
    "wlan0".to_string()
}

fn default_dry_run() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_redacted_wifi_uplink_plan() {
        let plan = build_wifi_uplink_plan(&WifiUplinkRequest {
            interface_name: "wlan0".to_string(),
            ssid: "LabNet".to_string(),
            psk: Some("secret-passphrase".to_string()),
            country_code: Some("us".to_string()),
            dry_run: true,
        })
        .unwrap();

        assert_eq!(plan.commands[0].args, ["reg", "set", "US"]);
        let connect = plan.commands.last().unwrap();
        assert_eq!(
            connect.args,
            [
                "--wait",
                "20",
                "connection",
                "up",
                "fieldsurvey-uplink-wlan0",
                "ifname",
                "wlan0"
            ]
        );

        let security = plan
            .commands
            .iter()
            .find(|command| command.args.contains(&"wifi-sec.key-mgmt".to_string()))
            .unwrap();
        assert!(security.args.contains(&"wpa-psk".to_string()));
        assert!(security.args.contains(&"********".to_string()));
        assert!(!security.args.contains(&"secret-passphrase".to_string()));
    }

    #[test]
    fn converts_request_to_saved_config_without_password() {
        let saved = WifiUplinkRequest {
            interface_name: " wlan0 ".to_string(),
            ssid: " LabNet ".to_string(),
            psk: Some("secret-passphrase".to_string()),
            country_code: Some("us".to_string()),
            dry_run: false,
        }
        .to_saved_config();

        assert_eq!(saved.interface_name, "wlan0");
        assert_eq!(saved.ssid, "LabNet");
        assert_eq!(saved.country_code.as_deref(), Some("US"));
        assert!(saved.psk_configured);
    }
}
