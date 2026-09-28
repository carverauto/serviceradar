defmodule ServiceRadar.EventWriter.Config do
  @moduledoc """
  Configuration management for the EventWriter.

  Loads configuration from application environment and environment variables,
  with support for multi-stream configurations.

  ## Configuration

  Configure in runtime.exs:

      config :serviceradar_core, ServiceRadar.EventWriter,
        enabled: true,
        nats: [
          host: "localhost",
          port: 4222,
          user: "serviceradar",
          password: {:system, "NATS_PASSWORD"},
          creds_file: "/etc/serviceradar/creds/platform.creds"
        ],
        batch_size: 100,
        batch_timeout: 1000,
        streams: [
          %{name: "EVENTS", subject: "events.>", processor: ServiceRadar.EventWriter.Processors.Events},
          %{
            name: "FALCO",
            stream_name: "events",
            subject: "falco.logs",
            processor: ServiceRadar.EventWriter.Processors.FalcoEvents
          },
          %{name: "OTEL_METRICS", subject: "otel.metrics.>", processor: ServiceRadar.EventWriter.Processors.OtelMetrics},
          %{name: "OTEL_TRACES", subject: "otel.traces.>", processor: ServiceRadar.EventWriter.Processors.OtelTraces},
          %{name: "METRICS", subject: "metrics.>", processor: ServiceRadar.EventWriter.Processors.Metrics},
          %{name: "LOGS", subject: "logs.>", processor: ServiceRadar.EventWriter.Processors.Logs}
        ]

  ## Environment Variables

  - `EVENT_WRITER_ENABLED` - Enable/disable the EventWriter (default: false)
  - `EVENT_WRITER_NATS_URL` - NATS connection URL (e.g., nats://localhost:4222)
  - `EVENT_WRITER_NATS_CREDS_FILE` - Path to NATS .creds file (JWT auth)
  - `EVENT_WRITER_BATCH_SIZE` - Batch size for inserts (default: 100)
  - `EVENT_WRITER_BATCH_TIMEOUT` - Batch timeout in ms (default: 1000)
  - `EVENT_WRITER_CONSUMER_PULL_BATCH_SIZE` - Max JetStream messages requested per pull (default: 16)
  - `EVENT_WRITER_CONSUMER_LAG_POLL_INTERVAL_MS` - JetStream consumer lag poll interval (default: 30000)
  """

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.EventWriter.Processors.Flows
  alias ServiceRadar.EventWriter.Processors.PowerDNS

  require Logger

  @default_batch_size 100
  @default_batch_timeout 1_000
  @default_consumer_name "serviceradar-event-writer"

  # Flow-control defaults. The Broadway producer uses JetStream pull consumers
  # and requests at most this many NATS messages per pull request. These are
  # messages, not expanded metric rows; high-payload streams should stay small.
  @default_consumer_pull_batch_size 16
  @default_consumer_lag_poll_interval_ms 30_000
  # Flow pipeline long-poll window (2s). Zero disables expires (legacy no_wait).
  @default_flow_pull_expires_ns 2_000_000_000
  @default_flow_pull_batch_size 64
  @default_flow_max_ack_pending 1024
  # Conservative create-if-missing defaults (10 GiB / 6h). flow-collector owns
  # live retention reconcile; EventWriter must not thrash these on existing streams.
  @default_flows_stream_max_bytes 10_737_418_240
  @default_flows_stream_max_age_ns 21_600_000_000_000

  # `max_ack_pending` is still the server-side delivered-but-unacked ceiling for
  # each durable, but pull mode means it is a safety bound rather than a push
  # prefetch target.
  @default_max_ack_pending 256
  @default_processor_concurrency 10
  # 120s (in ns) gives a slow batch room before the server redelivers, avoiding
  # the redelivery storm a 30s ack_wait caused once a backlog formed.
  @default_ack_wait_ns 120_000_000_000
  @default_max_deliver 5

  defstruct [
    :enabled,
    :nats,
    :batch_size,
    :batch_timeout,
    :consumer_name,
    :producer_name,
    :streams,
    :consumer_pull_batch_size,
    :max_ack_pending,
    :processor_concurrency,
    :ack_wait_ns,
    :max_deliver,
    :consumer_lag_poll_interval_ms,
    :pull_expires_ns
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          nats: nats_config(),
          batch_size: pos_integer(),
          batch_timeout: pos_integer(),
          consumer_name: String.t(),
          producer_name: atom() | nil,
          streams: [stream_config()],
          consumer_pull_batch_size: pos_integer(),
          max_ack_pending: pos_integer(),
          processor_concurrency: pos_integer(),
          ack_wait_ns: pos_integer(),
          max_deliver: pos_integer(),
          consumer_lag_poll_interval_ms: pos_integer(),
          pull_expires_ns: non_neg_integer() | nil
        }

  @type nats_config :: %{
          host: String.t(),
          port: pos_integer(),
          user: String.t() | nil,
          password: String.t() | nil,
          tls: boolean() | keyword(),
          jwt: String.t() | nil,
          nkey_seed: String.t() | nil,
          creds_file: String.t() | nil
        }

  @type stream_config :: %{
          required(:name) => String.t(),
          required(:subject) => String.t(),
          required(:processor) => module(),
          optional(:stream_name) => String.t() | nil,
          optional(:batch_size) => pos_integer() | nil,
          optional(:batch_timeout) => pos_integer() | nil,
          optional(:stream_retention) => String.t() | nil,
          optional(:stream_storage) => String.t() | nil,
          optional(:stream_discard) => String.t() | nil,
          optional(:stream_replicas) => pos_integer() | nil,
          optional(:stream_max_bytes) => pos_integer() | nil,
          optional(:stream_max_age) => pos_integer() | nil,
          optional(:stream_duplicate_window) => pos_integer() | nil,
          optional(:consumer_max_deliver) => integer() | nil,
          optional(:consumer_max_ack_pending) => pos_integer() | nil,
          optional(:consumer_ack_wait_ns) => pos_integer() | nil,
          optional(:consumer_pull_batch_size) => pos_integer() | nil,
          optional(:consumer_deliver_policy) => atom() | nil,
          optional(:consumer_inactive_threshold) => non_neg_integer() | nil,
          optional(:allow_stream_fallback) => boolean() | nil,
          optional(:reconcile_stream_shape) => boolean() | nil
        }

  @doc """
  Loads the EventWriter configuration from the application environment.
  """
  @spec load() :: t()
  def load do
    config = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])
    consumer_name = load_consumer_name(config)
    streams = load_non_flow_streams(config)

    # Shared pipeline must also fail closed on durable/inbox collisions after
    # canonicalization (long EVENT_WRITER_CONSUMER_NAME prefixes included).
    assert_no_canonical_consumer_collisions!(streams, consumer_name)

    %__MODULE__{
      enabled: enabled?(),
      nats: load_nats_config(config),
      batch_size: load_batch_size(config),
      batch_timeout: load_batch_timeout(config),
      consumer_name: consumer_name,
      producer_name: Keyword.get(config, :producer_name),
      streams: streams,
      consumer_pull_batch_size: load_consumer_pull_batch_size(config),
      max_ack_pending: load_max_ack_pending(config),
      processor_concurrency: load_processor_concurrency(config),
      ack_wait_ns: load_ack_wait_ns(config),
      max_deliver: load_max_deliver(config),
      consumer_lag_poll_interval_ms: load_consumer_lag_poll_interval_ms(config),
      # Shared pipeline keeps the legacy no_wait + timer path (pull_expires_ns nil/0).
      pull_expires_ns: 0
    }
  end

  @doc """
  Loads EventWriter config for the dedicated raw-flow Broadway pipeline.

  Flow subjects use an independent GenStage demand domain, long-poll JetStream
  pulls, and the dedicated `flows` stream retention stanza.
  """
  @spec load_flow() :: t()
  def load_flow do
    config = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])
    base = load()

    {pull_batch, pull_batch_override?} =
      load_flow_int(
        "EVENT_WRITER_FLOW_CONSUMER_PULL_BATCH_SIZE",
        config,
        :flow_consumer_pull_batch_size,
        @default_flow_pull_batch_size
      )

    {max_ack, max_ack_override?} =
      load_flow_int(
        "EVENT_WRITER_FLOW_MAX_ACK_PENDING",
        config,
        :flow_max_ack_pending,
        @default_flow_max_ack_pending
      )

    {pull_expires, _pull_expires_override?} =
      load_flow_int(
        "EVENT_WRITER_FLOW_PULL_EXPIRES_NS",
        config,
        :flow_pull_expires_ns,
        @default_flow_pull_expires_ns
      )

    # Precedence: env/top-level override > explicit per-stream > default.
    # put_new only when no explicit env/top-level override is present.
    streams =
      config
      |> load_flow_streams()
      |> maybe_append_events_drain_streams()
      |> Enum.map(fn stream ->
        stream
        |> put_flow_tuning(:consumer_pull_batch_size, pull_batch, pull_batch_override?)
        |> put_flow_tuning(:consumer_max_ack_pending, max_ack, max_ack_override?)
      end)

    # Fail closed if two stream configs collapse to one durable/inbox after
    # durable_name/2 / pull-subject canonicalization.
    assert_no_canonical_consumer_collisions!(streams, base.consumer_name)

    %{
      base
      | streams: streams,
        producer_name:
          Keyword.get(config, :flow_producer_name, ServiceRadar.EventWriter.FlowProducer),
        consumer_pull_batch_size: pull_batch,
        max_ack_pending: max_ack,
        pull_expires_ns: pull_expires
    }
  end

  @doc """
  Returns true when a stream config is raw NetFlow/sFlow persistence (`flows.raw.*`).

  `flow.host-slice.*` must **not** become EventWriter flow consumers (attribution
  joining is currently unsupported/out of scope and would dilute Broadway pull
  budget).
  """
  @spec flow_stream?(stream_config() | map()) :: boolean()
  def flow_stream?(%{subject: subject}) when is_binary(subject),
    do: String.starts_with?(subject, "flows.raw.")

  def flow_stream?(%{name: name}) when name in ["NETFLOW_RAW", "SFLOW_RAW"], do: true
  def flow_stream?(_), do: false

  @doc """
  JetStream stream a config entry should bind to.

  Logical names such as `SFLOW_RAW` / `NETFLOW_RAW` are consumer keys, not
  stream names. Creating a stream under that name with `flows.raw.*` subjects
  fails with JetStream 10065 (subjects overlap) against the dedicated `flows`
  stream.
  """
  @spec jetstream_stream_name(stream_config() | map()) :: String.t()
  def jetstream_stream_name(%{stream_name: name}) when is_binary(name) and name != "", do: name

  def jetstream_stream_name(stream) when is_map(stream) do
    if flow_stream?(stream), do: "flows", else: Map.get(stream, :name, "")
  end

  @doc """
  Default pull batch size for the dedicated flow EventWriter pipeline.
  """
  @spec default_flow_pull_batch_size() :: pos_integer()
  def default_flow_pull_batch_size, do: @default_flow_pull_batch_size

  @doc """
  Default max_ack_pending for the dedicated flow EventWriter pipeline.
  """
  @spec default_flow_max_ack_pending() :: pos_integer()
  def default_flow_max_ack_pending, do: @default_flow_max_ack_pending

  @doc """
  Default long-poll expires (ns) for the dedicated flow EventWriter pipeline.
  """
  @spec default_flow_pull_expires_ns() :: pos_integer()
  def default_flow_pull_expires_ns, do: @default_flow_pull_expires_ns

  @doc """
  Returns the default per-consumer `max_ack_pending` flow-control bound.
  """
  @spec default_max_ack_pending() :: pos_integer()
  def default_max_ack_pending, do: @default_max_ack_pending

  @doc """
  Returns the default JetStream pull batch size in messages.
  """
  @spec default_consumer_pull_batch_size() :: pos_integer()
  def default_consumer_pull_batch_size, do: @default_consumer_pull_batch_size

  @doc """
  Returns the default JetStream consumer lag poll interval in milliseconds.
  """
  @spec default_consumer_lag_poll_interval_ms() :: pos_integer()
  def default_consumer_lag_poll_interval_ms, do: @default_consumer_lag_poll_interval_ms

  @doc """
  Builds the durable consumer name used for a configured EventWriter stream.
  """
  @spec durable_name(String.t(), String.t()) :: String.t()
  # NATS JetStream consumer names are limited to 255 bytes (err 10102).
  @nats_max_consumer_name_bytes 255

  def durable_name(base, stream_name) when is_binary(base) and is_binary(stream_name) do
    suffix =
      stream_name
      |> sanitize_durable_token()
      |> then(fn s -> if s == "", do: "stream", else: s end)

    # Preferred form keeps backward-compatible durables for normal-length names
    # (e.g. serviceradar-event-writer-netflow-raw) so drain cursors still match.
    preferred = "#{base}-#{suffix}"

    if byte_size(preferred) <= @nats_max_consumer_name_bytes do
      preferred
    else
      # Over budget: reserve a stable hash of the stream key and shrink the base
      # (long EVENT_WRITER_CONSUMER_NAME), never prefix-slice the completed name.
      hash =
        :sha256
        |> :crypto.hash(stream_name)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)

      base_token =
        base
        |> sanitize_durable_token()
        |> then(fn s -> if s == "", do: "ew", else: s end)

      # name = base_part-suffix_part-hash  (ASCII only → safe byte truncates)
      # budget for base+suffix+two hyphens = 255 - 8
      body_budget = @nats_max_consumer_name_bytes - 8 - 2

      {base_part, suffix_part} =
        if byte_size(suffix) + 1 <= body_budget do
          base_budget = max(body_budget - byte_size(suffix) - 1, 1)
          {binary_part(base_token, 0, min(byte_size(base_token), base_budget)), suffix}
        else
          base_budget = max(div(body_budget, 3), 1)
          suffix_budget = max(body_budget - base_budget - 1, 1)

          {
            binary_part(base_token, 0, min(byte_size(base_token), base_budget)),
            binary_part(suffix, 0, min(byte_size(suffix), suffix_budget))
          }
        end

      name = "#{base_part}-#{suffix_part}-#{hash}"

      if byte_size(name) <= @nats_max_consumer_name_bytes do
        name
      else
        # Last resort: short base + hash only (still unique per stream_name).
        "ew-#{hash}"
      end
    end
  end

  defp sanitize_durable_token(token) when is_binary(token) do
    token
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Returns the default Broadway processor concurrency.
  """
  @spec default_processor_concurrency() :: pos_integer()
  def default_processor_concurrency, do: @default_processor_concurrency

  @doc """
  Returns the default consumer `ack_wait` in nanoseconds.
  """
  @spec default_ack_wait_ns() :: pos_integer()
  def default_ack_wait_ns, do: @default_ack_wait_ns

  @doc """
  Returns the default consumer `max_deliver`.
  """
  @spec default_max_deliver() :: pos_integer()
  def default_max_deliver, do: @default_max_deliver

  @doc """
  Checks if the EventWriter is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("EVENT_WRITER_ENABLED") do
      nil ->
        config = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])
        Keyword.get(config, :enabled, false)

      value when value in ["true", "1", "yes"] ->
        true

      _ ->
        false
    end
  end

  @spec k8s_nodes_stream() :: stream_config()
  def k8s_nodes_stream do
    %{
      name: "K8S_NODES",
      stream_name: "k8s_inventory",
      subject: "inventory.k8s.nodes",
      processor: ServiceRadar.EventWriter.Processors.K8sNodes,
      batch_size: 1,
      batch_timeout: 2_000,
      stream_retention: "limits",
      stream_storage: "file",
      stream_discard: "old",
      stream_max_bytes: 1_073_741_824,
      stream_max_age: 86_400_000_000_000
    }
  end

  @doc """
  The dedicated ANALYTICS_PREDICTIONS stream/consumer definition.

  Dedicated verdict stream (restore-anomaly-alerting design D9): the shared
  `events` stream is byte-capped and the otel collector pins its MaxAge to
  30m, so anomaly/capacity verdicts died in any core outage >30m.
  1 GiB / 24h, discard old. Existing deployments keep consuming from `events`
  until the operator releases `signals.analytics.>` there (see the change
  runbook); fresh installs converge automatically.

  Shared by `default_streams/0` and both runtime.exs stream lists so the
  retention stanza cannot drift.
  """
  @spec analytics_predictions_stream() :: stream_config()
  def analytics_predictions_stream do
    %{
      name: "ANALYTICS_PREDICTIONS",
      stream_name: "analytics_predictions",
      subject: "signals.analytics.predictions.>",
      processor: AnalyticsSignals,
      batch_size: 100,
      batch_timeout: 1_000,
      stream_retention: "limits",
      stream_storage: "file",
      stream_discard: "old",
      stream_max_bytes: 1_073_741_824,
      stream_max_age: 86_400_000_000_000
    }
  end

  @doc """
  The `EDGE_RECORD` stream/consumer definition (task 0.12's one real durable
  route -- minimum slice only).

  Subject/stream naming matches `ServiceRadar.Edge.StreamRoute`'s already-frozen
  placement exactly (`telemetry.edge-record.v1.bulk.pNN` ->
  `TELEMETRY_EDGE_RECORD_V1_BULK`), not an independently invented convention.
  Only the BULK traffic class is wired: 0.12's own acceptance scope is "ONE
  committed BULK `SweepObservationBatchV1` fixture"; INTERACTIVE is a separate,
  not-yet-provisioned stream this task does not touch. `batch_size: 1` because
  `ServiceRadar.EventWriter.Processors.EdgeRecord` runs one real,
  all-or-nothing CNPG transaction per record -- a redelivered message must
  never be folded into another record's batch outcome.
  """
  @spec edge_record_stream() :: stream_config()
  def edge_record_stream do
    %{
      name: "EDGE_RECORD",
      stream_name: "TELEMETRY_EDGE_RECORD_V1_BULK",
      subject: "telemetry.edge-record.v1.bulk.>",
      processor: ServiceRadar.EventWriter.Processors.EdgeRecord,
      batch_size: 1,
      batch_timeout: 1_000,
      stream_retention: "limits",
      stream_storage: "file",
      stream_discard: "old",
      stream_max_bytes: 1_073_741_824,
      stream_max_age: 86_400_000_000_000
    }
  end

  @doc """
  Returns the default stream configurations.

  Subjects are unprefixed in single-deployment deployments.
  """
  @spec default_streams() :: [stream_config()]
  def default_streams do
    [
      %{
        name: "EVENTS",
        stream_name: "events",
        subject: "events.>",
        processor: Events,
        batch_size: 100,
        batch_timeout: 1_000,
        # Retention guard: if the consumer ever falls behind, the shared `events`
        # stream must degrade gracefully (drop oldest) instead of growing until
        # core OOMs. 8 GiB / 24h, discard old.
        stream_retention: "limits",
        stream_storage: "file",
        stream_discard: "old",
        stream_max_bytes: 8_589_934_592,
        stream_max_age: 86_400_000_000_000
      },
      %{
        name: "PDNS_OCSF",
        stream_name: "events",
        subject: "pdns.ocsf",
        processor: PowerDNS,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "FALCO",
        stream_name: "events",
        subject: "falco.logs",
        processor: ServiceRadar.EventWriter.Processors.FalcoEvents,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "TRIVY",
        stream_name: "trivy_reports",
        subject: "trivy.report.>",
        processor: ServiceRadar.EventWriter.Processors.TrivyReports,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "K8S_INVENTORY",
        stream_name: "k8s_inventory",
        # Must overlap stream subjects from k8s-inventory publisher
        # (inventory.k8s.public_endpoints[+.>] — not the broader inventory.k8s.>).
        subject: "inventory.k8s.public_endpoints",
        processor: ServiceRadar.EventWriter.Processors.K8sPublicEndpoints,
        # Full-cluster snapshots; process one message at a time.
        batch_size: 1,
        batch_timeout: 2_000,
        stream_retention: "limits",
        stream_storage: "file",
        stream_discard: "old",
        stream_max_bytes: 1_073_741_824,
        stream_max_age: 86_400_000_000_000
      },
      k8s_nodes_stream(),
      %{
        name: "OTEL_METRICS",
        stream_name: "events",
        subject: "otel.metrics.>",
        processor: ServiceRadar.EventWriter.Processors.OtelMetrics,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "OTEL_TRACES",
        stream_name: "events",
        subject: "otel.traces.>",
        processor: ServiceRadar.EventWriter.Processors.OtelTraces,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "LOGS",
        stream_name: "events",
        subject: "logs.>",
        processor: ServiceRadar.EventWriter.Processors.Logs,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "METRICS",
        stream_name: "metrics",
        subject: "metrics.>",
        processor: ServiceRadar.EventWriter.Processors.Metrics,
        batch_size: 500,
        batch_timeout: 500,
        stream_retention: "limits",
        stream_storage: "file",
        stream_discard: "old",
        stream_max_bytes: 1_073_741_824,
        stream_max_age: 1_800_000_000_000,
        # fj #3788 REC4: dedup exact redeliveries (consumer_max_deliver: 5) within a
        # 2-minute window, keyed on the Nats-Msg-Id (= ingress_id) the gateway stamps.
        stream_duplicate_window: 120_000_000_000,
        # Sized to fill the 500-msg Broadway batch in a few JetStream round-trips.
        # Was 4 (LOWER than the default 16) on the highest-volume stream, so the
        # producer did ~125 pull round-trips per batch — pure pull-request churn,
        # the dominant cost of EventWriter.Producer at idle-ish load. 64 is bounded
        # by max_ack_pending (256) and the producer's max_buffered overflow guard,
        # so back-pressure is unchanged.
        consumer_pull_batch_size: 64,
        consumer_max_deliver: 5
      },
      %{
        name: "SCAN_RESULTS",
        stream_name: "scan_results",
        subject: "scans.results.>",
        processor: ServiceRadar.EventWriter.Processors.AdhocScan,
        batch_size: 200,
        batch_timeout: 500,
        # Ad-hoc scan results are interactive and low-volume; keep a small,
        # short-lived stream (results are also persisted durably in CNPG).
        stream_retention: "limits",
        stream_storage: "file",
        stream_discard: "old",
        stream_max_bytes: 268_435_456,
        stream_max_age: 3_600_000_000_000
      },
      %{
        name: "BMP_CAUSAL",
        stream_name: "events",
        subject: "bmp.events.>",
        processor: AnalyticsSignals,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "ARANCINI_CAUSAL",
        stream_name: "ARANCINI_CAUSAL",
        subject: "arancini.updates.>",
        processor: AnalyticsSignals,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "SIEM_CAUSAL",
        stream_name: "events",
        subject: "siem.events.>",
        processor: AnalyticsSignals,
        batch_size: 100,
        batch_timeout: 1_000
      },
      analytics_predictions_stream(),
      edge_record_stream()
      # Raw flows live in default_flow_streams/0 (dedicated Broadway demand domain).
    ]
  end

  @doc """
  Default stream configurations for the dedicated raw-flow EventWriter pipeline.

  Publishes land on the dedicated JetStream stream `flows` (not shared `events`).
  """
  @spec default_flow_streams() :: [stream_config()]
  def default_flow_streams do
    # No per-stream pull/ack literals — load_flow/0 fills defaults via put_new.
    # Retention create-if-missing only; collector owns reconcile_stream_shape.
    base = %{
      stream_name: "flows",
      processor: Flows,
      batch_size: 100,
      batch_timeout: 500,
      stream_retention: "limits",
      stream_storage: "file",
      stream_discard: "old",
      stream_max_bytes: @default_flows_stream_max_bytes,
      stream_max_age: @default_flows_stream_max_age_ns,
      allow_stream_fallback: false,
      reconcile_stream_shape: false
    }

    [
      Map.merge(base, %{name: "SFLOW_RAW", subject: "flows.raw.sflow"}),
      Map.merge(base, %{name: "NETFLOW_RAW", subject: "flows.raw.netflow"})
    ]
  end

  # Dual-consume drain: keep reading residual flows.raw.* from the legacy
  # `events` stream until pending is zero / MaxAge expires. New publishes land
  # on `flows`. Disable with EVENT_WRITER_FLOW_DRAIN_EVENTS=false after drain.
  #
  # Critical: reuse the pre-cutover durable name (durable_source_name) so JetStream
  # resumes the existing ACK cursor. A brand-new durable with deliver_policy:all
  # would replay retained history that the old durable already ACKed (duplicate
  # ocsf_network_activity rows; on_conflict does not dedupe).
  # Shared source of truth for extension raw-flow subjects (live + drain).
  # EVENT_WRITER_FLOW_EXTRA_SUBJECTS is preferred; legacy
  # EVENT_WRITER_FLOW_DRAIN_EXTRA_SUBJECTS is still accepted.
  @doc false
  def extra_flow_subjects do
    primary =
      System.get_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS") ||
        System.get_env("EVENT_WRITER_FLOW_DRAIN_EXTRA_SUBJECTS") ||
        ""

    subjects =
      primary
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # Whole-token NATS wildcards (`*` / `>`) are stream-ownership filters only —
    # EventWriter requires concrete leaves so consumers do not double-ACK or
    # silently miss live coverage. Fail closed rather than drop them quietly.
    wildcards = Enum.filter(subjects, &nats_filter_overlaps_flow_namespace?/1)

    if wildcards != [] do
      raise ArgumentError,
            "EVENT_WRITER_FLOW_EXTRA_SUBJECTS / EVENT_WRITER_FLOW_DRAIN_EXTRA_SUBJECTS " <>
              "reject NATS wildcard filters that intersect " <>
              "flows.raw.> / flow.host-slice.>: #{inspect(wildcards)}. " <>
              "Use concrete subjects (embedded */> in a token are literals)."
    end

    host_slices =
      Enum.filter(subjects, &String.starts_with?(&1, "flow.host-slice."))

    if host_slices != [] do
      raise ArgumentError,
            "EVENT_WRITER_FLOW_EXTRA_SUBJECTS rejects flow.host-slice.* subjects " <>
              "(host-slice attribution joining is currently unsupported/out of scope; " <>
              "subjects would be stored without a ServiceRadar consumer): #{inspect(host_slices)}"
    end

    subjects
    |> Enum.filter(&exact_raw_flow_subject?/1)
    # Defaults already have dedicated live/drain entries.
    |> Enum.reject(&(&1 in ["flows.raw.netflow", "flows.raw.sflow"]))
    |> Enum.uniq()
  end

  @doc """
  True when subject is a concrete NATS subject under `flows.raw.*` (no whole-token
  wildcards). Embedded `*`/`>` in a token (e.g. `vendor*name`) are literals.
  """
  @spec exact_raw_flow_subject?(String.t()) :: boolean()
  def exact_raw_flow_subject?(subject) when is_binary(subject) do
    String.starts_with?(subject, "flows.raw.") and exact_nats_subject?(subject)
  end

  @doc false
  def exact_nats_subject?(subject) when is_binary(subject) do
    protocol_valid_nats_subject?(subject) and
      subject
      |> String.split(".")
      |> Enum.all?(fn token -> token != "" and token != "*" and token != ">" end)
  end

  @doc false
  def protocol_valid_nats_subject?(subject) when is_binary(subject) do
    subject != "" and
      not String.starts_with?(subject, ".") and
      not String.ends_with?(subject, ".") and
      not String.contains?(subject, "..") and
      not String.contains?(subject, " ") and
      not String.contains?(subject, "\t") and
      not String.contains?(subject, "\r") and
      not String.contains?(subject, "\n")
  end

  @doc false
  def flow_subject_stream_name(subject) when is_binary(subject) do
    # Keep names short: final durable is "#{consumer}-#{downcase name}" and NATS
    # caps consumer names at 255 bytes. Hash disambiguates; readable prefix is budgeted.
    hash =
      :sha256
      |> :crypto.hash(subject)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    readable =
      subject
      |> String.replace_prefix("flows.raw.", "")
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]+/, "_")
      |> String.trim("_")

    # "FLOW_" + readable + "_" + 8-char hash; total stream-name budget ~48 so
    # even with long consumer base + "_EVENTS_DRAIN" we stay under 255.
    max_readable = 24

    readable =
      if byte_size(readable) > max_readable do
        binary_part(readable, 0, max_readable)
      else
        readable
      end

    "FLOW_#{readable}_#{hash}"
  end

  defp extra_live_flow_streams(existing) do
    existing_subjects = MapSet.new(existing, & &1.subject)

    extras =
      extra_flow_subjects()
      |> Enum.reject(&MapSet.member?(existing_subjects, &1))
      |> Enum.map(fn subject ->
        name = flow_subject_stream_name(subject)

        %{
          name: name,
          stream_name: "flows",
          subject: subject,
          processor: Flows,
          batch_size: 100,
          batch_timeout: 500,
          stream_retention: "limits",
          stream_storage: "file",
          stream_discard: "old",
          stream_max_bytes: @default_flows_stream_max_bytes,
          stream_max_age: @default_flows_stream_max_age_ns,
          allow_stream_fallback: false,
          reconcile_stream_shape: false
        }
      end)

    extras
  end

  @doc false
  def assert_no_canonical_consumer_collisions!(streams, consumer_base)
      when is_list(streams) and is_binary(consumer_base) do
    # Durables are per JetStream stream: live (flows) and drain (events) may
    # intentionally share durable_source_name so the legacy ACK cursor resumes.
    streams
    |> Enum.group_by(&jetstream_stream_name/1)
    |> Enum.each(fn {js_stream, group} ->
      durables =
        Enum.map(group, fn stream ->
          key = Map.get(stream, :durable_source_name) || stream.name
          durable_name(consumer_base, key)
        end)

      if length(durables) != length(Enum.uniq(durables)) do
        raise ArgumentError,
              "colliding JetStream durable names on stream #{inspect(js_stream)} after canonicalization: #{inspect(durables)}"
      end
    end)

    # Pull inboxes are connection-global (one Gnat per producer).
    pull_keys =
      Enum.map(streams, fn stream ->
        suffix =
          stream.name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "_")
          |> String.trim("_")

        "#{consumer_base}.#{suffix}"
      end)

    if length(pull_keys) != length(Enum.uniq(pull_keys)) do
      raise ArgumentError,
            "colliding pull inbox keys after canonicalization: #{inspect(pull_keys)}"
    end

    :ok
  end

  defp maybe_append_events_drain_streams(streams) do
    if System.get_env("EVENT_WRITER_FLOW_DRAIN_EVENTS", "true") in ~w(true 1 yes) do
      drain_base = %{
        stream_name: "events",
        processor: Flows,
        batch_size: 100,
        batch_timeout: 500,
        allow_stream_fallback: false,
        reconcile_stream_shape: false,
        ensure_stream: false,
        # Best effort: these read leftover flow messages out of the shared
        # `events` stream from before flows got their own. Whether `events`
        # still carries a given flow subject depends on how long ago that
        # deployment cut over, and a subject it never carried makes NATS reject
        # the consumer with 10093 ("filter subject is not a valid subset of the
        # interest subjects"). A backlog reader must never be able to take the
        # live pipeline down with it -- see setup_jetstream_consumers/2.
        best_effort: true
      }

      # Drain every live flows.* entry (defaults + EXTRA subjects).
      live =
        streams
        |> Enum.filter(&flow_stream?/1)
        |> Enum.reject(fn s -> Map.get(s, :stream_name) == "events" end)

      live
      |> Enum.map(fn stream ->
        # Legacy NETFLOW/SFLOW durables used deliver_policy:all; if missing, :new
        # avoids replaying ACKed history. Extension extras never had a pre-cutover
        # durable, so absent INFO must use :all to drain retained backlog.
        if_absent =
          if stream.name in ["NETFLOW_RAW", "SFLOW_RAW"] do
            :new
          else
            :all
          end

        Map.merge(drain_base, %{
          name: "#{stream.name}_EVENTS_DRAIN",
          subject: stream.subject,
          durable_source_name: stream.name,
          consumer_deliver_policy_if_absent: if_absent
        })
      end)
      |> then(&(streams ++ &1))
    else
      streams
    end
  end

  defp put_flow_tuning(stream, key, value, true = _override?), do: Map.put(stream, key, value)
  defp put_flow_tuning(stream, key, value, false), do: Map.put_new(stream, key, value)

  # Returns {value, override?} where override? is true when env is set OR the
  # application config keyword explicitly contains the key. Runtime must not
  # always inject default 64/1024 or those look like explicit overrides.
  defp load_flow_int(env_name, config, app_key, default)
       when is_binary(env_name) and is_atom(app_key) do
    case System.get_env(env_name) do
      nil ->
        case Keyword.fetch(config, app_key) do
          {:ok, app_value} ->
            # Explicit app key — but treat release defaults as non-override when
            # they equal the hard-coded default AND no env is set. Operators who
            # set the same value explicitly still get override behavior only when
            # the key was intentionally different; for true "always override"
            # they set the env. Here: only mark override when app value differs
            # from the module default OR when a dedicated origin marker is set.
            # Simpler contract: env wins; app key only overrides when present AND
            # we use put for app-only when env absent — still overwrites custom
            # streams. Review wants: omit app keys when env absent.
            # So app key present => override (runtime must omit defaults).
            {sanitize_non_neg_int(app_value, default), true}

          :error ->
            {sanitize_non_neg_int(default, default), false}
        end

      value ->
        case Integer.parse(value) do
          {int, _} -> {sanitize_non_neg_int(int, default), true}
          :error -> {sanitize_non_neg_int(default, default), false}
        end
    end
  end

  # Private functions

  @doc false
  @spec build_nats_config(keyword() | map(), keyword()) :: nats_config()
  def build_nats_config(nats_config, opts \\ [])
      when is_list(nats_config) or is_map(nats_config) do
    url_env = Keyword.get(opts, :url_env, "EVENT_WRITER_NATS_URL")
    creds_file_env = Keyword.get(opts, :creds_file_env, "EVENT_WRITER_NATS_CREDS_FILE")

    # Check for NATS URL environment variable
    {host, port} = parse_nats_url(url_env)

    creds_file =
      System.get_env(creds_file_env) ||
        resolve_value(config_get(nats_config, :creds_file))

    creds_file = normalize(creds_file)
    jwt = nats_config |> config_get(:jwt) |> resolve_value() |> normalize()
    nkey_seed = nats_config |> config_get(:nkey_seed) |> resolve_value() |> normalize()
    {jwt, nkey_seed} = load_creds(creds_file, jwt, nkey_seed)

    %{
      host: host || config_get(nats_config, :host, "localhost"),
      port: port || config_get(nats_config, :port, 4222),
      user: resolve_value(config_get(nats_config, :user)),
      password: resolve_value(config_get(nats_config, :password)),
      tls: config_get(nats_config, :tls, false),
      creds_file: creds_file,
      jwt: jwt,
      nkey_seed: nkey_seed
    }
  end

  defp load_nats_config(config) do
    config
    |> Keyword.get(:nats, [])
    |> build_nats_config()
  end

  defp parse_nats_url(env_name) do
    case System.get_env(env_name) do
      nil ->
        {nil, nil}

      url ->
        uri = URI.parse(url)
        {uri.host, uri.port}
    end
  end

  defp load_batch_size(config) do
    case System.get_env("EVENT_WRITER_BATCH_SIZE") do
      nil -> Keyword.get(config, :batch_size, @default_batch_size)
      value -> String.to_integer(value)
    end
  end

  defp load_batch_timeout(config) do
    case System.get_env("EVENT_WRITER_BATCH_TIMEOUT") do
      nil -> Keyword.get(config, :batch_timeout, @default_batch_timeout)
      value -> String.to_integer(value)
    end
  end

  defp load_consumer_name(config) do
    case System.get_env("EVENT_WRITER_CONSUMER_NAME") do
      nil -> Keyword.get(config, :consumer_name, @default_consumer_name)
      value -> value
    end
  end

  defp load_max_ack_pending(config) do
    load_positive_int(
      "EVENT_WRITER_MAX_ACK_PENDING",
      Keyword.get(config, :max_ack_pending, @default_max_ack_pending),
      @default_max_ack_pending
    )
  end

  defp load_consumer_pull_batch_size(config) do
    load_positive_int(
      "EVENT_WRITER_CONSUMER_PULL_BATCH_SIZE",
      Keyword.get(config, :consumer_pull_batch_size, @default_consumer_pull_batch_size),
      @default_consumer_pull_batch_size
    )
  end

  defp load_consumer_lag_poll_interval_ms(config) do
    load_positive_int(
      "EVENT_WRITER_CONSUMER_LAG_POLL_INTERVAL_MS",
      Keyword.get(
        config,
        :consumer_lag_poll_interval_ms,
        @default_consumer_lag_poll_interval_ms
      ),
      @default_consumer_lag_poll_interval_ms
    )
  end

  defp load_processor_concurrency(config) do
    load_positive_int(
      "EVENT_WRITER_PROCESSOR_CONCURRENCY",
      Keyword.get(config, :processor_concurrency, @default_processor_concurrency),
      @default_processor_concurrency
    )
  end

  defp load_ack_wait_ns(config) do
    # Accept seconds via env for ergonomics; store nanoseconds internally.
    case System.get_env("EVENT_WRITER_ACK_WAIT_SECONDS") do
      nil ->
        sanitize_positive_int(
          Keyword.get(config, :ack_wait_ns, @default_ack_wait_ns),
          @default_ack_wait_ns
        )

      value ->
        case Integer.parse(value) do
          {seconds, _} when seconds > 0 -> seconds * 1_000_000_000
          _ -> @default_ack_wait_ns
        end
    end
  end

  defp load_max_deliver(config) do
    load_positive_int(
      "EVENT_WRITER_MAX_DELIVER",
      Keyword.get(config, :max_deliver, @default_max_deliver),
      @default_max_deliver
    )
  end

  defp load_positive_int(env_name, configured, default) do
    case System.get_env(env_name) do
      nil ->
        sanitize_positive_int(configured, default)

      value ->
        case Integer.parse(value) do
          {parsed, _} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end

  defp sanitize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp sanitize_positive_int(_value, default), do: default

  defp load_streams(config) do
    streams =
      case Keyword.get(config, :streams) do
        nil -> default_streams()
        streams when is_list(streams) -> streams
      end

    # Apply the same subject guards as EXTRA env so custom :streams cannot
    # reintroduce wildcards or host-slice no-op consumers.
    Enum.each(streams, &assert_valid_event_writer_stream_subject!/1)
    streams
  end

  defp load_non_flow_streams(config) do
    config
    |> load_streams()
    |> Enum.reject(&flow_stream?/1)
  end

  defp load_flow_streams(config) do
    base =
      case Keyword.get(config, :flow_streams) do
        streams when is_list(streams) and streams != [] ->
          streams

        _ ->
          from_main =
            config
            |> load_streams()
            |> Enum.filter(&flow_stream?/1)

          if from_main == [], do: default_flow_streams(), else: from_main
      end

    Enum.each(base, &assert_valid_flow_pipeline_subject!/1)
    base ++ extra_live_flow_streams(base)
  end

  @doc false
  def assert_valid_event_writer_stream_subject!(stream) when is_map(stream) do
    subject = Map.get(stream, :subject) || Map.get(stream, "subject")

    cond do
      not is_binary(subject) or subject == "" ->
        :ok

      # Concrete flows.raw leaves are the only allowed EventWriter flow filters.
      exact_raw_flow_subject?(subject) ->
        :ok

      String.starts_with?(subject, "flow.host-slice.") ->
        raise ArgumentError,
              "EventWriter stream config rejects flow.host-slice.* subjects " <>
                "(host-slice attribution joining is currently unsupported/out of scope): #{inspect(subject)}"

      # Reject any NATS filter that intersects flows.raw.> or flow.host-slice.>
      # (symbolic intersection, not finite probe leaves).
      nats_filter_overlaps_flow_namespace?(subject) ->
        raise ArgumentError,
              "EventWriter stream config rejects filter #{inspect(subject)} that intersects " <>
                "flows.raw.> / flow.host-slice.> (would double-consume with NETFLOW/SFLOW leaves)"

      true ->
        :ok
    end
  end

  @doc false
  def assert_valid_flow_pipeline_subject!(stream) when is_map(stream) do
    assert_valid_event_writer_stream_subject!(stream)
    subject = Map.get(stream, :subject) || Map.get(stream, "subject")

    if is_binary(subject) and subject != "" and not exact_raw_flow_subject?(subject) do
      raise ArgumentError,
            "flow EventWriter pipeline only accepts concrete flows.raw.* subjects, got: #{inspect(subject)}"
    end

    :ok
  end

  @doc """
  True when a NATS **wildcard** filter intersects `flows.raw.>` or
  `flow.host-slice.>` (token language: `*` one token, `>` rest).
  Concrete leaves return false.
  """
  @spec nats_filter_overlaps_flow_namespace?(String.t()) :: boolean()
  def nats_filter_overlaps_flow_namespace?(filter) when is_binary(filter) do
    if exact_nats_subject?(filter) do
      false
    else
      nats_filters_intersect?(filter, "flows.raw.>") or
        nats_filters_intersect?(filter, "flow.host-slice.>")
    end
  end

  @doc false
  def nats_filters_intersect?(a, b) when is_binary(a) and is_binary(b) do
    filter_tokens_intersect?(String.split(a, "."), String.split(b, "."))
  end

  @doc false
  def nats_filter_covers?(broader, narrower) when is_binary(broader) and is_binary(narrower) do
    if broader == narrower do
      true
    else
      pattern_covers_tokens?(String.split(broader, "."), String.split(narrower, "."))
    end
  end

  defp filter_tokens_intersect?([], []), do: true
  defp filter_tokens_intersect?([], _), do: false
  defp filter_tokens_intersect?(_, []), do: false

  defp filter_tokens_intersect?([">"], b) when b != [], do: true
  defp filter_tokens_intersect?(a, [">"]) when a != [], do: true
  defp filter_tokens_intersect?([">" | _], _), do: false
  defp filter_tokens_intersect?(_, [">" | _]), do: false

  defp filter_tokens_intersect?(["*" | at], [_ | bt]), do: filter_tokens_intersect?(at, bt)
  defp filter_tokens_intersect?([_ | at], ["*" | bt]), do: filter_tokens_intersect?(at, bt)

  defp filter_tokens_intersect?([la | at], [lb | bt]) when la == lb,
    do: filter_tokens_intersect?(at, bt)

  defp filter_tokens_intersect?(_, _), do: false

  defp pattern_covers_tokens?(broader, narrower) do
    do_pattern_covers(broader, narrower)
  end

  defp do_pattern_covers([">"], narrower) when narrower != [], do: true
  defp do_pattern_covers([">"], []), do: false
  defp do_pattern_covers([], []), do: true
  defp do_pattern_covers([], _), do: false
  defp do_pattern_covers(_, []), do: false

  defp do_pattern_covers(["*" | bt], [nt | ntrest]) do
    if nt in ["*", ">"] do
      false
    else
      do_pattern_covers(bt, ntrest)
    end
  end

  defp do_pattern_covers([lit | bt], [nt | ntrest]) do
    cond do
      nt in ["*", ">"] -> false
      lit == nt -> do_pattern_covers(bt, ntrest)
      true -> false
    end
  end

  defp sanitize_non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp sanitize_non_neg_int(_value, default) when is_integer(default) and default >= 0,
    do: default

  defp sanitize_non_neg_int(_value, _default), do: 0

  defp config_get(config, key, default \\ nil)

  defp config_get(config, key, default) when is_list(config) do
    Keyword.get(config, key, default)
  end

  defp config_get(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, to_string(key), default))
  end

  defp load_creds(nil, jwt, nkey_seed), do: {jwt, nkey_seed}
  defp load_creds("", jwt, nkey_seed), do: {jwt, nkey_seed}

  defp load_creds(creds_file, jwt, nkey_seed) do
    case ServiceRadar.NATS.Creds.read(creds_file) do
      {:ok, creds} ->
        {creds.jwt, creds.nkey_seed}

      {:error, reason} ->
        Logger.warning(
          "Failed to read EventWriter NATS creds file #{creds_file}: #{inspect(reason)}"
        )

        {jwt, nkey_seed}
    end
  end

  defp resolve_value({:system, env_var}), do: System.get_env(env_var)
  defp resolve_value(value), do: value

  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value), do: value
end
