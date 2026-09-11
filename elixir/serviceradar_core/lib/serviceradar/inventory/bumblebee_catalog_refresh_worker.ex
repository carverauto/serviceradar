defmodule ServiceRadar.Inventory.BumblebeeCatalogRefreshWorker do
  @moduledoc """
  Refreshes Bumblebee exposure catalog snapshots and promotes only validated artifacts.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentArtifacts
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.HTTP.EgressClient
  alias ServiceRadar.Inventory.BumblebeeCatalogArtifact
  alias ServiceRadar.Inventory.BumblebeeCatalogEntry
  alias ServiceRadar.Inventory.BumblebeeCatalogParser
  alias ServiceRadar.Inventory.BumblebeeCatalogRefreshEventWriter
  alias ServiceRadar.Inventory.BumblebeeCatalogSnapshot
  alias ServiceRadar.Inventory.BumblebeeCatalogSource
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_timeout_ms 30_000
  @default_reschedule_seconds 86_400
  @default_failure_reschedule_seconds 3_600
  @default_max_entries 250_000
  @default_max_catalog_bytes 16 * 1024 * 1024

  @spec ensure_scheduled() ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:ok, :disabled} | {:error, term()}
  def ensure_scheduled do
    config = config()

    cond do
      not enabled?(config) ->
        {:ok, :disabled}

      not ObanSupport.available?() ->
        {:error, :oban_unavailable}

      scheduled?() ->
        {:ok, :already_scheduled}

      true ->
        %{} |> new() |> ObanSupport.safe_insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    config = config()

    if enabled?(config) or Map.get(job.args || %{}, "force") == true do
      perform_refresh(config)
    else
      :ok
    end
  end

  defp perform_refresh(config) do
    actor = SystemActor.system(:bumblebee_catalog_refresh)

    sources =
      BumblebeeCatalogSource
      |> Ash.Query.for_read(:enabled, %{}, actor: actor)
      |> Ash.read!(actor: actor)

    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)
    max_entries = Keyword.get(config, :max_entries, @default_max_entries)
    max_catalog_bytes = Keyword.get(config, :max_catalog_bytes, @default_max_catalog_bytes)

    download_source =
      Keyword.get(config, :download_source, fn url, timeout ->
        download_source(url, timeout, max_catalog_bytes)
      end)

    materialize_catalog = Keyword.get(config, :materialize_catalog, &materialize_catalog/3)
    push_config = Keyword.get(config, :push_config, &AgentCommandBus.push_config_for_type/1)
    insert_job = Keyword.get(config, :insert_job, &ObanSupport.safe_insert/1)

    refreshed? =
      sources
      |> Enum.map(
        &refresh_source(
          &1,
          actor,
          timeout_ms,
          max_entries,
          download_source,
          materialize_catalog,
          push_config
        )
      )
      |> Enum.any?(&match?({:ok, _}, &1))

    schedule_next(config, refreshed?, insert_job)
    :ok
  end

  defp refresh_source(
         %BumblebeeCatalogSource{} = source,
         actor,
         timeout_ms,
         max_entries,
         download_source,
         materialize_catalog,
         push_config
       ) do
    Logger.info("Refreshing Bumblebee catalog source", source: source.name)

    with {:ok, parsed, source_body} <-
           load_source_catalog(source, timeout_ms, max_entries, download_source),
         entries = Map.fetch!(parsed, :entries),
         source_revision = source_revision(source, parsed),
         catalog_version = Map.get(parsed, :catalog_version),
         snapshot_ref = snapshot_ref(source, catalog_version, source_revision, source_body),
         {:ok, artifact} <-
           materialize_catalog.(snapshot_ref, entries, %{
             "catalog_version" => catalog_version,
             "source_revision" => source_revision,
             "schema_version" => Map.get(parsed, :schema_version)
           }),
         {:ok, promoted} <-
           persist_snapshot(
             source,
             snapshot_ref,
             parsed,
             artifact,
             source_revision,
             catalog_version,
             actor
           ) do
      _ = publish_agent_catalog(promoted)
      _ = push_config.(:bumblebee)
      _ = BumblebeeCatalogRefreshEventWriter.write_success(source, promoted, actor: actor)
      {:ok, promoted}
    else
      {:error, reason} = error ->
        Logger.warning("Bumblebee catalog refresh failed",
          source: source.name,
          reason: inspect(reason)
        )

        _ = BumblebeeCatalogRefreshEventWriter.write_failure(source, reason, actor: actor)
        error
    end
  end

  defp load_source_catalog(
         %BumblebeeCatalogSource{} = source,
         timeout_ms,
         max_entries,
         download_source
       ) do
    case source |> catalog_urls() |> Enum.reject(&(String.trim(&1) == "")) do
      [] ->
        with {:ok, body} <- download_source.(source.url, timeout_ms),
             {:ok, parsed} <- BumblebeeCatalogParser.parse(body, max_entries: max_entries) do
          {:ok, parsed, body}
        end

      urls ->
        load_bundled_catalog(source, urls, timeout_ms, max_entries, download_source)
    end
  end

  defp load_bundled_catalog(source, urls, timeout_ms, max_entries, download_source) do
    urls
    |> Enum.reduce_while({:ok, []}, fn url, {:ok, acc} ->
      with {:ok, body} <- download_source.(url, timeout_ms),
           {:ok, parsed} <- BumblebeeCatalogParser.parse(body, max_entries: max_entries) do
        {:cont, {:ok, [%{url: url, body: body, parsed: parsed} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:catalog_url_failed, url, reason}}}
      end
    end)
    |> case do
      {:ok, catalogs} ->
        catalogs = Enum.reverse(catalogs)
        entries = merge_catalog_entries(catalogs, max_entries)

        if entries == [] do
          {:error, :empty_catalog}
        else
          {:ok, merged_catalog(source, catalogs, entries), bundled_body(catalogs)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp materialize_catalog(snapshot_ref, entries, metadata) do
    BumblebeeCatalogArtifact.materialize(snapshot_ref, entries, metadata)
  end

  defp publish_agent_catalog(%BumblebeeCatalogSnapshot{} = snapshot) do
    source_id = snapshot.source_id || snapshot.snapshot_ref

    AgentArtifacts.publish_catalog(%{
      source_id: source_id,
      object_key: snapshot.object_key,
      file_name:
        "catalog-#{safe_segment(snapshot.catalog_version || snapshot.snapshot_ref)}.json",
      metadata: %{
        "snapshot_ref" => snapshot.snapshot_ref,
        "catalog_version" => snapshot.catalog_version,
        "source_revision" => snapshot.source_revision
      }
    })
  end

  defp persist_snapshot(
         source,
         snapshot_ref,
         parsed,
         artifact,
         source_revision,
         catalog_version,
         actor
       ) do
    case Repo.transaction(fn ->
           with {:ok, snapshot, snapshot_notifications} <-
                  create_snapshot(
                    source,
                    snapshot_ref,
                    parsed,
                    artifact,
                    source_revision,
                    catalog_version,
                    actor
                  ),
                :ok <- create_entries(snapshot, Map.fetch!(parsed, :entries), actor),
                {:ok, promoted, promote_notifications} <-
                  promote_snapshot(snapshot, parsed, artifact, actor) do
             {promoted, snapshot_notifications ++ promote_notifications}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {promoted, notifications}} ->
        _ = Ash.Notifier.notify(notifications)
        {:ok, promoted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_catalog_entries(catalogs, max_entries) do
    catalogs
    |> Enum.flat_map(fn %{parsed: parsed} -> Map.fetch!(parsed, :entries) end)
    |> Enum.uniq_by(& &1.catalog_id)
    |> Enum.take(max_entries)
  end

  defp merged_catalog(source, catalogs, entries) do
    metadata = source.metadata || %{}

    parsed_catalog_versions =
      catalogs |> Enum.map(& &1.parsed[:catalog_version]) |> Enum.reject(&is_nil/1)

    parsed_schema_versions =
      catalogs |> Enum.map(& &1.parsed[:schema_version]) |> Enum.reject(&is_nil/1)

    catalog_urls = Enum.map(catalogs, & &1.url)

    %{
      entries: entries,
      catalog_version:
        fetch_map_value(metadata, "catalog_version") || common_value(parsed_catalog_versions) ||
          bundled_catalog_version(source),
      schema_version: common_value(parsed_schema_versions) || "mixed",
      metadata:
        compact_map(%{
          "source_url" => source.url,
          "catalog_urls" => catalog_urls,
          "catalog_count" => length(catalogs),
          "source_revision" => fetch_map_value(metadata, "source_revision"),
          "upstream_repo" => fetch_map_value(metadata, "upstream_repo"),
          "upstream_tag" => fetch_map_value(metadata, "upstream_tag"),
          "upstream_commit" => fetch_map_value(metadata, "upstream_commit")
        }),
      validation_result: %{
        "status" => "valid",
        "entry_count" => length(entries),
        "catalog_count" => length(catalogs),
        "source_urls" => catalog_urls
      }
    }
  end

  defp bundled_body(catalogs) do
    catalogs
    |> Enum.map(fn %{url: url, body: body} -> [url, "\n", body] end)
    |> IO.iodata_to_binary()
  end

  defp create_snapshot(
         source,
         snapshot_ref,
         parsed,
         artifact,
         source_revision,
         catalog_version,
         actor
       ) do
    attrs = %{
      source_id: source.id,
      snapshot_ref: snapshot_ref,
      source_revision: source_revision,
      catalog_version: catalog_version,
      schema_version: Map.get(parsed, :schema_version),
      status: "candidate",
      entry_count: length(Map.fetch!(parsed, :entries)),
      content_sha256: Map.fetch!(artifact, "content_sha256"),
      object_key: Map.fetch!(artifact, "object_key"),
      object_size_bytes: Map.fetch!(artifact, "object_size_bytes"),
      validation_result: Map.fetch!(parsed, :validation_result),
      artifact_metadata: artifact,
      metadata: Map.get(parsed, :metadata, %{})
    }

    BumblebeeCatalogSnapshot
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(actor: actor, return_notifications?: true)
    |> normalize_ash_result_with_notifications()
  end

  defp create_entries(snapshot, entries, actor) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      attrs = Map.put(entry, :snapshot_id, snapshot.id)

      case BumblebeeCatalogEntry
           |> Ash.Changeset.for_create(:create, attrs, actor: actor)
           |> Ash.create(actor: actor, return_notifications?: true) do
        {:ok, _entry, _notifications} -> {:cont, :ok}
        {:ok, _entry} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp promote_snapshot(snapshot, parsed, artifact, actor) do
    attrs = %{
      entry_count: length(Map.fetch!(parsed, :entries)),
      content_sha256: Map.fetch!(artifact, "content_sha256"),
      object_key: Map.fetch!(artifact, "object_key"),
      object_size_bytes: Map.fetch!(artifact, "object_size_bytes"),
      validation_result: Map.fetch!(parsed, :validation_result),
      artifact_metadata: artifact
    }

    snapshot
    |> Ash.Changeset.for_update(:promote, attrs, actor: actor)
    |> Ash.update(actor: actor, return_notifications?: true)
    |> normalize_ash_result_with_notifications()
  end

  defp normalize_ash_result_with_notifications({:ok, record, %{notifications: notifications}}) do
    {:ok, record, notifications}
  end

  defp normalize_ash_result_with_notifications({:ok, record, notifications})
       when is_list(notifications) do
    {:ok, record, notifications}
  end

  defp normalize_ash_result_with_notifications({:ok, record}) do
    {:ok, record, []}
  end

  defp normalize_ash_result_with_notifications({:error, reason}) do
    {:error, reason}
  end

  # EgressClient, not the shared Finch pool: the pool cannot tunnel through
  # SERVICERADAR_EGRESS_PROXY. :max_bytes stops the transfer once it passes the
  # cap rather than after the whole body has arrived.
  defp download_source(url, timeout_ms, max_catalog_bytes) do
    opts = [
      headers: [{"user-agent", "serviceradar"}],
      receive_timeout: timeout_ms,
      max_bytes: max_catalog_bytes
    ]

    with :ok <- validate_url(url),
         {:ok, %Req.Response{status: 200, body: body}} <- EgressClient.fetch_body(url, opts) do
      {:ok, body}
    else
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, :response_too_large} -> {:error, {:catalog_too_large, max_catalog_bytes}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _ ->
        {:error, :invalid_catalog_url}
    end
  end

  defp validate_url(_), do: {:error, :invalid_catalog_url}

  defp catalog_urls(%BumblebeeCatalogSource{metadata: metadata}) when is_map(metadata) do
    metadata
    |> fetch_map_value("catalog_urls", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp catalog_urls(_source), do: []

  defp source_revision(%BumblebeeCatalogSource{pinned_revision: revision}, parsed) do
    cond do
      present?(revision) ->
        String.trim(revision)

      present?(Map.get(parsed, :metadata, %{})["source_revision"]) ->
        parsed.metadata["source_revision"]

      true ->
        nil
    end
  end

  defp snapshot_ref(source, catalog_version, source_revision, body) do
    digest = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    timestamp = System.system_time(:nanosecond)

    Enum.join(
      [
        "bumblebee",
        safe_segment(source.name),
        safe_segment(catalog_version || source_revision || "snapshot"),
        digest,
        Integer.to_string(timestamp)
      ],
      ":"
    )
  end

  defp schedule_next(config, true, insert_job) do
    __MODULE__
    |> SelfScheduling.successor_changeset(
      %{"scheduled_at" => DateTime.to_iso8601(DateTime.utc_now()), "last_result" => "success"},
      max(Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds), 3_600)
    )
    |> insert_next_job(insert_job)
  end

  defp schedule_next(config, false, insert_job) do
    __MODULE__
    |> SelfScheduling.successor_changeset(
      %{"scheduled_at" => DateTime.to_iso8601(DateTime.utc_now()), "last_result" => "failure"},
      max(
        Keyword.get(config, :failure_reschedule_seconds, @default_failure_reschedule_seconds),
        900
      )
    )
    |> insert_next_job(insert_job)
  end

  defp insert_next_job(changeset, insert_job) do
    case insert_job.(changeset) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule next Bumblebee catalog refresh",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp scheduled? do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp enabled?(config) do
    Keyword.get(config, :enabled, false) ||
      System.get_env("BUMBLEBEE_CATALOG_REFRESH_ENABLED", "false") in ~w(true 1 yes on)
  end

  defp config, do: Application.get_env(:serviceradar_core, __MODULE__, [])

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp bundled_catalog_version(%BumblebeeCatalogSource{pinned_revision: revision, name: name}) do
    if present?(revision), do: revision, else: name
  end

  defp common_value([]), do: nil

  defp common_value([first | rest]) do
    if Enum.all?(rest, &(&1 == first)), do: first, else: "mixed"
  end

  defp fetch_map_value(map, key, default \\ nil)

  defp fetch_map_value(map, key, default) when is_map(map) do
    atom_key = key_atom(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> default
    end
  end

  defp fetch_map_value(_map, _key, default), do: default

  defp key_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp key_atom(key) when is_atom(key), do: key
  defp key_atom(_key), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      segment -> segment
    end
  end
end
