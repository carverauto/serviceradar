defmodule ServiceRadar.Observability.ThreatIntelOTXSyncWorker do
  @moduledoc """
  Core-hosted AlienVault OTX sync worker.

  This is the non-edge execution path. Secrets are resolved through persisted credential-broker grants
  at execution time and are never stored in Oban job args.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 900,
      fields: [:worker, :args],
      states: :incomplete
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.ThreatIntel.Page
  alias ServiceRadar.Observability.ThreatIntel.Providers.AlienVaultOTX
  alias ServiceRadar.Observability.ThreatIntelPluginIngestor
  alias ServiceRadar.Observability.ThreatIntelSyncStatus
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_schedule_seconds 3_600
  @freshness_floor_seconds 86_400
  @default_provider AlienVaultOTX
  @plugin_id "alienvault-otx-core"
  @collection_id "otx:pulses:subscribed"
  @completed_walk_overlap_seconds 2 * 24 * 60 * 60
  # Continuation and root jobs share one chain. This key is never written, so
  # every incomplete job counts and a second chain can be cancelled.
  @chain_one_off_key "manual"

  @doc """
  Schedules one core-hosted OTX sync when that path is enabled.

  An incomplete job, including a page continuation, means the chain is alive.
  Extra pending jobs are cancelled down to the earliest one. `force: true`
  queues a run even when the saved execution mode is the edge plugin; the
  NetFlow security scheduler calls this without force.
  """
  @spec ensure_scheduled(keyword()) ::
          {:ok, Oban.Job.t()}
          | {:ok, :already_scheduled}
          | {:ok, :disabled}
          | {:error, term()}
  def ensure_scheduled(opts \\ []) do
    cond do
      not ObanSupport.available?() ->
        {:error, :oban_unavailable}

      not Keyword.get(opts, :force, false) and not core_sync_enabled?() ->
        {:ok, :disabled}

      true ->
        schedule_chain(opts)
    end
  end

  @doc """
  A feed is stale when it has no successful sync, or the last success is older
  than twice the longer of the configured interval and one day.
  """
  @spec stale?(map(), DateTime.t(), pos_integer()) :: boolean()
  def stale?(status, now, interval \\ @freshness_floor_seconds)

  def stale?(%{last_success_at: %DateTime{} = success}, %DateTime{} = now, interval) do
    DateTime.diff(now, success, :second) > freshness_budget_seconds(interval)
  end

  def stale?(%{}, %DateTime{}, _interval), do: true
  def stale?(_status, _now, _interval), do: false

  @doc false
  @spec freshness_budget_seconds(term()) :: pos_integer()
  def freshness_budget_seconds(interval) do
    max(positive_int(interval, @freshness_floor_seconds), @freshness_floor_seconds) * 2
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    started_at = System.monotonic_time()
    config = provider_config()
    provider = Keyword.get(config, :provider, @default_provider)
    actor = SystemActor.system(:threat_intel_otx_sync_worker)
    cursor = requested_cursor(args) || latest_completed_cursor(actor)
    provider_config = config |> Keyword.get(:provider_config, %{}) |> Map.new()

    case provider.fetch_page(provider_config, cursor) do
      {:ok, page} ->
        observed_at = DateTime.utc_now()
        page = stamp_durable_cursor(page, observed_at)
        payload = payload_for(page)
        status = status_for(config)

        with :ok <-
               ThreatIntelPluginIngestor.ingest_page(page, payload, status,
                 actor: actor,
                 observed_at: observed_at
               ),
             :ok <- maybe_enqueue_continuation(page.cursor) do
          emit_sync_event(:stop, started_at, %{
            provider: page.provider,
            source: page.source,
            collection_id: page.collection_id || "",
            status: "ok",
            objects_count: count(page, "objects"),
            indicators_count: count(page, "indicators"),
            skipped_count: count(page, "skipped")
          })

          Logger.info("AlienVault OTX sync page completed",
            source: page.source,
            collection_id: page.collection_id,
            objects_count: count(page, "objects"),
            indicators_count: count(page, "indicators"),
            skipped_count: count(page, "skipped"),
            next_page: Map.get(continuation_cursor(page.cursor) || %{}, "page")
          )

          :ok
        else
          {:error, reason} -> sync_error(started_at, reason)
        end

      {:error, reason} ->
        sync_error(started_at, reason)
    end
  end

  @doc false
  @spec continuation_cursor(term()) :: map() | nil
  def continuation_cursor(cursor) when is_map(cursor) do
    current_page = positive_int(Map.get(cursor, "page") || Map.get(cursor, :page), 1)

    next_page =
      positive_int(
        Map.get(cursor, "next_page") || Map.get(cursor, :next_page),
        page_from_url(Map.get(cursor, "next") || Map.get(cursor, :next))
      )

    if is_integer(next_page) and next_page > current_page do
      %{
        "page" => next_page,
        "next" => Map.get(cursor, "next") || Map.get(cursor, :next),
        "modified_since" => Map.get(cursor, "modified_since") || Map.get(cursor, :modified_since)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  def continuation_cursor(_cursor), do: nil

  @doc false
  @spec stamp_durable_cursor(Page.t(), DateTime.t()) ::
          Page.t()
  def stamp_durable_cursor(%Page{} = page, %DateTime{} = now) do
    cursor = page.cursor || %{}

    cursor =
      if blank?(Map.get(cursor, "next") || Map.get(cursor, :next)) do
        cursor
        |> Map.put("page", 1)
        |> Map.put("complete", "true")
        |> Map.put(
          "modified_since",
          now
          |> DateTime.add(-@completed_walk_overlap_seconds, :second)
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()
        )
      else
        Map.put(cursor, "complete", "false")
      end

    %{page | cursor: cursor, raw: Map.put(page.raw || %{}, "cursor", cursor)}
  end

  defp maybe_enqueue_continuation(cursor) do
    case continuation_cursor(cursor) do
      nil ->
        :ok

      next_cursor ->
        %{"cursor" => next_cursor}
        |> new(schedule_in: 1)
        |> ObanSupport.safe_insert()
        |> case do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, {:continuation_enqueue_failed, reason}}
        end
    end
  end

  defp requested_cursor(%{"cursor" => cursor}) when is_map(cursor) and map_size(cursor) > 0,
    do: cursor

  defp requested_cursor(_args), do: nil

  defp latest_completed_cursor(actor) do
    ThreatIntelSyncStatus
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == "alienvault_otx" and plugin_id == ^@plugin_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, %ThreatIntelSyncStatus{cursor: cursor}} when is_map(cursor) ->
        if complete_cursor?(cursor) do
          cursor
          |> Map.take(["modified_since"])
          |> Map.put("page", 1)
        else
          %{}
        end

      _ ->
        %{}
    end
  rescue
    error ->
      Logger.debug("AlienVault OTX completion cursor unavailable", reason: inspect(error))
      %{}
  end

  defp complete_cursor?(cursor) do
    complete = Map.get(cursor, "complete") || Map.get(cursor, :complete)
    modified_since = Map.get(cursor, "modified_since") || Map.get(cursor, :modified_since)
    complete in [true, "true"] and is_binary(modified_since) and modified_since != ""
  end

  defp blank?(value), do: value in [nil, ""]

  defp sync_error(started_at, reason) do
    emit_sync_event(:exception, started_at, %{
      provider: "alienvault_otx",
      source: "alienvault_otx",
      collection_id: @collection_id,
      status: "error",
      error: error_kind(reason)
    })

    Logger.warning("AlienVault OTX sync failed", reason: error_kind(reason))
    record_failure(reason)
    {:error, reason}
  end

  defp schedule_chain(opts) do
    case ObanSupport.incomplete_chain_job_count(__MODULE__, @chain_one_off_key) do
      0 ->
        schedule_in = Keyword.get(opts, :schedule_in, next_delay_seconds())

        %{}
        |> new(schedule_in: max(schedule_in, 1))
        |> ObanSupport.safe_insert()

      1 ->
        {:ok, :already_scheduled}

      _duplicates ->
        ObanSupport.cancel_duplicate_pending_jobs(__MODULE__, @chain_one_off_key)
        {:ok, :already_scheduled}
    end
  end

  defp next_delay_seconds do
    case read_settings() do
      %NetflowSettings{otx_sync_interval_seconds: seconds} when is_integer(seconds) ->
        max(seconds, @default_schedule_seconds)

      _ ->
        @default_schedule_seconds
    end
  end

  defp core_sync_enabled? do
    case read_settings() do
      %NetflowSettings{otx_enabled: true, otx_execution_mode: "core_worker",
        otx_credential_secret_id: id} when is_binary(id) -> true
      _ -> false
    end
  end

  defp record_failure(reason) do
    actor = SystemActor.system(:threat_intel_otx_sync_worker)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    existing = latest_status(actor)

    attrs = %{
      provider: "alienvault_otx",
      source: "alienvault_otx",
      collection_id: @collection_id,
      agent_id: "",
      gateway_id: "",
      plugin_id: @plugin_id,
      execution_mode: "core_worker",
      last_status: "error",
      last_message: "AlienVault OTX sync failed",
      last_error: error_kind(reason),
      last_attempt_at: now,
      last_failure_at: now,
      last_success_at: existing && existing.last_success_at,
      objects_count: (existing && existing.objects_count) || 0,
      indicators_count: (existing && existing.indicators_count) || 0,
      skipped_count: (existing && existing.skipped_count) || 0,
      total_count: (existing && existing.total_count) || 0,
      cursor: (existing && existing.cursor) || %{},
      metadata: (existing && existing.metadata) || %{}
    }

    case Ash.create(ThreatIntelSyncStatus, attrs,
           action: :upsert,
           actor: actor,
           domain: ServiceRadar.Observability
         ) do
      {:ok, _status} ->
        :ok

      {:error, write_error} ->
        Logger.warning("AlienVault OTX failure status was not recorded",
          reason: error_kind(write_error)
        )
    end
  rescue
    error ->
      Logger.warning("AlienVault OTX failure status was not recorded", reason: error_kind(error))
  end

  defp latest_status(actor) do
    ThreatIntelSyncStatus
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      source == "alienvault_otx" and plugin_id == ^@plugin_id and collection_id == ^@collection_id and
        agent_id == "" and gateway_id == ""
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, %ThreatIntelSyncStatus{} = status} -> status
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp page_from_url(url) when is_binary(url) do
    with %URI{query: query} when is_binary(query) <- URI.parse(url),
         page when is_binary(page) <- URI.decode_query(query)["page"] do
      positive_int(page, nil)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp page_from_url(_url), do: nil

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp positive_int(_value, fallback), do: fallback

  defp provider_config do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    # Only the credential broker supplies authentication, even when tuning is configured.
    tuning = config |> Keyword.get(:provider_config, %{}) |> Map.new()
      |> Map.drop(["api_key", :api_key, "base_url", :base_url])
    Keyword.put(config, :provider_config, Map.merge(tuning, settings_provider_config()))
  end

  defp settings_provider_config do
    case read_settings() do
      %NetflowSettings{otx_enabled: true, otx_execution_mode: "core_worker"} = settings ->
        settings_config(settings)

      _ ->
        %{}
    end
  end

  defp settings_config(%NetflowSettings{} = settings) do
    %{
      "api_key" => otx_token(settings.otx_credential_secret_id),
      "base_url" => "https://otx.alienvault.com",
      "modified_since" => settings.otx_modified_since,
      "limit" => settings.otx_page_size,
      "timeout_ms" => settings.otx_timeout_ms
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp read_settings do
    actor = SystemActor.system(:threat_intel_otx_sync_worker)

    case NetflowSettings.get_settings(actor: actor) do
      {:ok, %NetflowSettings{} = settings} -> settings
      _ -> nil
    end
  rescue
    error ->
      Logger.debug("AlienVault OTX settings unavailable", reason: error_kind(error))
      nil
  end

  defp otx_token(secret_id) do
    case ServiceRadar.Inventory.AdvisoryFeeds.CredentialResolver.resolve_otx(secret_id) do
      {:ok, token} -> token
      {:error, _reason} -> nil
    end
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
