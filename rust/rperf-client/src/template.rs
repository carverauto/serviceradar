use std::fs;
use std::path::Path;

pub const DEFAULT_TEMPLATE: &str = include_str!("../config/default_template.json");

pub fn ensure_config_file(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        return Ok(());
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    fs::write(path, DEFAULT_TEMPLATE)?;
    Ok(())
}
