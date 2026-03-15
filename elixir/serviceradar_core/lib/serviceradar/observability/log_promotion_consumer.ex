defmodule ServiceRadar.Observability.LogPromotionConsumer do
  @moduledoc """
  Subscribes to processed log subjects and promotes matching logs to events.
  """

  use Jetstream.PullConsumer

  alias Jetstream.API.Consumer
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetstreamConsumer
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.Observability.LogPromotionParser

  require Logger

  @default_stream "events"
  @default_consumer "log-promotion"
  @default_filter "logs.*.processed"
  @ack_wait_ns 30_000_000_000
  @max_ack_pending 1_000
  @max_deliver 3
  @ensure_retry_ms 2_000
  @default_connect_retry_ms 5_000
  @default_connect_retries 120

  def start_link(opts \\ []) do
    Jetstream.PullConsumer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:serviceradar_core, :log_promotion_consumer_enabled) do
      nil ->
        System.get_env("LOG_PROMOTION_CONSUMER_ENABLED", "true") in ~w(true 1 yes)

      value ->
        value
    end
  end

  @spec status() :: map()
  def status do
    config = load_config([])
    running = is_pid(Process.whereis(__MODULE__))
    enabled = enabled?()

    connected =
      enabled and running and Connection.connected?() and
        consumer_available?(config)

    %{
      enabled: enabled,
      running: running,
      connected: connected,
      last_error: if(connected, do: nil, else: :not_connected)
    }
  end

  @impl true
  def init(opts) do
    if migration_only?() do
      Logger.info("Log promotion consumer disabled in migration-only mode")
      :ignore
    else
      config = load_config(opts)

      maybe_create_consumer(config)
      ensure_consumer_async(config)

      {:ok,
       %{
         processed_count: 0,
         promoted_count: 0,
         last_error: nil,
         config: config
       },
       connection_name: config.connection_name,
       stream_name: config.stream_name,
       consumer_name: config.consumer_name,
       domain: config.domain,
       connection_retry_timeout: config.connection_retry_timeout,
       connection_retries: config.connection_retries}
    end
  end

  @impl true
  def handle_message(%{body: body, topic: subject}, state) do
    received_at = DateTime.utc_now()
    logs = LogPromotionParser.parse_payload(body, subject, received_at)

    case logs do
      [] ->
        {:ack, %{state | processed_count: state.processed_count + 1}}

      _ ->
        {:ok, count} = LogPromotion.promote(logs)

        :telemetry.execute(
          [:serviceradar, :log_promotion, :consumer, :processed],
          %{logs: length(logs), events: count},
          %{subject: subject}
        )

        {:ack,
         %{
           state
           | processed_count: state.processed_count + length(logs),
             promoted_count: state.promoted_count + count,
             last_error: nil
         }}
    end
  rescue
    error ->
      Logger.error("Log promotion consumer crashed", error: inspect(error), subject: subject)
      {:nack, %{state | last_error: error}}
  end

  defp load_config(opts) do
    stream_name = Keyword.get(opts, :stream_name, System.get_env("LOG_PROMOTION_CONSUMER_STREAM"))

    consumer_name =
      Keyword.get(opts, :consumer_name, System.get_env("LOG_PROMOTION_CONSUMER_NAME"))

    filter_subject =
      Keyword.get(opts, :filter_subject, System.get_env("LOG_PROMOTION_CONSUMER_FILTER"))

    deliver_policy =
      Keyword.get(opts, :deliver_policy, System.get_env("LOG_PROMOTION_CONSUMER_DELIVER_POLICY"))

    domain = Keyword.get(opts, :domain, System.get_env("LOG_PROMOTION_CONSUMER_DOMAIN"))

    %{
      connection_name: Connection.connection_name(),
      stream_name: stream_name || @default_stream,
      consumer_name: consumer_name || @default_consumer,
      filter_subject: filter_subject || @default_filter,
      deliver_policy: normalize_deliver_policy(deliver_policy),
      domain: domain,
      connection_retry_timeout: load_connect_retry_timeout(opts),
      connection_retries: load_connect_retries(opts)
    }
  end

  defp normalize_deliver_policy(policy) when is_atom(policy), do: policy

  defp normalize_deliver_policy(policy) when is_binary(policy) do
    case String.downcase(String.trim(policy)) do
      "new" -> :new
      "last" -> :last
      "last_per_subject" -> :last_per_subject
      "by_start_time" -> :by_start_time
      "by_start_sequence" -> :by_start_sequence
      _ -> :all
    end
  end

  defp normalize_deliver_policy(_policy), do: :all

  defp load_connect_retry_timeout(opts) do
    from_opts = Keyword.get(opts, :connection_retry_timeout)
    from_env = System.get_env("LOG_PROMOTION_CONSUMER_RETRY_TIMEOUT_MS")
    parse_int(from_opts || from_env, @default_connect_retry_ms)
  end

  defp load_connect_retries(opts) do
    from_opts = Keyword.get(opts, :connection_retries)
    from_env = System.get_env("LOG_PROMOTION_CONSUMER_RETRY_COUNT")
    parse_int(from_opts || from_env, @default_connect_retries)
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, _} -> number
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp ensure_consumer_async(config) do
    Task.start(fn -> ensure_consumer(config) end)
  end

  defp ensure_consumer(config, attempt \\ 0) do
    if consumer_available?(config) do
      :ok
    else
      case create_consumer(config) do
        :ok ->
          Logger.info("Log promotion JetStream consumer ready",
            stream: config.stream_name,
            consumer: config.consumer_name,
            filter_subject: config.filter_subject
          )

        {:error, reason} ->
          Logger.warning("Failed to create log promotion consumer",
            reason: inspect(reason),
            attempt: attempt + 1
          )

          Process.sleep(@ensure_retry_ms)
          ensure_consumer(config, attempt + 1)
      end
    end
  end

  defp maybe_create_consumer(config) do
    if Connection.connected?() do
      _ = create_consumer(config)
    end
  end

  defp consumer_available?(config) do
    if Connection.connected?() do
      try do
        case Consumer.info(
               config.connection_name,
               config.stream_name,
               config.consumer_name,
               config.domain
             ) do
          {:ok, _info} -> true
          _ -> false
        end
      catch
        :exit, _ -> false
      end
    else
      false
    end
  end

  defp create_consumer(config) do
    if Connection.connected?() do
      create_consumer_when_connected(config)
    else
      {:error, :not_connected}
    end
  end

  defp create_consumer_when_connected(config) do
    case JetstreamConsumer.ensure_durable(config.connection_name,
           stream_name: config.stream_name,
           consumer_name: config.consumer_name,
           filter_subject: config.filter_subject,
           description: "Promote processed logs into OCSF events",
           ack_policy: :explicit,
           ack_wait: @ack_wait_ns,
           deliver_policy: config.deliver_policy,
           max_ack_pending: @max_ack_pending,
           max_deliver: @max_deliver,
           replay_policy: :instant,
           domain: config.domain
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp migration_only? do
    System.get_env("SERVICERADAR_MIGRATION_ONLY", "false") in ~w(true 1 yes)
  end
end
