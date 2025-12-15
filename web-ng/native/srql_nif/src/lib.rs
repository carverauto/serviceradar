use rustler::{Encoder, Env, Term};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn translate(
    env: Env,
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

    let config = srql::config::AppConfig::embedded("postgres://unused/db".to_string());

    let response = match srql::query::translate_request(&config, request) {
        Ok(response) => response,
        Err(err) => return (atoms::error(), err.to_string()).encode(env),
    };

    match serde_json::to_string(&response) {
        Ok(json) => (atoms::ok(), json).encode(env),
        Err(err) => (
            atoms::error(),
            format!("failed to encode SRQL translation: {err}"),
        )
            .encode(env),
    }
}

rustler::init!("Elixir.ServiceRadarWebNG.SRQL.Native");
