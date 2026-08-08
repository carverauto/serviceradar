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

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Observability.OutboundFeedPolicy
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.ObanSchedule
  alias ServiceRadar.PrefixTags.PrefixTag
  alias ServiceRadar.PrefixTags.Slug
  alias ServiceRadar.PrefixTags.Snapshot
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @source_name "netbox"
  @default_page_limit 200
  @default_timeout_ms 30_000
  @default_reschedule_seconds 15 * 60
  @default_failure_reschedule_seconds 30 * 60
  @default_max_tags_per_prefix 32
  @default_max_pages 500
  @insert_chunk_size 250
  @db_timeout_ms 120_000

  # Dimension namespaces control which NetBox fields become LPM tags.
  # site/role/tenant/status columns on prefix_tags are denormalized mirrors for
  # list UI; tags remain the LPM/query source of truth.
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
  def ensure_scheduled, do: ObanSchedule.ensure_scheduled(__MODULE__)

  @impl Oban.Worker
  def perform(_job) do
    if ObanSchedule.scheduler_node?() do
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

          ObanSchedule.schedule_next(
            __MODULE__,
            Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)
          )

        {:error, reason} ->
          duration_us = System.monotonic_time(:microsecond) - started
          emit_import_telemetry(:error, 0, duration_us)

          Logger.warning("NetBox prefix-tag promotion failed", reason: inspect(reason))

          ObanSchedule.schedule_next(
            __MODULE__,
            Keyword.get(config, :failure_reschedule_seconds, @default_failure_reschedule_seconds)
          )
      end
    else
      {:error, :no_credentials} ->
        Logger.info("NetBox prefix-tag import skipped: no credentials configured")

        ObanSchedule.schedule_next(
          __MODULE__,
          Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)
        )

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - started
        emit_import_telemetry(:error, 0, duration_us)

        Logger.warning("NetBox prefix-tag import failed", reason: inspect(reason))

        ObanSchedule.schedule_next(
          __MODULE__,
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
    keys
    |> Enum.reduce_while(:__miss__, fn key, _acc ->
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
    max_pages = Keyword.get(config, :max_pages, @default_max_pages)
    namespaces = Keyword.get(config, :dimension_namespaces, @default_dimension_namespaces)
    max_tags = Keyword.get(config, :max_tags_per_prefix, @default_max_tags_per_prefix)

    prefixes_url = "#{creds.url}/api/ipam/prefixes/?limit=#{page_limit}"
    aggregates_url = "#{creds.url}/api/ipam/aggregates/?limit=#{page_limit}"

    with {:ok, prefix_results, prefix_count} <-
           paginate(prefixes_url, creds, http_get, timeout_ms, [], nil, 0, max_pages),
         {:ok, aggregate_results, aggregate_count} <-
           paginate_optional(aggregates_url, creds, http_get, timeout_ms, max_pages) do
      if length(prefix_results) == prefix_count do
        # Aggregates may 404 on older NetBox; when present, validate count too.
        if is_integer(aggregate_count) and length(aggregate_results) != aggregate_count do
          {:error, {:aggregate_count_mismatch, length(aggregate_results), aggregate_count}}
        else
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
      else
        {:error, {:count_mismatch, length(prefix_results), prefix_count}}
      end
    end
  end

  # Aggregates are optional — 404 means the NetBox build has no aggregates API.
  defp paginate_optional(url, creds, http_get, timeout_ms, max_pages) do
    case paginate(url, creds, http_get, timeout_ms, [], nil, 0, max_pages) do
      {:ok, results, count} -> {:ok, results, count}
      {:error, {:http_status, 404}} -> {:ok, [], 0}
      {:error, reason} -> {:error, reason}
    end
  end

  # `acc` is a reverse list of page chunks; flattened once at the end (O(n)).
  defp paginate(nil, _creds, _http_get, _timeout, acc, count, _pages, _max) do
    results = acc |> Enum.reverse() |> Enum.concat()
    {:ok, results, count || length(results)}
  end

  defp paginate(_url, _creds, _http_get, _timeout, _acc, _count, pages, max_pages)
       when is_integer(pages) and is_integer(max_pages) and pages >= max_pages do
    {:error, {:too_many_pages, max_pages}}
  end

  defp paginate(url, creds, http_get, timeout_ms, acc, count, pages, max_pages)
       when is_binary(url) do
    with {:ok, safe_url} <- validate_request_url(url, creds.url) do
      headers = [
        {"authorization", "Token #{creds.token}"},
        {"accept", "application/json"}
      ]

      opts =
        timeout_ms
        |> request_opts(creds.verify_ssl)
        |> Keyword.put(:headers, headers)

      case http_get.(safe_url, opts) do
        {:ok, %{status: 200, body: body}} ->
          with {:ok, decoded} <- decode_body(body),
               {:ok, page_results, next, page_count} <- extract_page(decoded),
               {:ok, next_url} <- validate_next_url(next, creds.url) do
            reported = count || page_count

            paginate(
              next_url,
              creds,
              http_get,
              timeout_ms,
              [page_results | acc],
              reported,
              pages + 1,
              max_pages
            )
          end

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Never follow pagination (or re-send the token) to a different origin than
  # the configured NetBox base URL — same defense as the NetBox Wasm plugin.
  @doc false
  def validate_next_url(nil, _base_url), do: {:ok, nil}
  def validate_next_url("", _base_url), do: {:ok, nil}

  def validate_next_url(next, base_url) when is_binary(next) and is_binary(base_url) do
    validate_request_url(next, base_url)
  end

  def validate_next_url(_, _), do: {:error, :invalid_next_url}

  @doc false
  def validate_request_url(url, base_url) when is_binary(url) and is_binary(base_url) do
    with {:ok, base} <- parse_uri(base_url),
         {:ok, target} <- resolve_against_base(url, base),
         true <- same_origin?(base, target) do
      {:ok, URI.to_string(target)}
    else
      false -> {:error, {:next_url_host_mismatch, url}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_against_base(url, %URI{} = base) when is_binary(url) do
    case parse_uri(url) do
      {:ok, uri} ->
        {:ok, uri}

      {:error, _} ->
        # Relative next path (NetBox may emit path-only pagination links).
        merged = URI.merge(base, url)
        parse_uri(URI.to_string(merged))
    end
  end

  defp parse_uri(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, scheme: scheme} = uri}
      when is_binary(host) and host != "" and scheme in ["http", "https"] ->
        {:ok, uri}

      {:ok, _} ->
        {:error, :invalid_url}

      {:error, reason} ->
        {:error, {:invalid_url, reason}}
    end
  end

  defp same_origin?(%URI{} = base, %URI{} = target) do
    String.downcase(base.host || "") == String.downcase(target.host || "") and
      (base.scheme || "https") == (target.scheme || "https") and
      normalize_port(base) == normalize_port(target)
  end

  defp normalize_port(%URI{port: port, scheme: "https"}) when port in [nil, 443], do: 443
  defp normalize_port(%URI{port: port, scheme: "http"}) when port in [nil, 80], do: 80
  defp normalize_port(%URI{port: port}), do: port

  defp maybe_insecure(opts, true), do: opts

  defp maybe_insecure(opts, false) do
    # Req 0.6 refuses :finch and :connect_options together. Drop the named
    # pool when dynamic TLS options are required (self-signed NetBox).
    opts
    |> Keyword.delete(:finch)
    |> Keyword.put(:connect_options, transport_opts: [verify: :verify_none])
  end

  @doc false
  @spec request_opts(pos_integer(), boolean()) :: keyword()
  def request_opts(timeout_ms, verify_ssl)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_boolean(verify_ssl) do
    timeout_ms
    |> OutboundFeedPolicy.req_opts()
    |> maybe_insecure(verify_ssl)
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

    if is_integer(count) do
      {:ok, results, next, count}
    else
      {:ok, results, next, length(results)}
    end
  end

  defp extract_page(_), do: {:error, :unexpected_response_shape}

  # -- tag mapping ------------------------------------------------------------

  @doc false
  def map_prefix_row(
        item,
        namespaces \\ @default_dimension_namespaces,
        max_tags \\ @default_max_tags_per_prefix
      )
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
        |> maybe_ns_tag(namespaces, :vrf, vrf && "vrf:#{Slug.slugify(vrf) || vrf}")
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
      %{"value" => value} when is_binary(value) ->
        value

      %{"label" => label} when is_binary(label) ->
        Slug.slugify(label) || label

      value when is_binary(value) ->
        value

      _ ->
        nil
    end
  end

  # -- promote ----------------------------------------------------------------

  @doc false
  def promote_snapshot(source_url, rows, meta) when is_list(rows) do
    actor = SystemActor.system(:prefix_tags_netbox_import)
    content_hash = content_hash(rows)
    now = DateTime.utc_now()

    fn ->
      # Code-interface CreateOpts do not accept :domain (resource already declares it).
      # return_notifications?: true so we can flush after the outer transaction commits.
      {:ok, snapshot, notes} =
        Snapshot.create(
          %{
            source: @source_name,
            status: "building",
            source_url: source_url,
            source_sha256: content_hash,
            fetched_at: now,
            is_active: false,
            record_count: 0,
            metadata: meta || %{}
          },
          actor: actor,
          return_notifications?: true
        )

      {count, bulk_notes} = bulk_insert_prefix_tags!(snapshot.id, rows, actor)

      if count == 0 and rows != [] do
        Repo.rollback(:no_rows_inserted)
      else
        supersede_notes = supersede_previous_active!(actor, snapshot.id)
        promote_notes = promote_active!(snapshot, count, actor)

        {notes ++ bulk_notes ++ supersede_notes ++ promote_notes, :ok}
      end
    end
    |> Repo.transaction(timeout: @db_timeout_ms)
    |> case do
      {:ok, {notifications, :ok}} ->
        _ = Ash.Notifier.notify(notifications)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bulk_insert_prefix_tags!(snapshot_id, rows, actor) do
    inputs =
      rows
      |> Enum.map(fn row ->
        %{
          snapshot_id: snapshot_id,
          prefix: row.prefix,
          vrf: row[:vrf],
          tags: row[:tags] || [],
          site: row[:site],
          role: row[:role],
          tenant: row[:tenant],
          status: row[:status],
          partition: nil
        }
      end)
      |> Enum.filter(&(is_binary(&1.prefix) and &1.prefix != ""))

    inputs
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, []}, fn chunk, {acc, notes_acc} ->
      case Ash.bulk_create(chunk, PrefixTag, :create,
             actor: actor,
             domain: ServiceRadar.PrefixTags,
             return_records?: false,
             return_errors?: true,
             return_notifications?: true,
             stop_on_error?: true,
             batch_size: @insert_chunk_size,
             timeout: @db_timeout_ms
           ) do
        %Ash.BulkResult{status: :success, notifications: notes} ->
          {acc + length(chunk), notes_acc ++ List.wrap(notes)}

        %Ash.BulkResult{status: status, errors: errors} = result ->
          Repo.rollback({:bulk_create_failed, status, errors || result})

        other ->
          Repo.rollback({:bulk_create_failed, other})
      end
    end)
  end

  defp supersede_previous_active!(actor, keep_id) do
    case Snapshot.active_for_source(%{source: @source_name}, actor: actor) do
      {:ok, %Snapshot{id: id} = previous} when id != keep_id ->
        case previous
             |> Ash.Changeset.for_update(:supersede, %{}, actor: actor)
             |> Ash.update(domain: ServiceRadar.PrefixTags, return_notifications?: true) do
          {:ok, _, notes} -> List.wrap(notes)
          {:ok, _} -> []
          {:error, err} -> Repo.rollback({:supersede_failed, err})
        end

      {:ok, _} ->
        []

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        if Enum.any?(errors, &match?(%NotFound{}, &1)) do
          []
        else
          Repo.rollback({:supersede_failed, errors})
        end

      {:error, %NotFound{}} ->
        []

      {:error, err} ->
        Repo.rollback({:supersede_failed, err})
    end
  end

  defp promote_active!(snapshot, count, actor) do
    case Snapshot.promote(snapshot, %{record_count: count},
           actor: actor,
           return_notifications?: true
         ) do
      {:ok, _, notes} -> List.wrap(notes)
      {:ok, _} -> []
      {:error, err} -> Repo.rollback({:promote_failed, err})
    end
  end

  # Streaming hash — avoid Jason-encoding the entire import as one binary.
  defp content_hash(rows) when is_list(rows) do
    rows
    |> Enum.reduce(:crypto.hash_init(:sha256), fn row, acc ->
      iodata = [
        to_string(row[:prefix] || row["prefix"] || ""),
        0,
        to_string(row[:vrf] || row["vrf"] || ""),
        0,
        Enum.join(List.wrap(row[:tags] || row["tags"] || []), ",")
      ]

      :crypto.hash_update(acc, iodata)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # -- scheduling / config ----------------------------------------------------

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
