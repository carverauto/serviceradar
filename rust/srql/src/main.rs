use srql::telemetry;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    telemetry::init_tracing();
    srql::run().await
}
