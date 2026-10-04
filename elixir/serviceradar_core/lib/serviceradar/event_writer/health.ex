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

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Producer
  alias ServiceRadar.EventWriter.Supervisor
  alias ServiceRadar.FlowAttribution

  @doc """
  Returns the full health status of the EventWriter subsystem.

  Returns a map with:
  - `enabled` - Whether EventWriter is enabled in configuration
  - `running` - Whether the supervisor is running
  - `healthy` - Whether every configured pipeline is running with a ready producer
  - `reason` - `:ok` or `{:error, reason}` (see `check/0`)
  - `pipeline` - Shared pipeline status (running, pid)
  - `producer` - Shared producer status (connection and consumer readiness)
  - `pipelines` - Per-pipeline `%{pipeline: ..., producer: ...}` map
  - `config` - Current configuration summary
  - `flow_attribution` - `ServiceRadar.FlowAttribution.health/0`; reports
    `attribution_disabled: :starrocks_required` without the warehouse
  """
  @spec status() :: map()
  def status do
    config = Config.load()

    pipelines =
      [{Pipeline, config}, {ServiceRadar.EventWriter.FlowPipeline, Config.load_flow()}]
      |> Enum.reject(fn {_name, cfg} -> cfg.streams == [] end)
      |> Map.new(fn {name, _cfg} ->
        {name, %{pipeline: pipeline_status(name), producer: producer_status(name)}}
      end)

    running = supervisor_running?()
    result = health_result(config.enabled, running, pipelines)
    shared = Map.get(pipelines, Pipeline, %{})

    %{
      enabled: config.enabled,
      running: running,
      healthy: result == :ok,
      reason: result,
      pipeline: Map.get(shared, :pipeline),
      producer: Map.get(shared, :producer),
      pipelines: pipelines,
      config: config_summary(config),
      flow_attribution: FlowAttribution.health(),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Performs a quick health check.

  Returns:
  - `:ok` if EventWriter is healthy (or disabled)
  - `{:error, reason}` if there's a problem
  """
  @spec check() :: :ok | {:error, term()}
  def check do
    status().reason
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

  defp health_result(false, _running, _pipelines), do: :ok
  defp health_result(true, false, _pipelines), do: {:error, :supervisor_not_running}
  defp health_result(true, true, pipelines) when map_size(pipelines) == 0,
    do: {:error, :no_streams_configured}

  defp health_result(true, true, pipelines) do
    Enum.reduce_while(pipelines, :ok, fn {name, status}, :ok ->
      cond do
        not status.pipeline.running ->
          {:halt, {:error, {:pipeline_not_running, name}}}

        not status.producer.ready ->
          {:halt, {:error, {:producer_not_ready, name}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp pipeline_status(name) do
    case Process.whereis(name) do
      nil ->
        %{running: false}

      pid ->
        %{running: Process.alive?(pid), pid: inspect(pid)}
    end
  end

  defp producer_status(pipeline) do
    # Broadway wraps the producer module in its own named GenStage process;
    # Producer.start_link/1 and config.producer_name are not used by Broadway.
    case Broadway.producer_names(pipeline) do
      [name] -> Producer.status(name)
      _ -> %{running: false, connected: false, ready: false}
    end
  rescue
    _ -> %{running: false, connected: false, ready: false}
  catch
    :exit, _ -> %{running: false, connected: false, ready: false}
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
