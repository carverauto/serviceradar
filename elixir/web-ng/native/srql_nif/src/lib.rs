use rustler::{Encoder, Env, Term};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

/// Parse an SRQL query and return the AST as JSON.
/// This allows Elixir to consume the structured query without re-parsing.
#[rustler::nif(schedule = "DirtyCpu")]
fn parse_ast(env: Env, srql_query: String) -> Term {
    match srql::parser::parse(&srql_query) {
        Ok(ast) => match serde_json::to_string(&ast) {
            Ok(json) => (atoms::ok(), json).encode(env),
            Err(err) => (
                atoms::error(),
                format!("failed to encode SRQL AST: {err}"),
            )
                .encode(env),
        },
        Err(err) => (atoms::error(), err.to_string()).encode(env),
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
