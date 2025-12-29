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
          password: {:system, "NATS_PASSWORD"}
        ],
        batch_size: 100,
        batch_timeout: 1000,
        streams: [
          %{name: "OTEL_METRICS", subject: "otel.metrics.>", processor: ServiceRadar.EventWriter.Processors.OtelMetrics},
          %{name: "OTEL_TRACES", subject: "otel.traces.>", processor: ServiceRadar.EventWriter.Processors.OtelTraces},
          %{name: "LOGS", subject: "logs.>", processor: ServiceRadar.EventWriter.Processors.Logs}
        ]

  ## Environment Variables

  - `EVENT_WRITER_ENABLED` - Enable/disable the EventWriter (default: false)
  - `EVENT_WRITER_NATS_URL` - NATS connection URL (e.g., nats://localhost:4222)
  - `EVENT_WRITER_BATCH_SIZE` - Batch size for inserts (default: 100)
  - `EVENT_WRITER_BATCH_TIMEOUT` - Batch timeout in ms (default: 1000)
  """

  require Logger

  @default_batch_size 100
  @default_batch_timeout 1_000
  @default_consumer_name "serviceradar-event-writer"

  defstruct [
    :enabled,
    :nats,
    :batch_size,
    :batch_timeout,
    :consumer_name,
    :streams
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          nats: nats_config(),
          batch_size: pos_integer(),
          batch_timeout: pos_integer(),
          consumer_name: String.t(),
          streams: [stream_config()]
        }

  @type nats_config :: %{
          host: String.t(),
          port: pos_integer(),
          user: String.t() | nil,
          password: String.t() | nil,
          tls: boolean() | keyword()
        }

  @type stream_config :: %{
          name: String.t(),
          subject: String.t(),
          processor: module(),
          batch_size: pos_integer() | nil,
          batch_timeout: pos_integer() | nil
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
      streams: load_streams(config)
    }
  end

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
  Returns the default stream configurations.
  """
  @spec default_streams() :: [stream_config()]
  def default_streams do
    [
      %{
        name: "OTEL_METRICS",
        subject: "otel.metrics.>",
        processor: ServiceRadar.EventWriter.Processors.OtelMetrics,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "OTEL_TRACES",
        subject: "otel.traces.>",
        processor: ServiceRadar.EventWriter.Processors.OtelTraces,
        batch_size: 100,
        batch_timeout: 1_000
      },
      %{
        name: "LOGS",
        subject: "logs.>",
        processor: ServiceRadar.EventWriter.Processors.Logs,
        batch_size: 100,
        batch_timeout: 1_000
      }
    ]
  end

  # Private functions

  defp load_nats_config(config) do
    nats_config = Keyword.get(config, :nats, [])

    # Check for NATS URL environment variable
    {host, port} = parse_nats_url()

    %{
      host: host || Keyword.get(nats_config, :host, "localhost"),
      port: port || Keyword.get(nats_config, :port, 4222),
      user: resolve_value(Keyword.get(nats_config, :user)),
      password: resolve_value(Keyword.get(nats_config, :password)),
      tls: Keyword.get(nats_config, :tls, false)
    }
  end

  defp parse_nats_url do
    case System.get_env("EVENT_WRITER_NATS_URL") do
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

  defp load_streams(config) do
    case Keyword.get(config, :streams) do
      nil -> default_streams()
      streams when is_list(streams) -> streams
    end
  end

  defp resolve_value({:system, env_var}), do: System.get_env(env_var)
  defp resolve_value(value), do: value
end
