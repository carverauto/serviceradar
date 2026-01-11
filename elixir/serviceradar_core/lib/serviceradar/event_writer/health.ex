defmodule ServiceRadar.EventWriter.Health do
  @moduledoc """
  Health check module for the EventWriter subsystem.

  Provides health status information for monitoring and alerting.

  ## Usage

      # Get full health status
      status = ServiceRadar.EventWriter.Health.status()

      # Quick health check
      :ok = ServiceRadar.EventWriter.Health.check()
  """

  alias ServiceRadar.EventWriter.{Config, Supervisor, Pipeline, Producer}

  @doc """
  Returns the full health status of the EventWriter subsystem.

  Returns a map with:
  - `enabled` - Whether EventWriter is enabled in configuration
  - `running` - Whether the supervisor is running
  - `pipeline` - Pipeline status (connected, message count, etc.)
  - `producer` - Producer status (NATS connection status)
  - `config` - Current configuration summary
  """
  @spec status() :: map()
  def status do
    config = Config.load()

    base_status = %{
      enabled: config.enabled,
      running: supervisor_running?(),
      timestamp: DateTime.utc_now()
    }

    if config.enabled and base_status.running do
      Map.merge(base_status, %{
        pipeline: pipeline_status(),
        producer: producer_status(),
        config: config_summary(config)
      })
    else
      base_status
    end
  end

  @doc """
  Performs a quick health check.

  Returns:
  - `:ok` if EventWriter is healthy (or disabled)
  - `{:error, reason}` if there's a problem
  """
  @spec check() :: :ok | {:error, term()}
  def check do
    config = Config.load()

    cond do
      not config.enabled ->
        :ok

      not supervisor_running?() ->
        {:error, :supervisor_not_running}

      not pipeline_running?() ->
        {:error, :pipeline_not_running}

      true ->
        :ok
    end
  end

  @doc """
  Returns true if the EventWriter is healthy and ready to process messages.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    check() == :ok
  end

  # Private functions

  defp supervisor_running? do
    case Process.whereis(Supervisor) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp pipeline_running? do
    case Process.whereis(Pipeline) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp pipeline_status do
    case Process.whereis(Pipeline) do
      nil ->
        %{running: false}

      pid ->
        # Get Broadway info if available
        try do
          info = Broadway.topology(Pipeline)

          %{
            running: true,
            pid: inspect(pid),
            producers: length(info[:producers] || []),
            processors: length(info[:processors] || []),
            batchers: length(info[:batchers] || [])
          }
        rescue
          _ ->
            %{running: Process.alive?(pid), pid: inspect(pid)}
        end
    end
  end

  defp producer_status do
    case Process.whereis(Producer) do
      nil ->
        %{running: false, connected: false}

      pid ->
        # Try to get producer state
        try do
          state = :sys.get_state(pid, 1000)

          %{
            running: true,
            connected: state.connected,
            pending_messages: length(state.pending_messages),
            demand: state.demand
          }
        rescue
          _ ->
            %{running: Process.alive?(pid), connected: :unknown}
        end
    end
  end

  defp config_summary(config) do
    %{
      nats_host: config.nats.host,
      nats_port: config.nats.port,
      batch_size: config.batch_size,
      batch_timeout: config.batch_timeout,
      consumer_name: config.consumer_name,
      streams: Enum.map(config.streams, & &1.name)
    }
  end
end
