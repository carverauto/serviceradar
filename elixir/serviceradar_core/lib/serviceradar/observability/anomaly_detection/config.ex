defmodule ServiceRadar.Observability.AnomalyDetection.Config do
  @moduledoc """
  Runtime configuration for the real-time anomaly analysis consumer.

  The analysis consumer has its own JetStream cursor and never shares the
  DB-sync EventWriter consumer. It defaults to processing only OTEL metrics so
  operators can validate the always-live stream before enabling host, SNMP, or
  flow subjects.
  """

  alias ServiceRadar.EventWriter.Config, as: EventWriterConfig

  @default_consumer_name "serviceradar-anomaly-analysis"
  @default_batch_size 100
  @default_batch_timeout 1_000
  @default_processor_concurrency 4
  @default_inactive_threshold_ns 300_000_000_000
  @default_enabled_subjects ["otel.metrics.>"]

  defstruct [
    :enabled,
    :nats,
    :batch_size,
    :batch_timeout,
    :consumer_name,
    :producer_name,
    :processor_concurrency,
    :enabled_subjects,
    :streams
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          nats: EventWriterConfig.nats_config(),
          batch_size: pos_integer(),
          batch_timeout: pos_integer(),
          consumer_name: String.t(),
          producer_name: atom(),
          processor_concurrency: pos_integer(),
          enabled_subjects: [String.t()],
          streams: [EventWriterConfig.stream_config()]
        }

  @doc """
  Returns true when the anomaly analysis consumer should be supervised.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("ANOMALY_ANALYSIS_CONSUMER_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :anomaly_analysis_consumer_enabled, false)
      value when is_binary(value) -> truthy?(value)
    end
  end

  @doc """
  Loads the analysis consumer configuration.
  """
  @spec load() :: t()
  def load do
    app_config =
      Application.get_env(
        :serviceradar_core,
        ServiceRadar.Observability.AnomalyDetection,
        []
      )

    event_writer_config = EventWriterConfig.load()

    %__MODULE__{
      enabled: enabled?(),
      nats: load_nats_config(app_config, event_writer_config.nats),
      batch_size:
        int_env("ANOMALY_ANALYSIS_BATCH_SIZE", app_config, :batch_size, @default_batch_size),
      batch_timeout:
        int_env(
          "ANOMALY_ANALYSIS_BATCH_TIMEOUT",
          app_config,
          :batch_timeout,
          @default_batch_timeout
        ),
      consumer_name:
        System.get_env("ANOMALY_ANALYSIS_CONSUMER_NAME") ||
          Keyword.get(app_config, :consumer_name, @default_consumer_name),
      producer_name:
        Keyword.get(
          app_config,
          :producer_name,
          ServiceRadar.Observability.AnomalyDetection.Producer
        ),
      processor_concurrency:
        int_env(
          "ANOMALY_ANALYSIS_PROCESSOR_CONCURRENCY",
          app_config,
          :processor_concurrency,
          @default_processor_concurrency
        ),
      enabled_subjects: load_enabled_subjects(app_config),
      streams: Keyword.get(app_config, :streams, default_streams())
    }
  end

  @doc """
  Returns the analysis stream filters.
  """
  @spec default_streams() :: [EventWriterConfig.stream_config()]
  def default_streams do
    [
      analysis_stream("ANALYSIS_METRICS_SYSMON", "metrics", "metrics.sysmon.*", 500, 500),
      analysis_stream("ANALYSIS_METRICS_SNMP", "metrics", "metrics.snmp.>", 500, 500),
      analysis_stream("ANALYSIS_OTEL_METRICS", "events", "otel.metrics.>", 100, 1_000),
      analysis_stream("ANALYSIS_NETFLOW_RAW", "events", "flows.raw.netflow", 50, 500),
      analysis_stream("ANALYSIS_SFLOW_RAW", "events", "flows.raw.sflow", 50, 500),
      analysis_stream("ANALYSIS_ATTRIBUTED_FLOW", "attributed_flow", "flow.attributed.>", 50, 500)
    ]
  end

  @doc """
  Builds the EventWriter-compatible producer config for Broadway.
  """
  @spec to_event_writer_config(t()) :: EventWriterConfig.t()
  def to_event_writer_config(%__MODULE__{} = config) do
    %EventWriterConfig{
      enabled: config.enabled,
      nats: config.nats,
      batch_size: config.batch_size,
      batch_timeout: config.batch_timeout,
      consumer_name: config.consumer_name,
      producer_name: config.producer_name,
      streams: config.streams
    }
  end

  @doc """
  Returns true when `subject` matches one of the enabled subject filters.
  """
  @spec subject_enabled?(t(), String.t()) :: boolean()
  def subject_enabled?(%__MODULE__{} = config, subject) when is_binary(subject) do
    Enum.any?(config.enabled_subjects, &subject_matches?(&1, subject))
  end

  def subject_enabled?(_config, _subject), do: false

  @doc """
  NATS-style subject matcher supporting `*` and terminal `>`.
  """
  @spec subject_matches?(String.t(), String.t()) :: boolean()
  def subject_matches?(filter, subject) when is_binary(filter) and is_binary(subject) do
    match_tokens(String.split(filter, "."), String.split(subject, "."))
  end

  def subject_matches?(_filter, _subject), do: false

  defp analysis_stream(name, stream_name, subject, batch_size, batch_timeout) do
    %{
      name: name,
      stream_name: stream_name,
      subject: subject,
      processor: ServiceRadar.Observability.AnomalyDetection.Pipeline,
      batch_size: batch_size,
      batch_timeout: batch_timeout,
      consumer_deliver_policy: :new,
      consumer_inactive_threshold: @default_inactive_threshold_ns,
      consumer_max_deliver: 3
    }
  end

  defp load_enabled_subjects(app_config) do
    env_subjects = System.get_env("ANOMALY_ANALYSIS_ENABLED_SUBJECTS")

    (parse_subjects(env_subjects) || Keyword.get(app_config, :enabled_subjects) ||
       @default_enabled_subjects)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_subjects(nil), do: nil

  defp parse_subjects(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp load_nats_config(app_config, fallback) do
    case Keyword.fetch(app_config, :nats) do
      {:ok, nats_config} ->
        EventWriterConfig.build_nats_config(nats_config,
          url_env: "ANOMALY_ANALYSIS_NATS_URL",
          creds_file_env: "ANOMALY_ANALYSIS_NATS_CREDS_FILE"
        )

      :error ->
        fallback
    end
  end

  defp int_env(env_name, app_config, key, default) do
    case System.get_env(env_name) do
      nil -> Keyword.get(app_config, key, default)
      value -> parse_int(value, default)
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, _} when number > 0 -> number
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  defp match_tokens([">"], _subject_tokens), do: true
  defp match_tokens([], []), do: true
  defp match_tokens([], _subject_tokens), do: false
  defp match_tokens(_filter_tokens, []), do: false

  defp match_tokens(["*" | filter_rest], [_subject_token | subject_rest]) do
    match_tokens(filter_rest, subject_rest)
  end

  defp match_tokens([filter_token | filter_rest], [filter_token | subject_rest]) do
    match_tokens(filter_rest, subject_rest)
  end

  defp match_tokens(_filter_tokens, _subject_tokens), do: false
end
