# Design: Rewrite db-event-writer in Elixir

## Overview

This document describes the technical design for rewriting the Go db-event-writer as an Elixir GenServer-based system within core-elx.

## Current Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Current Architecture                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────┐    ┌───────────────┐    ┌───────────────────────────┐   │
│  │  Go Services  │    │ db-event-     │    │      core-elx             │   │
│  │  (pollers,    │───▶│ writer (Go)   │    │  (ClusterHealth,          │   │
│  │  agents, etc) │    │               │    │   Oban, Ash, etc)         │   │
│  └───────────────┘    └───────────────┘    └───────────────────────────┘   │
│          │                   │                        │                    │
│          ▼                   ▼                        ▼                    │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                        NATS JetStream                                 │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                 │                                          │
│                                 ▼                                          │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                      CNPG/Timescale                                   │ │
│  │  pgx pool (Go)           │           Ecto pool (Elixir)               │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Problems:**
1. Two separate database connection pools
2. Separate container for db-event-writer
3. Embedded migrations drift from canonical schema
4. No shared supervision/monitoring

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Target Architecture                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────┐                                                         │
│  │  Go Services  │                                                         │
│  │  (pollers,    │──────────────────────────┐                              │
│  │  agents, etc) │                          │                              │
│  └───────────────┘                          │                              │
│                                             ▼                              │
│                          ┌───────────────────────────────────────────────┐ │
│                          │                NATS JetStream                 │ │
│                          └───────────────────────────────────────────────┘ │
│                                             │                              │
│                                             ▼                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         core-elx                                    │   │
│  │  ┌─────────────────────────────────────────────────────────────┐   │   │
│  │  │                  EventWriter.Supervisor                      │   │   │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │   │   │
│  │  │  │  Broadway   │  │  Processors │  │  NatsConnection     │  │   │   │
│  │  │  │  Pipeline   │  │  (batched)  │  │  (reconnect mgmt)   │  │   │   │
│  │  │  └─────────────┘  └─────────────┘  └─────────────────────┘  │   │   │
│  │  └─────────────────────────────────────────────────────────────┘   │   │
│  │                                                                     │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐    │   │
│  │  │ ClusterHealth│  │ Oban/AshOban │  │  Ash Resources/API     │    │   │
│  │  └──────────────┘  └──────────────┘  └────────────────────────┘    │   │
│  │                              │                                      │   │
│  │                              ▼                                      │   │
│  │  ┌───────────────────────────────────────────────────────────────┐ │   │
│  │  │                      Ecto / Repo                               │ │   │
│  │  └───────────────────────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                             │                              │
│                                             ▼                              │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                         CNPG/Timescale                                │ │
│  │                    (single Ecto connection pool)                      │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Benefits:**
1. Single database connection pool (Ecto)
2. Unified supervision tree
3. Shared telemetry/metrics
4. No migration drift (Ash/Ecto manages schema)

## Component Design

### EventWriter.Supervisor

```elixir
defmodule ServiceRadar.EventWriter.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = EventWriter.Config.load()

    children = [
      {EventWriter.NatsConnection, config.nats},
      {EventWriter.Broadway, config.streams}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### Broadway Pipeline

Broadway provides:
- Back-pressure handling
- Batching
- Acknowledgment management
- Failure handling

```elixir
defmodule ServiceRadar.EventWriter.Broadway do
  use Broadway

  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {EventWriter.Producer, opts},
        transformer: {__MODULE__, :transform, []},
        concurrency: 2
      ],
      processors: [
        default: [concurrency: 4]
      ],
      batchers: [
        telemetry: [batch_size: 100, batch_timeout: 1000],
        events: [batch_size: 100, batch_timeout: 1000],
        sweep: [batch_size: 50, batch_timeout: 2000],
        netflow: [batch_size: 200, batch_timeout: 500],
        otel: [batch_size: 100, batch_timeout: 1000],
        logs: [batch_size: 100, batch_timeout: 1000]
      ]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    # Route to appropriate batcher based on subject
    batcher = determine_batcher(message.metadata.subject)
    Broadway.Message.put_batcher(message, batcher)
  end

  @impl true
  def handle_batch(batcher, messages, _batch_info, _context) do
    processor = get_processor(batcher)

    case processor.process_batch(messages) do
      :ok -> messages
      {:error, reason} ->
        Enum.map(messages, &Broadway.Message.failed(&1, reason))
    end
  end
end
```

### NATS JetStream Producer

Custom Broadway producer for NATS JetStream:

```elixir
defmodule ServiceRadar.EventWriter.Producer do
  use GenStage

  @behaviour Broadway.Producer

  def init(opts) do
    {:ok, conn} = connect_to_nats(opts)
    {:ok, consumer} = create_consumer(conn, opts)

    {:producer, %{conn: conn, consumer: consumer, demand: 0}}
  end

  def handle_demand(demand, state) do
    messages = fetch_messages(state.consumer, demand)
    {:noreply, messages, %{state | demand: 0}}
  end
end
```

### Processor Behaviour

```elixir
defmodule ServiceRadar.EventWriter.Processor do
  @callback process_batch([Broadway.Message.t()]) :: :ok | {:error, term()}
end

defmodule ServiceRadar.EventWriter.Processors.Telemetry do
  @behaviour ServiceRadar.EventWriter.Processor

  @impl true
  def process_batch(messages) do
    rows = Enum.map(messages, &parse_telemetry_message/1)

    ServiceRadar.Repo.insert_all("timeseries_metrics", rows,
      on_conflict: :nothing,
      returning: false
    )

    :ok
  rescue
    e -> {:error, e}
  end
end
```

## Database Interaction

### Schemaless Inserts

For hypertables, use schemaless `insert_all` to avoid schema coupling:

```elixir
def insert_telemetry_batch(rows) do
  Repo.insert_all("timeseries_metrics", rows,
    on_conflict: :nothing,
    returning: false,
    timeout: 30_000
  )
end
```

### Connection Pooling

Leverage existing Ecto pool configuration:

```elixir
# config/runtime.exs
config :serviceradar, ServiceRadar.Repo,
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "20")),
  queue_target: 50,
  queue_interval: 1000
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `EVENT_WRITER_ENABLED` | Enable EventWriter | `false` |
| `EVENT_WRITER_NATS_URL` | NATS connection URL | `nats://nats:4222` |
| `EVENT_WRITER_NATS_STREAM` | JetStream stream name | `TELEMETRY` |
| `EVENT_WRITER_NATS_CONSUMER` | Consumer name | `db-writer` |
| `EVENT_WRITER_BATCH_SIZE` | Batch size for inserts | `100` |
| `EVENT_WRITER_BATCH_TIMEOUT` | Batch timeout (ms) | `1000` |

### Multi-Stream Configuration

Support for multiple streams via environment or config file:

```elixir
config :serviceradar, ServiceRadar.EventWriter,
  streams: [
    %{name: "TELEMETRY", subject: "telemetry.>", processor: Processors.Telemetry},
    %{name: "EVENTS", subject: "events.>", processor: Processors.Events},
    %{name: "SWEEP", subject: "sweep.>", processor: Processors.Sweep},
    %{name: "NETFLOW", subject: "netflow.>", processor: Processors.NetFlow},
    %{name: "OTEL_METRICS", subject: "otel.metrics.>", processor: Processors.OtelMetrics},
    %{name: "OTEL_TRACES", subject: "otel.traces.>", processor: Processors.OtelTraces},
    %{name: "LOGS", subject: "logs.>", processor: Processors.Logs}
  ]
```

## Error Handling

### Transient Failures

- NATS disconnection: Reconnect with exponential backoff
- Database timeout: Retry batch with smaller size
- Parse error: NACK message, send to dead-letter queue

### Fatal Failures

- Invalid configuration: Log and exit supervisor
- Persistent database errors: Circuit breaker pattern

```elixir
defmodule ServiceRadar.EventWriter.CircuitBreaker do
  use GenServer

  def check_health do
    case Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end
end
```

## Telemetry

### Metrics

```elixir
:telemetry.execute(
  [:serviceradar, :event_writer, :batch_processed],
  %{count: length(messages), duration: duration_ms},
  %{stream: stream_name, processor: processor}
)

:telemetry.execute(
  [:serviceradar, :event_writer, :message_failed],
  %{count: 1},
  %{stream: stream_name, reason: reason}
)
```

### Integration with Existing Telemetry

Add to `ServiceRadarWebNGWeb.Telemetry`:

```elixir
counter("serviceradar.event_writer.batch_processed.count",
  tags: [:stream, :processor],
  description: "Number of batches processed"
),
summary("serviceradar.event_writer.batch_processed.duration",
  tags: [:stream, :processor],
  unit: {:native, :millisecond},
  description: "Batch processing duration"
)
```

## Testing Strategy

### Unit Tests

```elixir
defmodule ServiceRadar.EventWriter.Processors.TelemetryTest do
  use ServiceRadar.DataCase

  test "process_batch inserts telemetry metrics" do
    messages = [build_telemetry_message(), build_telemetry_message()]

    assert :ok = Telemetry.process_batch(messages)
    assert Repo.aggregate("timeseries_metrics", :count) == 2
  end
end
```

### Integration Tests

```elixir
defmodule ServiceRadar.EventWriter.IntegrationTest do
  use ServiceRadar.DataCase

  @tag :integration
  test "Broadway pipeline processes NATS messages" do
    # Publish test messages to NATS
    :ok = publish_test_messages(10)

    # Wait for processing
    Process.sleep(2000)

    # Verify database records
    assert Repo.aggregate("timeseries_metrics", :count) >= 10
  end
end
```

## Migration Path

### Phase 1: Parallel Operation

Run both Go and Elixir writers:

```yaml
# docker-compose.yml
core-elx:
  environment:
    - EVENT_WRITER_ENABLED=false  # Start disabled

db-event-writer:
  # Keep running for now
```

### Phase 2: Switch Over

```yaml
core-elx:
  environment:
    - EVENT_WRITER_ENABLED=true

# db-event-writer commented out or removed
```

### Phase 3: Cleanup

Remove Go db-event-writer from stack.

## Performance Considerations

### Batch Size Tuning

| Stream | Expected Rate | Recommended Batch Size |
|--------|--------------|----------------------|
| Telemetry | 1000/s | 100 |
| Events | 100/s | 50 |
| Sweep | 10/s | 20 |
| NetFlow | 5000/s | 200 |
| OTEL Metrics | 500/s | 100 |
| Logs | 500/s | 100 |

### Memory Management

Broadway handles back-pressure automatically. Configure:

```elixir
producer: [
  module: {EventWriter.Producer, opts},
  concurrency: 2,
  rate_limiting: [
    allowed_messages: 1000,
    interval: 1000
  ]
]
```

## Alternatives Considered

### 1. Fix Go db-event-writer migrations

**Rejected because:**
- Doesn't solve the dual-stack problem
- Requires ongoing sync between Go and repo migrations
- Misses opportunity to consolidate

### 2. Use Oban for message processing

**Rejected because:**
- Oban is designed for job processing, not stream consumption
- Would require bridging NATS → Oban jobs → DB
- Adds unnecessary indirection

### 3. Use GenStage directly without Broadway

**Rejected because:**
- Broadway provides production-ready batching/acknowledgment
- Less code to maintain
- Better observability out of the box
