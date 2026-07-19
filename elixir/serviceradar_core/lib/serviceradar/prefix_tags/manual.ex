defmodule ServiceRadar.PrefixTags.Manual do
  @moduledoc """
  Operator-facing helpers for the permanent `manual` prefix-tag snapshot.

  Ensures an active manual snapshot exists, performs CRUD under
  `settings.prefix_tags.manage`, and broadcasts Loader invalidation so tries
  refresh cluster-wide.
  """

  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.PrefixTag
  alias ServiceRadar.PrefixTags.Snapshot
  alias ServiceRadar.PrefixTags.Store

  require Ash.Query
  require Logger

  @source "manual"
  # Align with rust/srql flows::literals::normalize_tag_literal
  @max_tag_bytes 128
  @tag_char_re ~r/^[A-Za-z0-9:._\/@+\-]+$/

  @doc "Canonical source name for manually authored tags."
  @spec source_name() :: String.t()
  def source_name, do: @source

  @doc """
  Return the active manual snapshot, creating + promoting one if missing.
  """
  @spec ensure_active_snapshot!(keyword()) :: Snapshot.t()
  def ensure_active_snapshot!(opts \\ []) do
    ash_opts = ash_opts(opts)

    case Snapshot.active_for_source(%{source: @source}, ash_opts) do
      {:ok, %Snapshot{} = snap} ->
        snap

      {:error, %Ash.Error.Query.NotFound{}} ->
        create_active_manual_snapshot!(ash_opts)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
          create_active_manual_snapshot!(ash_opts)
        else
          raise "PrefixTags.Manual ensure_active_snapshot failed: #{inspect(errors)}"
        end

      {:error, reason} ->
        raise "PrefixTags.Manual ensure_active_snapshot failed: #{inspect(reason)}"
    end
  end

  @doc "List prefix tags for a source (default manual). Loads snapshot."
  @spec list(keyword()) :: {:ok, [PrefixTag.t()]} | {:error, term()}
  def list(opts \\ []) do
    source = Keyword.get(opts, :source, @source)
    ash_opts = ash_opts(opts)

    query =
      PrefixTag
      |> Ash.Query.for_read(:list_active, %{}, ash_opts)
      |> Ash.Query.filter(snapshot.source == ^source)
      |> Ash.Query.sort(prefix: :asc)
      |> Ash.Query.limit(Keyword.get(opts, :limit, 500))

    case Ash.read(query, ash_opts) do
      {:ok, page} -> {:ok, page_results(page)}
      {:error, err} -> {:error, err}
    end
  end

  @doc "List tags across all active sources (for read-only imported views)."
  @spec list_all_active(keyword()) :: {:ok, [PrefixTag.t()]} | {:error, term()}
  def list_all_active(opts \\ []) do
    ash_opts = ash_opts(opts)

    query =
      PrefixTag
      |> Ash.Query.for_read(:list_active, %{}, ash_opts)
      |> Ash.Query.sort(prefix: :asc)
      |> Ash.Query.limit(Keyword.get(opts, :limit, 1000))

    case Ash.read(query, ash_opts) do
      {:ok, page} -> {:ok, page_results(page)}
      {:error, err} -> {:error, err}
    end
  end

  @doc "Create a manual prefix tag and refresh the local trie."
  @spec create(map(), keyword()) :: {:ok, PrefixTag.t()} | {:error, term()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    ash_opts = ash_opts(opts)

    with {:ok, snapshot} <- ensure_active_snapshot(opts),
         attrs <-
           attrs
           |> stringify_keys()
           |> Map.put("snapshot_id", snapshot.id)
           |> normalize_tags_attr(),
         :ok <- validate_tags(Map.get(attrs, "tags")),
         {:ok, tag} <- PrefixTag.create_manual(attrs, ash_opts) do
      _ = bump_record_count!(snapshot, ash_opts)
      invalidate!()
      {:ok, tag}
    end
  end

  @doc "Update a manual prefix tag (refuses non-manual rows)."
  @spec update(PrefixTag.t(), map(), keyword()) :: {:ok, PrefixTag.t()} | {:error, term()}
  def update(%PrefixTag{} = tag, attrs, opts \\ []) do
    ash_opts = ash_opts(opts)

    with :ok <- assert_manual!(tag, ash_opts) do
      attrs =
        attrs
        |> stringify_keys()
        |> normalize_tags_attr()
        |> Map.drop(["snapshot_id", :snapshot_id])

      with :ok <- validate_tags(Map.get(attrs, "tags")),
           {:ok, updated} <- PrefixTag.update(tag, attrs, ash_opts) do
        invalidate!()
        {:ok, updated}
      end
    end
  end

  @doc "Destroy a manual prefix tag (refuses non-manual rows)."
  @spec destroy(PrefixTag.t(), keyword()) :: :ok | {:error, term()}
  def destroy(%PrefixTag{} = tag, opts \\ []) do
    ash_opts = ash_opts(opts)

    with :ok <- assert_manual!(tag, ash_opts) do
      case PrefixTag.destroy(tag, ash_opts) do
        :ok ->
          case Snapshot.by_id(%{id: tag.snapshot_id}, ash_opts) do
            {:ok, snap} -> _ = bump_record_count!(snap, ash_opts)
            _ -> :ok
          end

          invalidate!()
          :ok

        {:ok, _} ->
          invalidate!()
          :ok

        {:error, err} ->
          {:error, err}
      end
    end
  end

  @doc "Parse a free-form tags field (comma/whitespace/newline separated)."
  @spec parse_tags_input(term()) :: [String.t()]
  def parse_tags_input(nil), do: []
  def parse_tags_input(list) when is_list(list), do: normalize_tag_list(list)

  def parse_tags_input(text) when is_binary(text) do
    text
    |> String.split([",", "\n", "\r", "\t", " "], trim: true)
    |> normalize_tag_list()
  end

  def parse_tags_input(_), do: []

  # -- internals --------------------------------------------------------------

  defp ensure_active_snapshot(opts) do
    {:ok, ensure_active_snapshot!(opts)}
  rescue
    e -> {:error, e}
  end

  defp create_active_manual_snapshot!(ash_opts) do
    now = DateTime.utc_now()

    case Snapshot.create(
           %{
             source: @source,
             status: "building",
             is_active: false,
             record_count: 0,
             fetched_at: now,
             metadata: %{"managed_by" => "manual_ui"}
           },
           ash_opts
         ) do
      {:ok, building} ->
        case Snapshot.promote(
               building,
               %{record_count: 0, metadata: %{"managed_by" => "manual_ui"}},
               ash_opts
             ) do
          {:ok, active} ->
            active

          {:error, _} ->
            case Snapshot.active_for_source(%{source: @source}, ash_opts) do
              {:ok, %Snapshot{} = snap} -> snap
              {:error, err} -> raise "PrefixTags.Manual promote race: #{inspect(err)}"
            end
        end

      {:error, _} ->
        case Snapshot.active_for_source(%{source: @source}, ash_opts) do
          {:ok, %Snapshot{} = snap} -> snap
          {:error, err} -> raise "PrefixTags.Manual create race: #{inspect(err)}"
        end
    end
  end

  defp assert_manual!(%PrefixTag{} = tag, ash_opts) do
    case tag do
      %{snapshot: %Snapshot{source: @source}} ->
        :ok

      %{snapshot: %Snapshot{source: _other}} ->
        {:error, :not_manual}

      _ ->
        case Snapshot.by_id(%{id: tag.snapshot_id}, ash_opts) do
          {:ok, %Snapshot{source: @source}} -> :ok
          {:ok, _} -> {:error, :not_manual}
          {:error, err} -> {:error, err}
        end
    end
  end

  defp bump_record_count!(%Snapshot{} = snapshot, ash_opts) do
    count =
      case Ecto.Adapters.SQL.query(
             ServiceRadar.Repo,
             """
             SELECT COUNT(*)::bigint
             FROM platform.prefix_tags
             WHERE snapshot_id = $1
             """,
             [snapshot.id]
           ) do
        {:ok, %{rows: [[n]]}} when is_integer(n) -> n
        {:ok, %{rows: [[n]]}} -> String.to_integer(to_string(n))
        _ -> 0
      end

    _ = Snapshot.update_record_count(snapshot, %{record_count: count}, ash_opts)
    count
  rescue
    e ->
      Logger.debug("PrefixTags.Manual record_count bump failed", error: Exception.message(e))
      0
  end

  defp invalidate! do
    # Prefer Loader (CNPG → Store); fall back to rebuilding from the active
    # manual snapshot when the GenServer is not running (unit tests / partial boot).
    case safe_loader_reload() do
      :ok -> :ok
      {:error, _} -> rebuild_local_manual_trie()
    end

    _ = Loader.broadcast_invalidation(%{source: @source})
    :ok
  end

  defp safe_loader_reload do
    Loader.reload(@source)
  rescue
    _ -> {:error, :loader_unavailable}
  catch
    :exit, _ -> {:error, :loader_unavailable}
  end

  defp rebuild_local_manual_trie do
    case list(source: @source, limit: 10_000) do
      {:ok, tags} ->
        rows =
          Enum.map(tags, fn tag ->
            %{
              prefix: prefix_string(tag.prefix),
              tags: List.wrap(tag.tags),
              vrf: tag.vrf,
              site: tag.site,
              role: tag.role,
              tenant: tag.tenant,
              status: tag.status,
              source: @source
            }
          end)

        _ = Store.put_rows(@source, rows)
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp prefix_string(%Postgrex.INET{} = inet) do
    mask = inet.netmask || default_mask(inet.address)
    "#{inet.address |> :inet.ntoa() |> to_string()}/#{mask}"
  end

  defp prefix_string(other) when is_binary(other), do: other
  defp prefix_string(other), do: to_string(other)

  defp default_mask(addr) when tuple_size(addr) == 4, do: 32
  defp default_mask(addr) when tuple_size(addr) == 8, do: 128
  defp default_mask(_), do: 32

  defp ash_opts(opts) do
    cond do
      scope = Keyword.get(opts, :scope) ->
        [scope: scope, domain: ServiceRadar.PrefixTags]

      actor = Keyword.get(opts, :actor) ->
        [actor: actor, domain: ServiceRadar.PrefixTags]

      true ->
        [domain: ServiceRadar.PrefixTags]
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_tags_attr(attrs) do
    case Map.fetch(attrs, "tags") do
      {:ok, tags} -> Map.put(attrs, "tags", parse_tags_input(tags))
      :error -> attrs
    end
  end

  defp normalize_tag_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp validate_tags(nil), do: {:error, :tags_required}
  defp validate_tags([]), do: {:error, :tags_required}

  defp validate_tags(tags) when is_list(tags) do
    Enum.reduce_while(tags, :ok, fn tag, :ok ->
      case validate_tag_literal(tag) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_tags(_), do: {:error, :tags_invalid}

  defp validate_tag_literal(tag) when is_binary(tag) do
    cond do
      tag == "" ->
        {:error, :tag_empty}

      byte_size(tag) > @max_tag_bytes ->
        {:error, :tag_too_long}

      not Regex.match?(@tag_char_re, tag) ->
        {:error, {:tag_invalid_chars, tag}}

      true ->
        :ok
    end
  end

  defp validate_tag_literal(_), do: {:error, :tag_invalid}

  defp page_results(%Ash.Page.Keyset{results: results}), do: results
  defp page_results(%Ash.Page.Offset{results: results}), do: results
  defp page_results(list) when is_list(list), do: list
  defp page_results(%{results: results}) when is_list(results), do: results
  defp page_results(other), do: List.wrap(other)
end
