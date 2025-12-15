use rustler::{Encoder, Env, ResourceArc, Term};
use tokio::runtime::Runtime;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

struct EngineResource {
    runtime: Runtime,
    srql: srql::EmbeddedSrql,
}

impl rustler::Resource for EngineResource {}

#[rustler::nif(schedule = "DirtyIo")]
fn init(
    env: Env,
    database_url: String,
    root_cert: Option<String>,
    client_cert: Option<String>,
    client_key: Option<String>,
    pool_size: u32,
) -> Term {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(err) => {
            return (
                atoms::error(),
                format!("failed to start tokio runtime: {err}"),
            )
                .encode(env)
        }
    };

    let mut config = srql::config::AppConfig::embedded(database_url);
    config.max_pool_size = pool_size.max(1);
    config.pg_ssl_root_cert = root_cert;
    config.pg_ssl_cert = client_cert;
    config.pg_ssl_key = client_key;

    let srql = match runtime.block_on(srql::EmbeddedSrql::new(config)) {
        Ok(engine) => engine,
        Err(err) => return (atoms::error(), format!("failed to init SRQL: {err}")).encode(env),
    };

    let resource = ResourceArc::new(EngineResource { runtime, srql });
    (atoms::ok(), resource).encode(env)
}

#[rustler::nif(schedule = "DirtyIo")]
fn query(
    env: Env,
    engine: ResourceArc<EngineResource>,
    srql_query: String,
    limit: Option<i64>,
    cursor: Option<String>,
    direction: Option<String>,
    mode: Option<String>,
) -> Term {
    let direction = match direction.as_deref() {
        Some("prev") => srql::QueryDirection::Prev,
        _ => srql::QueryDirection::Next,
    };

    let request = srql::QueryRequest {
        query: srql_query,
        limit,
        cursor,
        direction,
        mode,
    };

    let response = match engine
        .runtime
        .block_on(engine.srql.query.execute_query(request))
    {
        Ok(response) => response,
        Err(err) => return (atoms::error(), err.to_string()).encode(env),
    };

    match serde_json::to_string(&response) {
        Ok(json) => (atoms::ok(), json).encode(env),
        Err(err) => (
            atoms::error(),
            format!("failed to encode SRQL response: {err}"),
        )
            .encode(env),
    }
}

fn load(env: Env, _info: Term) -> bool {
    env.register::<EngineResource>().is_ok()
}

rustler::init!("Elixir.ServiceRadarWebNG.SRQL.Native", load = load);
