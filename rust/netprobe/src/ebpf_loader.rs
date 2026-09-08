use std::path::Path;

use anyhow::{Context, Result};
use aya::{Ebpf, EbpfLoader};

use crate::{config::Config, lifecycle::DEFAULT_BPF_PIN_DIR};

const FLOW_TABLE_MAP: &str = "flow_table";

pub fn load_netprobe_ebpf(object_path: &Path, config: &Config) -> Result<Ebpf> {
    let flow_table_max_entries = config.effective_flow_table_max_entries();
    EbpfLoader::new()
        .map_pin_path(DEFAULT_BPF_PIN_DIR)
        .set_max_entries(FLOW_TABLE_MAP, flow_table_max_entries)
        .load_file(object_path)
        .with_context(|| {
            format!(
                "load netprobe eBPF object from {} with {FLOW_TABLE_MAP} max_entries={flow_table_max_entries}",
                object_path.display()
            )
        })
}
