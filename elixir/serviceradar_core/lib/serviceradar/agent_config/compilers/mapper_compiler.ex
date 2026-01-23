defmodule ServiceRadar.AgentConfig.Compilers.MapperCompiler do
  @moduledoc """
  Compiler for mapper discovery configurations.

  Transforms mapper discovery jobs into the JSON schema expected by the mapper
  discovery engine.
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor

  alias ServiceRadar.NetworkDiscovery.{
    MapperJob,
    MapperSeed,
    MapperUnifiController
  }
  alias ServiceRadar.SNMPProfiles.CredentialResolver

  @default_workers 20
  @default_timeout "30s"
  @default_retries 3
  @default_max_active_jobs 100
  @default_result_retention "24h"

  @impl true
  def config_type, do: :mapper

  @impl true
  def source_resources do
    [MapperJob, MapperSeed, MapperUnifiController]
  end

  @impl true
  def compile(partition, agent_id, opts \\ []) do
    actor = opts[:actor] || SystemActor.system(:mapper_compiler)
    device_uid = opts[:device_uid]

    jobs = load_jobs(partition, agent_id, actor)
    unifi_controllers = load_unifi_controllers(jobs)
    credentials = resolve_credentials(device_uid, actor)

    config = %{
      "workers" => @default_workers,
      "timeout" => @default_timeout,
      "retries" => @default_retries,
      "max_active_jobs" => @default_max_active_jobs,
      "result_retention" => @default_result_retention,
      "scheduled_jobs" => Enum.map(jobs, &compile_job(&1, credentials)),
      "unifi_apis" => unifi_controllers
    }

    {:ok, config}
  rescue
    e ->
      Logger.error("MapperCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  defp load_jobs(partition, agent_id, actor) do
    MapperJob
    |> Ash.Query.for_read(:for_agent_partition, %{agent_id: agent_id, partition: partition},
      actor: actor
    )
    |> Ash.Query.load([:seeds, :unifi_controllers])
    |> Ash.read!()
  end

  defp load_unifi_controllers(jobs) do
    jobs
    |> Enum.flat_map(fn job ->
      job.unifi_controllers || []
    end)
    |> Enum.map(&compile_unifi_controller/1)
  end

  defp compile_unifi_controller(controller) do
    %{
      "base_url" => controller.base_url,
      "api_key" => controller.api_key,
      "name" => controller.name,
      "insecure_skip_verify" => controller.insecure_skip_verify
    }
  end

  defp compile_job(job, credentials) do
    seeds = job.seeds || []

    options = job.options || %{}

    options =
      options
      |> Map.put_new("mapper_job_id", to_string(job.id))
      |> Map.put_new("mapper_job_name", job.name)

    %{
      "name" => job.name,
      "interval" => job.interval,
      "enabled" => job.enabled,
      "seeds" => Enum.map(seeds, & &1.seed),
      "type" => Atom.to_string(job.discovery_type),
      "credentials" => credentials,
      "concurrency" => job.concurrency,
      "timeout" => job.timeout,
      "retries" => job.retries,
      "options" => options
    }
  end

  defp resolve_credentials(device_uid, actor) do
    case CredentialResolver.resolve_for_device(device_uid, actor) do
      {:ok, %{credential: nil}} ->
        Logger.warning("MapperCompiler: no SNMP credentials resolved for discovery jobs")
        %{"version" => "v2c"}

      {:ok, %{credential: credential}} ->
        CredentialResolver.to_mapper_credentials(credential)

      {:error, _} ->
        Logger.warning("MapperCompiler: failed to resolve SNMP credentials for discovery jobs")
        %{"version" => "v2c"}
    end
  end
end
