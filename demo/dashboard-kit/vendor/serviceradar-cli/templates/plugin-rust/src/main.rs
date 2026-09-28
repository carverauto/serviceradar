use serviceradar_sdk_rust as sdk;

/// Decoded from the per-assignment configuration an operator sets in
/// ServiceRadar. Add fields here and declare them in config.schema.json to have
/// the UI render inputs for them.
#[derive(Debug, serde::Deserialize)]
#[serde(default)]
struct Config {
    message: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            message: "hello from __PLUGIN_NAME__".to_string(),
        }
    }
}

/// The manifest's `entrypoint`. The symbol name must match plugin.yaml.
#[unsafe(no_mangle)]
pub extern "C" fn run_check() {
    let _ = sdk::execute(|| {
        let config = sdk::load_config_or_default::<Config>()?;

        Ok(sdk::PluginResult::ok(config.message))
    });
}

fn main() {}
