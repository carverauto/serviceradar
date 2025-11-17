use once_cell::sync::OnceCell;
use tracing_subscriber::{fmt, EnvFilter};

static INIT: OnceCell<()> = OnceCell::new();

pub fn init_tracing() {
    let _ = INIT.get_or_init(|| {
        let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
        fmt().with_env_filter(filter).with_target(false).init();
    });
}
