use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat, RestartHandle};
use log::info;
use profiler::{
    config::Config,
    run_standalone_profiling,
    server::{create_profiler, start_server},
    setup::{
        handle_generate_config, load_configuration, log_configuration_info, parse_bind_address,
        resolve_config_path, setup_logging_and_parse_args,
    },
    template,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = setup_logging_and_parse_args()?;

    if args.generate_config {
        return handle_generate_config();
    }

    // Check if we're in standalone profiling mode
    if args.is_standalone_mode() {
        // Validate standalone arguments
        if let Err(e) = args.validate_standalone() {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }

        let pid = args.pid.unwrap(); // Safe because is_standalone_mode() checks this
        info!("Starting standalone profiling mode for PID {}", pid);

        run_standalone_profiling(
            pid,
            args.duration,
            args.frequency,
            args.output_file,
            args.format,
            args.tui,
        )
        .await?;
        return Ok(());
    }

    // Server mode - existing logic
    let config_path = resolve_config_path(&args);
    let use_kv = std::env::var("CONFIG_SOURCE").ok().as_deref() == Some("kv");
    let config: Config = if use_kv {
        template::ensure_config_file(&config_path)?;
        let mut bootstrap = Bootstrap::new(BootstrapOptions {
            service_name: "profiler".to_string(),
            config_path: config_path.display().to_string(),
            format: ConfigFormat::Toml,
            kv_key: Some("config/profiler.toml".to_string()),
            seed_kv: true,
            watch_kv: true,
        })
        .await?;
        let cfg = bootstrap.load().await?;

        if let Some(watcher) = bootstrap.watch::<Config>().await? {
            let restarter = RestartHandle::new("profiler", "config/profiler.toml");
            tokio::spawn(async move {
                let mut cfg_watcher = watcher;
                while cfg_watcher.recv().await.is_some() {
                    restarter.trigger();
                }
            });
        }

        cfg
    } else {
        load_configuration(&args)?
    };
    let addr = parse_bind_address(&config)?;

    log_configuration_info(&config);

    let profiler = create_profiler().await?;

    start_server(addr, profiler).await
}
