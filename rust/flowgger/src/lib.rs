#[cfg(feature = "coroutines")]
#[macro_use]
extern crate may;

#[cfg(feature = "capnp-recompile")]
pub mod record_capnp;

pub mod flowgger;

/// Start a flowgger instance starting from a file path
///
/// # Parameters
/// - `config_file`: path to a configuration file in &str format
///
/// # Panics
/// This panics when the configuration file was not able to be parsed, when there's non supported input/outputs or encoder/decoders in the configuration
/// file.
pub fn start(config_file: &str) {
    flowgger::start(config_file);
}
