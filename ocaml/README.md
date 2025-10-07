# SRQL Translator

An OCaml-based translator for the ServiceRadar Query Language (SRQL). SRQL keeps its name but the syntax is now ASQ-aligned key:value.

## Overview

SRQL provides an intuitive key:value syntax for querying data that gets translated into SQL for Proton/ClickHouse. This project includes:
- A planner/validator and translator pipeline
- A REST API server built with Dream framework
- Unit tests for the planner/translator

## Features

- **ASQ-aligned syntax**: key:value tokens with nesting and lists
- **Flexible filters**: AND/OR logic, IN lists, wildcards, negation
- **Streaming and analytics**: windowing and simple stats
- **REST API**: HTTP endpoint for integrating with other services

## Installation

### Prerequisites

```bash
# Install OPAM (OCaml package manager)
sh <(curl -sL https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh)

# Initialize OPAM
opam init
eval $(opam env)

# Install dependencies
opam install dune dream yojson ppx_deriving lwt_ppx alcotest
```

### Build

```bash
# Clone the repository
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar/ocaml

# Build the project
dune build

# Run tests
dune test
```

## Usage

### Web Server

Start the REST API server:

```bash
dune exec srql-translator
# Server runs on http://localhost:8080
```

Send translation requests:

```bash
curl -X POST http://localhost:8080/translate \
  -H "Content-Type: application/json" \
  -d '{"query": "in:devices hostname:server time:today"}'

# Response:
# {"sql": "SELECT * FROM unified_devices WHERE to_date(last_seen) = today() AND hostname = 'server'", "hint": "auto"}

You can optionally provide a boundedness hint to guide execution mode downstream and to the execution API:

```bash
curl -X POST http://localhost:8080/translate \
  -H "Content-Type: application/json" \
  -d '{"query": "in:devices discovery_sources:(sweep) stats:\"count()\"", "bounded_mode": "bounded"}'

# Response:
# {"sql": "SELECT count() FROM unified_devices WHERE has(discovery_sources, 'sweep')", "hint": "bounded"}
```

Supported hint fields:
- `bounded_mode`: one of `bounded`, `unbounded`, or `auto` (preferred)
- `bounded`: boolean (legacy/alternative), maps to `bounded`/`unbounded`

### Execution API: Streaming vs Snapshot

The `/api/query` endpoint supports both streaming (unbounded) and snapshot (bounded) execution. The UI can signal the intent via an HTTP header or JSON fields. The backend will default to snapshot unless explicitly asked to stream.

- Header: `X-SRQL-Mode: stream | snapshot | auto`
- Body (fallbacks if header not provided):
  - `mode`: `"stream" | "snapshot" | "auto"`
  - `bounded_mode`: `"unbounded" | "bounded" | "auto"`
  - `bounded`: `true | false` (maps to `bounded`/`unbounded`)

Examples:

```bash
# Snapshot (bounded) request
curl -X POST http://localhost:8080/api/query \
  -H "Content-Type: application/json" \
  -H "X-SRQL-Mode: snapshot" \
  -d '{"query": "in:devices hostname:server time:today", "limit": 50}'

# Streaming (unbounded) request via header
curl -X POST http://localhost:8080/api/query \
  -H "Content-Type: application/json" \
  -H "X-SRQL-Mode: stream" \
  -d '{"query": "in:logs service:myapp"}'

# Alternatively, signal via body (no header)
curl -X POST http://localhost:8080/api/query \
  -H "Content-Type: application/json" \
  -d '{"query": "in:logs service:myapp", "mode": "stream"}'

# Legacy-style body fields also work
curl -X POST http://localhost:8080/api/query \
  -H "Content-Type: application/json" \
  -d '{"query": "in:devices discovery_sources:(sweep)", "bounded_mode": "bounded"}'
```

Notes:
- Snapshot requests will wrap the SQL `FROM <table>` as `FROM table(<table>)` for Proton snapshot semantics.
- Streaming requests omit the `table(...)` wrapper and may run until canceled. UI should prefer a streaming transport (SSE/WebSocket) for long-lived queries.
- `auto` currently behaves like snapshot unless enhanced detection is implemented.

### WebSocket Streaming

For unbounded queries, use the WebSocket endpoint to receive incremental rows:

- Endpoint: `GET ws://localhost:8080/api/stream?query=<SRQL>`
- Messages are JSON objects with `type` of `columns`, `data`, `complete`, or `error`.

Example (JavaScript):

```js
const ws = new WebSocket("ws://localhost:8080/api/stream?query=" + encodeURIComponent("in:logs service:myapp"));
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.type === "columns") {
    console.log("columns", msg.columns);
  } else if (msg.type === "data") {
    console.log("row", msg.data);
  } else if (msg.type === "complete") {
    console.log("stream complete");
  } else if (msg.type === "error") {
    console.error("stream error", msg.error);
  }
};
```

Auth and CORS/Origin checks are not enabled in the OCaml server yet; see Go `pkg/core/api/stream.go` and `auth.go` for reference if you need parity.
```

### Command Line Interface

CLI examples omitted for now; use the HTTP API for translation and execution.

## SRQL Syntax (ASQ-aligned)

- Entities: `in:devices`, `in:services`, `in:activity` (aliases to events), `in:flows`, etc.
- Attributes: `key:value` pairs; nested groups: `parent:(child:value, ...)`.
- Lists: `key:(v1,v2,...)` compiles to `IN (...)`.
- Negation: prefix with `!` for NOT, including lists: `!key:(...)`.
- Wildcards: `%` in values uses `LIKE`/`NOT LIKE`.
- Time: `time:today|yesterday|last_7d|[start,end]` or `timeFrame:"7 Days"`.
- Stats/Windows: `stats:"count() by field"` and `window:5m` for bucketing.

Examples:

```
in:services port:(22,2222) timeFrame:"7 Days"
in:devices services:(name:(facebook)) type:MRIs timeFrame:"7 Days"
in:activity type:"Connection Started" connection:(from:(type:"Mobile Phone") direction:"From > To" to:(partition:Corporate tag:Managed)) timeFrame:"7 Days"
in:devices !model:(Hikvision,Zhejiang) name:%cam% time:last_24h
```

## Project Structure

```
srql/
├── dune-project          # Project metadata
├── srql-translator.opam  # OPAM package definition
├── srql/
│   ├── bin/
│   │   ├── dune         # Binary targets configuration
│   │   ├── main.ml      # Web server entry point
│   │   └── cli.ml       # CLI entry point
│   ├── lib/
│   │   ├── dune         # Library configuration
│   │   ├── sql_ir.ml         # Internal relational IR (was ast.ml)
│   │   ├── query_ast.ml      # ASQ spec
│   │   ├── query_parser.ml   # ASQ tokenizer/parser
│   │   ├── query_planner.ml  # Planner + mapping
│   │   ├── query_validator.ml# Validation
│   │   └── translator.ml     # IR to SQL translator
│   └── test/
│       ├── dune         # Test configuration
│       └── test_translator.ml # Unit tests
```

## Development

### Running Tests

```bash
# Run all tests
dune test

# Run tests with output
dune test --force --no-buffer

# Run specific test file
dune exec -- srql/test/test_query_engine
```

### Test Coverage

Tests cover entity mapping, timeFrame parsing, lists, wildcards, negation, nested groups, stats and windowing using Alcotest.

### Extending syntax

Add new key aliases/mappings in `query_planner.ml` and `translator.ml`, and extend `query_parser.ml` for additional token shapes as needed.

### Grammar Extension Ideas

- `JOIN` operations
- `GROUP BY` and `HAVING` clauses
- `ORDER BY` clause
- Aggregate functions (`sum`, `avg`, `max`, `min`)
- Subqueries
- `IN` operator for list membership

## API Reference

### POST /translate

Translates an SRQL (ASQ-aligned) query to SQL.

**Request:**
```json
{
  "query": "in:devices hostname:server time:today"
}
```

**Response (Success):**
```json
{
  "sql": "SELECT * FROM unified_devices WHERE to_date(last_seen) = today() AND hostname = 'server'"
}
```

**Response (Error):**
```json
{
  "error": "Syntax error near character 15"
}
```

### GET /health

Health check endpoint.

**Response:**
```json
{
  "status": "ok"
}
```

- Built with [Dream](https://aantron.github.io/dream/) web framework
- Planner/validator and translator implemented in pure OCaml
- JSON handling via [Yojson](https://github.com/ocaml-community/yojson)
