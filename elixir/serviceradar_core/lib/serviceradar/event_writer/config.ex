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
    :consumer_lag_poll_interval_ms
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
          consumer_lag_poll_interval_ms: pos_integer()
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
          optional(:consumer_inactive_threshold) => non_neg_integer() | nil
        }

  @doc """
  Loads the EventWriter configuration from the application environment.
  """
  @spec load() :: t()
  def load do
    config = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])

    %__MODULE__{
      enabled: enabled?(),
      nats: load_nats_config(config),
      batch_size: load_batch_size(config),
      batch_timeout: load_batch_timeout(config),
      consumer_name: load_consumer_name(config),
      producer_name: Keyword.get(config, :producer_name),
      streams: load_streams(config),
      consumer_pull_batch_size: load_consumer_pull_batch_size(config),
      max_ack_pending: load_max_ack_pending(config),
      processor_concurrency: load_processor_concurrency(config),
      ack_wait_ns: load_ack_wait_ns(config),
      max_deliver: load_max_deliver(config),
      consumer_lag_poll_interval_ms: load_consumer_lag_poll_interval_ms(config)
    }
  end

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
  def durable_name(base, stream_name) when is_binary(base) and is_binary(stream_name) do
    suffix =
      stream_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    "#{base}-#{suffix}"
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
      %{
        name: "SFLOW_RAW",
        subject: "flows.raw.sflow",
        processor: Flows,
        batch_size: 50,
        batch_timeout: 500
      },
      %{
        name: "NETFLOW_RAW",
        subject: "flows.raw.netflow",
        processor: Flows,
        batch_size: 50,
        batch_timeout: 500
      }
    ]
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
    case Keyword.get(config, :streams) do
      nil -> default_streams()
      streams when is_list(streams) -> streams
    end
  end

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
