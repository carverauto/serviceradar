defmodule ServiceRadar.Inventory.DeviceRiskAssessmentWorker do
  @moduledoc """
  Periodically evaluates device risk and writes composite scores.

  Matching and feed download are separate. Each pass re-scores endpoint
  inventory findings from KEV, CVSS, and CWE, then raises any device where an
  AlienVault IOC source has just connected to a vulnerable local process to
  maximum risk and emits a detection finding plus alert.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Inventory.DeviceRiskIocExposure
  alias ServiceRadar.Inventory.EndpointInventoryVulnerabilityRisk
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_reschedule_seconds 900

  @impl Oban.Worker
  def timeout(_job), do: 840_000

  @spec ensure_scheduled(keyword()) ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled(opts \\ []) do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        schedule_in = Keyword.get(opts, :schedule_in, 0)
        %{} |> new(schedule_in: schedule_in) |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    reschedule_seconds =
      bounded_positive_integer(
        args["reschedule_seconds"],
        Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)
      )

    case run_assessment() do
      {:ok, stats} ->
        Logger.info("Device risk assessment completed", stats: stats)
        schedule_next(reschedule_seconds)
        :ok

      {:error, reason} ->
        Logger.warning("Device risk assessment failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp run_assessment do
    assessor =
      :serviceradar_core
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:assess, &default_assess/1)

    case assessor.([]) do
      {:ok, result} -> {:ok, normalize_stats(result)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_assessment_result, other}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp default_assess(opts) do
    with {:ok, vuln} <- EndpointInventoryVulnerabilityRisk.recompute_all(opts),
         {:ok, ioc} <- DeviceRiskIocExposure.evaluate(opts) do
      {:ok,
       %{
         devices: vuln_devices(vuln),
         ioc_devices: Map.get(ioc, :devices, 0),
         ioc_hits: Map.get(ioc, :hits, 0),
         ioc_alerts: Map.get(ioc, :alerts, 0)
       }}
    end
  end

  defp vuln_devices(count) when is_integer(count), do: count
  defp vuln_devices(%{devices: count}), do: count
  defp vuln_devices(_other), do: 0

  defp normalize_stats(count) when is_integer(count), do: %{devices: count}
  defp normalize_stats(%{} = stats), do: stats
  defp normalize_stats(other), do: %{result: other}

  defp schedule_next(reschedule_seconds) do
    case ObanSupport.safe_insert(
           SelfScheduling.successor_changeset(__MODULE__, %{}, reschedule_seconds)
         ) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.debug("Device risk assessment reschedule deferred",
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp bounded_positive_integer(value, default) do
    value
    |> parse_integer(default)
    |> min(100_000)
    |> max(1)
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default
end
