defmodule ServiceRadar.PrefixTags.NetboxImportWorker do
  @moduledoc """
  Oban maintenance worker that imports NetBox IPAM prefixes into a
  `prefix_tag_snapshots` / `prefix_tags` snapshot and promotes it atomically.

  Credentials come from an enabled Integrations source of type `:netbox`
  (`url` / `token` / `verify_ssl`). Pagination follows NetBox `next` links to
  exhaustion; the imported row count is validated against NetBox's `count`.
  Partial pulls are never promoted.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.Types.Cidr

  require Logger

  @source_name "netbox"
  @default_page_limit 200
  @default_timeout_ms 30_000
  @default_reschedule_seconds 15 * 60
  @default_failure_reschedule_seconds 30 * 60
  @default_max_tags_per_prefix 32
  @successor_unique [period: :infinity, states: [:available, :scheduled, :retryable]]
  @insert_chunk_size 250
  @db_timeout_ms 120_000

  @default_dimension_namespaces %{
    site: true,
    role: true,
    tenant: true,
    status: true,
    vrf: true,
    tags: true
  }

  @doc "Schedules the import job if not already scheduled."
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
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
  def perform(_job) do
    if scheduler_node?() do
      do_perform()
    else
      Logger.debug("Skipping NetBox prefix-tag import on non-scheduler node", node: Node.self())
      :ok
    end
  end

  defp do_perform do
    config = config()
    started = System.monotonic_time(:microsecond)

    with {:ok, creds} <- resolve_credentials(config),
         {:ok, rows, meta} <- fetch_all_prefixes(creds, config) do
      case promote_snapshot(creds.url, rows, meta) do
        :ok ->
          duration_us = System.monotonic_time(:microsecond) - started
          emit_import_telemetry(:ok, length(rows), duration_us)
          _ = Loader.broadcast_invalidation(%{source: @source_name, record_count: length(rows)})
          Logger.info("NetBox prefix-tag snapshot promoted", rows: length(rows))
          schedule_next(Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds))

        {:error, reason} ->
          duration_us = System.monotonic_time(:microsecond) - started
          emit_import_telemetry(:error, 0, duration_us)

          Logger.warning("NetBox prefix-tag promotion failed", reason: inspect(reason))

          schedule_next(
            Keyword.get(config, :failure_reschedule_seconds, @default_failure_reschedule_seconds)
          )
      end
    else
      {:error, :no_credentials} ->
        Logger.info("NetBox prefix-tag import skipped: no credentials configured")
        schedule_next(Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds))

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - started
        emit_import_telemetry(:error, 0, duration_us)

        Logger.warning("NetBox prefix-tag import failed", reason: inspect(reason))

        schedule_next(
          Keyword.get(config, :failure_reschedule_seconds, @default_failure_reschedule_seconds)
        )
    end
  end

  # -- credentials ------------------------------------------------------------

  @doc false
  def resolve_credentials(config \\ config()) do
    case Keyword.get(config, :credentials) do
      %{} = injected ->
        normalize_credentials(injected)

      _ ->
        load_integration_credentials()
    end
  end

  defp load_integration_credentials do
    actor = SystemActor.system(:prefix_tags_netbox_import)

    IntegrationSource
    |> Ash.Query.for_read(:by_type, %{source_type: :netbox})
    |> Ash.Query.filter(enabled == true)
    |> Ash.Query.limit(1)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, %Ash.Page.Keyset{results: [source | _]}} ->
        credentials_from_source(source, actor)

      {:ok, [source | _]} ->
        credentials_from_source(source, actor)

      {:ok, _} ->
        {:error, :no_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp credentials_from_source(source, actor) do
    case Ash.load(source, [:credentials_encrypted, :credentials], actor: actor) do
      {:ok, loaded} ->
        creds = Map.get(loaded, :credentials) || %{}
        url = cred_fetch(creds, ["url", :url]) || loaded.endpoint
        token = cred_fetch(creds, ["token", :token])
        verify_ssl = cred_fetch(creds, ["verify_ssl", :verify_ssl], true)

        normalize_credentials(%{
          "url" => url,
          "token" => token,
          "verify_ssl" => verify_ssl
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_credentials(map) when is_map(map) do
    url = cred_fetch(map, ["url", :url])
    token = cred_fetch(map, ["token", :token])
    verify_ssl = cred_fetch(map, ["verify_ssl", :verify_ssl], true)

    cond do
      not is_binary(url) or String.trim(url) == "" ->
        {:error, :no_credentials}

      not is_binary(token) or String.trim(token) == "" ->
        {:error, :no_credentials}

      true ->
        {:ok,
         %{
           url: String.trim_trailing(String.trim(url), "/"),
           token: String.trim(token),
           verify_ssl: verify_ssl != false
         }}
    end
  end

  # Prefer Map.fetch so boolean false is preserved (unlike || / find_value).
  defp cred_fetch(map, keys, default \\ nil) do
    Enum.reduce_while(keys, :__miss__, fn key, _acc ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, :__miss__}
      end
    end)
    |> case do
      :__miss__ -> default
      value -> value
    end
  end

  # -- fetch + pagination -----------------------------------------------------

  @doc false
  @spec fetch_all_prefixes(map(), keyword()) ::
          {:ok, [map()], map()} | {:error, term()}
  def fetch_all_prefixes(creds, config \\ []) do
    http_get = Keyword.get(config, :http_get, &default_http_get/2)
    page_limit = Keyword.get(config, :page_limit, @default_page_limit)
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)
    namespaces = Keyword.get(config, :dimension_namespaces, @default_dimension_namespaces)
    max_tags = Keyword.get(config, :max_tags_per_prefix, @default_max_tags_per_prefix)

    prefixes_url = "#{creds.url}/api/ipam/prefixes/?limit=#{page_limit}"
    aggregates_url = "#{creds.url}/api/ipam/aggregates/?limit=#{page_limit}"

    with {:ok, prefix_results, prefix_count} <-
           paginate(prefixes_url, creds, http_get, timeout_ms, [], nil),
         {:ok, aggregate_results, aggregate_count} <-
           paginate_optional(aggregates_url, creds, http_get, timeout_ms) do
      if length(prefix_results) != prefix_count do
        {:error, {:count_mismatch, length(prefix_results), prefix_count}}
      else
        # Aggregates may 404 on older NetBox; when present, validate count too.
        cond do
          is_integer(aggregate_count) and length(aggregate_results) != aggregate_count ->
            {:error, {:aggregate_count_mismatch, length(aggregate_results), aggregate_count}}

          true ->
            rows =
              (prefix_results ++ aggregate_results)
              |> Enum.map(&map_prefix_row(&1, namespaces, max_tags))
              |> Enum.reject(&is_nil/1)
              # Prefer more-specific prefix rows if both lists share a CIDR
              |> Enum.uniq_by(&{&1.prefix, &1.vrf})

            meta = %{
              reported_count: prefix_count,
              aggregate_count: aggregate_count || 0,
              imported_count: length(rows),
              source_url: prefixes_url
            }

            {:ok, rows, meta}
        end
      end
    end
  end

  # Aggregates are optional — 404 means the NetBox build has no aggregates API.
  defp paginate_optional(url, creds, http_get, timeout_ms) do
    case paginate(url, creds, http_get, timeout_ms, [], nil) do
      {:ok, results, count} -> {:ok, results, count}
      {:error, {:http_status, 404}} -> {:ok, [], 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp paginate(nil, _creds, _http_get, _timeout, acc, count), do: {:ok, acc, count || length(acc)}

  defp paginate(url, creds, http_get, timeout_ms, acc, count) do
    headers = [
      {"authorization", "Token #{creds.token}"},
      {"accept", "application/json"}
    ]

    opts =
      [headers: headers, receive_timeout: timeout_ms]
      |> maybe_insecure(creds.verify_ssl)

    case http_get.(url, opts) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, decoded} <- decode_body(body),
             {:ok, page_results, next, page_count} <- extract_page(decoded) do
          new_acc = acc ++ page_results
          reported = count || page_count
          paginate(next, creds, http_get, timeout_ms, new_acc, reported)
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_insecure(opts, true), do: opts

  defp maybe_insecure(opts, false) do
    Keyword.put(opts, :connect_options, transport_opts: [verify: :verify_none])
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:decode_error, reason}}
    end
  end

  defp decode_body(_), do: {:error, :decode_error}

  defp extract_page(%{"results" => results} = body) when is_list(results) do
    next = Map.get(body, "next")
    count = Map.get(body, "count")

    cond do
      is_integer(count) -> {:ok, results, next, count}
      true -> {:ok, results, next, length(results)}
    end
  end

  defp extract_page(_), do: {:error, :unexpected_response_shape}

  # -- tag mapping ------------------------------------------------------------

  @doc false
  def map_prefix_row(item, namespaces \\ @default_dimension_namespaces, max_tags \\ @default_max_tags_per_prefix)
      when is_map(item) do
    prefix = item["prefix"] || item[:prefix]

    if is_binary(prefix) and prefix != "" do
      site = nested_slug(item, "site")
      role = nested_slug(item, "role")
      tenant = nested_slug(item, "tenant")
      status = status_value(item)
      vrf = nested_slug(item, "vrf") || nested_name(item, "vrf")

      tags =
        []
        |> maybe_ns_tag(namespaces, :site, site && "site:#{site}")
        |> maybe_ns_tag(namespaces, :role, role && "role:#{role}")
        |> maybe_ns_tag(namespaces, :tenant, tenant && "tenant:#{tenant}")
        |> maybe_ns_tag(namespaces, :status, status && "status:#{status}")
        |> maybe_ns_tag(namespaces, :vrf, vrf && "vrf:#{slugify(vrf)}")
        |> maybe_netbox_tags(namespaces, item)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(max_tags)

      %{
        prefix: prefix,
        vrf: vrf,
        tags: tags,
        site: site,
        role: role,
        tenant: tenant,
        status: status,
        source: @source_name
      }
    else
      nil
    end
  end

  defp maybe_ns_tag(acc, namespaces, key, tag) do
    if Map.get(namespaces, key, true) and is_binary(tag), do: acc ++ [tag], else: acc
  end

  defp maybe_netbox_tags(acc, namespaces, item) do
    if Map.get(namespaces, :tags, true) do
      tags =
        item
        |> Map.get("tags", [])
        |> List.wrap()
        |> Enum.map(fn
          %{"slug" => slug} when is_binary(slug) and slug != "" -> "netbox:tag:#{slug}"
          %{slug: slug} when is_binary(slug) and slug != "" -> "netbox:tag:#{slug}"
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      acc ++ tags
    else
      acc
    end
  end

  defp nested_slug(item, key) do
    case Map.get(item, key) do
      %{"slug" => slug} when is_binary(slug) and slug != "" -> slug
      %{slug: slug} when is_binary(slug) and slug != "" -> slug
      _ -> nil
    end
  end

  defp nested_name(item, key) do
    case Map.get(item, key) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp status_value(item) do
    case Map.get(item, "status") do
      %{"value" => value} when is_binary(value) -> value
      %{"label" => label} when is_binary(label) -> slugify(label)
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  # -- promote ----------------------------------------------------------------

  @doc false
  def promote_snapshot(source_url, rows, meta) when is_list(rows) do
    snapshot_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    now = DateTime.truncate(DateTime.utc_now(), :second)
    content_hash = content_hash(rows)

    fn ->
      {1, _} =
        Repo.insert_all(
          "prefix_tag_snapshots",
          [
            %{
              id: snapshot_id,
              source: @source_name,
              status: "building",
              source_url: source_url,
              source_etag: nil,
              source_sha256: content_hash,
              fetched_at: now,
              promoted_at: nil,
              is_active: false,
              record_count: length(rows),
              metadata: meta || %{},
              inserted_at: now,
              updated_at: now
            }
          ],
          prefix: "platform",
          timeout: @db_timeout_ms
        )

      count = insert_prefix_rows(snapshot_id, rows, now)

      if count == 0 and rows != [] do
        Repo.rollback(:no_rows_inserted)
      else
        # Deactivate other active snapshots for this source only
        Repo.query!(
          """
          UPDATE platform.prefix_tag_snapshots
          SET is_active = FALSE, status = 'superseded', updated_at = now()
          WHERE source = $1 AND is_active = TRUE AND id <> $2
          """,
          [@source_name, snapshot_id],
          timeout: @db_timeout_ms
        )

        Repo.query!(
          """
          UPDATE platform.prefix_tag_snapshots
          SET is_active = TRUE, status = 'active', promoted_at = now(),
              record_count = $2, updated_at = now()
          WHERE id = $1
          """,
          [snapshot_id, count],
          timeout: @db_timeout_ms
        )

        :ok
      end
    end
    |> Repo.transaction(timeout: @db_timeout_ms)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_prefix_rows(snapshot_id, rows, now) do
    rows
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      insert_rows =
        Enum.flat_map(chunk, fn row ->
          case Cidr.dump_to_native(row.prefix, []) do
            {:ok, %Postgrex.INET{} = inet} ->
              [
                %{
                  id: Ecto.UUID.dump!(Ecto.UUID.generate()),
                  snapshot_id: snapshot_id,
                  prefix: inet,
                  vrf: row[:vrf],
                  tags: row[:tags] || [],
                  site: row[:site],
                  role: row[:role],
                  tenant: row[:tenant],
                  status: row[:status],
                  partition: nil,
                  inserted_at: now,
                  updated_at: now
                }
              ]

            _ ->
              []
          end
        end)

      {count, _} =
        Repo.insert_all("prefix_tags", insert_rows, prefix: "platform", timeout: @db_timeout_ms)

      acc + count
    end)
  end

  defp content_hash(rows) do
    rows
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- scheduling / config ----------------------------------------------------

  defp schedule_next(seconds) when is_integer(seconds) do
    _ =
      %{}
      |> successor_job(schedule_in: max(seconds, 60))
      |> ObanSupport.safe_insert()

    :ok
  end

  defp successor_job(args, opts) do
    new(args, Keyword.put(opts, :unique, @successor_unique))
  end

  defp scheduler_node? do
    cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled, false)

    cluster_coordinator =
      Application.get_env(:serviceradar_core, :cluster_coordinator, cluster_enabled)

    if cluster_enabled, do: cluster_coordinator == true, else: true
  end

  defp config, do: Application.get_env(:serviceradar_core, __MODULE__, [])

  defp default_http_get(url, opts), do: Req.get(url, opts)

  defp emit_import_telemetry(outcome, record_count, duration_us) do
    :telemetry.execute(
      [:serviceradar, :prefix_tags, :import],
      %{duration_us: duration_us, record_count: record_count},
      %{outcome: outcome, source: @source_name}
    )
  end
end
