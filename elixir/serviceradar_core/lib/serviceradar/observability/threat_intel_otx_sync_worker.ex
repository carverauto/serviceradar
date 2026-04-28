defmodule ServiceRadar.Observability.ThreatIntelOTXSyncWorker do
  @moduledoc """
  Core-hosted AlienVault OTX sync worker.

  This is the non-edge execution path. Secrets are read from application
  configuration at execution time and are never stored in Oban job args.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 900,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.ThreatIntel.Providers.AlienVaultOTX
  alias ServiceRadar.Observability.ThreatIntelPluginIngestor
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_schedule_seconds 3_600
  @default_provider AlienVaultOTX
  @plugin_id "alienvault-otx-core"

  @doc """
  Schedules one core-hosted OTX sync job if Oban is available.
  """
  @spec ensure_scheduled(keyword()) ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled(opts \\ []) do
    schedule_in = Keyword.get(opts, :schedule_in, @default_schedule_seconds)

    if ObanSupport.available?() do
      %{}
      |> new(schedule_in: max(schedule_in, 1))
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    started_at = System.monotonic_time()
    config = provider_config()
    provider = Keyword.get(config, :provider, @default_provider)
    cursor = Map.get(args || %{}, "cursor", %{})
    provider_config = config |> Keyword.get(:provider_config, %{}) |> Map.new()

    case provider.fetch_page(provider_config, cursor) do
      {:ok, page} ->
        observed_at = DateTime.utc_now()
        payload = payload_for(page)
        status = status_for(config)
        actor = SystemActor.system(:threat_intel_otx_sync_worker)

        ThreatIntelPluginIngestor.ingest_page(page, payload, status,
          actor: actor,
          observed_at: observed_at
        )

        emit_sync_event(:stop, started_at, %{
          provider: page.provider,
          source: page.source,
          collection_id: page.collection_id || "",
          status: "ok",
          objects_count: count(page, "objects"),
          indicators_count: count(page, "indicators"),
          skipped_count: count(page, "skipped")
        })

        Logger.info("AlienVault OTX sync completed",
          source: page.source,
          collection_id: page.collection_id,
          objects_count: count(page, "objects"),
          indicators_count: count(page, "indicators"),
          skipped_count: count(page, "skipped")
        )

        :ok

      {:error, reason} ->
        formatted_reason = format_reason(reason)

        emit_sync_event(:exception, started_at, %{
          provider: "alienvault_otx",
          source: "alienvault_otx",
          collection_id: "otx:pulses:subscribed",
          status: "error",
          error: error_kind(reason)
        })

        Logger.warning("AlienVault OTX sync failed", reason: formatted_reason)
        {:error, reason}
    end
  end

  defp provider_config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end

  defp payload_for(page) do
    %{
      "status" => "ok",
      "summary" =>
        "OTX pulses: #{count(page, "objects")} objects, #{count(page, "indicators")} indicators, #{count(page, "skipped")} skipped",
      "threat_intel" => page.raw
    }
  end

  defp status_for(config) do
    %{
      plugin_id: Keyword.get(config, :plugin_id, @plugin_id),
      service_name: "AlienVault OTX",
      service_type: "threat_intel",
      partition: Keyword.get(config, :partition, "default")
    }
  end

  defp count(page, key) do
    case page.counts do
      %{} = counts -> Map.get(counts, key, 0)
      _ -> 0
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_kind(%module{}), do: inspect(module)
  defp error_kind(_reason), do: "error"

  defp emit_sync_event(kind, started_at, metadata) do
    :telemetry.execute(
      [:serviceradar, :threat_intel, :otx_sync, kind],
      %{duration: System.monotonic_time() - started_at},
      metadata
    )
  end
end
