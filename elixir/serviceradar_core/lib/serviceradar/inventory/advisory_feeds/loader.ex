defmodule ServiceRadar.Inventory.AdvisoryFeeds.Loader do
  @moduledoc """
  Chunked bulk loader for advisories + coordinates (design D4, tasks 3.5/1.4).

  Records arrive as a `Stream` of `%{advisory: map, coordinates: [map]}` from a
  parser. This module accumulates **bounded chunks** (default 2,000 advisories)
  and flushes them with `Repo.insert_all` upserts — never one Ash create per row.

  ## Generation swap

  Each run gets a fresh integer `generation`. Rows are written tagged with that
  generation and `current: false`; on success `finalize/3` flips the new
  generation to `current: true` and the previous generations to `current: false`
  in one statement, so the matcher always reads one consistent generation. Stale
  generations are reaped.

  Advisories upsert on `(provider, feed_key, source_object_id)`. Coordinates are
  rewritten per generation (delete old generation's rows for the advisory, insert
  the new) via upsert on the coordinate identity.

  Bounded memory: only one chunk of rows is resident at a time, independent of
  total feed size.
  """

  import Ecto.Query

  alias ServiceRadar.Repo

  require Logger

  @default_chunk_size 2_000
  # Each coordinate row is ~16 bind params. Postgrex caps a statement at 65_535
  # params; 2_000 rows stays well under that when a single NVD advisory expands
  # to tens of CPE rows and the advisory-sized chunk would otherwise flush
  # 20k+ coordinates in one insert_all.
  @max_coordinate_insert 2_000
  @schema "platform"

  @type load_result :: %{
          advisories_upserted: non_neg_integer(),
          coordinates_upserted: non_neg_integer(),
          advisories_skipped: non_neg_integer(),
          generation: integer()
        }

  @doc """
  Allocate the next generation number for a feed (monotonic per provider/feed).
  """
  @spec next_generation(String.t(), String.t()) :: integer()
  def next_generation(provider, feed_key) do
    case max_generation(provider, feed_key) do
      nil -> 1
      max -> max + 1
    end
  end

  @doc """
  Generation that was written but never finalized (`current` is still false).

  A core restart mid-load leaves rows in this generation. Resume writes
  the same generation instead of allocating another incomplete copy.
  """
  @spec in_progress_generation(String.t(), String.t()) :: integer() | nil
  def in_progress_generation(provider, feed_key) do
    current = current_generation(provider, feed_key)
    newest = max_generation(provider, feed_key)

    cond do
      is_integer(newest) and is_nil(current) -> newest
      is_integer(newest) and is_integer(current) and newest > current -> newest
      true -> nil
    end
  end

  defp max_generation(provider, feed_key) do
    query =
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key,
        select: max(a.generation)
      )

    Repo.one(query, prefix: @schema)
  end

  defp current_generation(provider, feed_key) do
    query =
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key and a.current == true,
        select: max(a.generation)
      )

    Repo.one(query, prefix: @schema)
  end

  @doc """
  Load a stream of parsed records for one feed run.

  `records` is an enumerable of `%{advisory: map, coordinates: [map]}`.
  Options: `:provider`, `:feed_key` (required), `:generation`, `:chunk_size`,
  `:now`.
  """
  @spec load_stream(Enumerable.t(), keyword()) :: load_result()
  def load_stream(records, opts) do
    provider = Keyword.fetch!(opts, :provider)
    feed_key = Keyword.fetch!(opts, :feed_key)

    generation =
      Keyword.get_lazy(opts, :generation, fn -> next_generation(provider, feed_key) end)

    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    existing_modified =
      Keyword.get_lazy(opts, :existing_modified, fn ->
        existing_modified_at(provider, feed_key)
      end)

    init = %{
      advisories_upserted: 0,
      coordinates_upserted: 0,
      advisories_skipped: 0,
      generation: generation
    }

    records
    |> Stream.chunk_every(chunk_size)
    |> Enum.reduce(init, fn chunk, acc ->
      {changed, skipped} =
        Enum.split_with(chunk, &(not unchanged_advisory?(&1, existing_modified)))

      {adv, coord} = flush_chunk(changed, provider, feed_key, generation, now)

      %{
        acc
        | advisories_upserted: acc.advisories_upserted + adv,
          coordinates_upserted: acc.coordinates_upserted + coord,
          advisories_skipped: acc.advisories_skipped + length(skipped)
      }
    end)
  end

  @doc false
  def existing_modified_at(provider, feed_key) do
    query =
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key,
        select: {a.source_object_id, a.modified_at}
      )

    query
    |> Repo.all(prefix: @schema)
    |> Map.new()
  end

  @doc false
  def unchanged_advisory?(%{advisory: advisory}, existing_modified) do
    source_object_id = fetch(advisory, :source_object_id)
    incoming = parse_datetime(fetch(advisory, :modified_at))

    case Map.fetch(existing_modified, source_object_id) do
      {:ok, existing} -> same_modified?(existing, incoming)
      :error -> false
    end
  end

  def unchanged_advisory?(_record, _existing_modified), do: false

  defp same_modified?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(left, right) == :eq
  end

  defp same_modified?(_left, _right), do: false

  @doc """
  Promote `generation` to current and demote all earlier generations.
  Optionally reap demoted rows (default: keep one prior generation).
  """
  @spec finalize(String.t(), String.t(), integer(), keyword()) :: :ok
  def finalize(provider, feed_key, generation, opts \\ []) do
    # Unchanged CVEs were skipped and still carry the previous generation.
    # Promote them in place (two cheap columns, no jsonb rewrite) so a
    # completed incremental run stays one current generation.
    Repo.update_all(
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key and a.generation != ^generation
      ),
      [set: [generation: generation, current: true]],
      prefix: @schema
    )

    Repo.update_all(
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key and a.generation == ^generation
      ),
      [set: [current: true]],
      prefix: @schema
    )

    if Keyword.get(opts, :reap, true) do
      reap_old_generations(provider, feed_key, generation)
    end

    :ok
  end

  @doc "Delete advisories (cascade coordinates) older than the kept generation."
  @spec reap_old_generations(String.t(), String.t(), integer()) :: :ok
  def reap_old_generations(provider, feed_key, current_generation) do
    keep = current_generation - 1

    Repo.delete_all(
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key and a.generation < ^keep
      ),
      prefix: @schema
    )

    :ok
  end

  defp flush_chunk([], _provider, _feed_key, _generation, _now), do: {0, 0}

  defp flush_chunk(chunk, provider, feed_key, generation, now) do
    advisory_rows =
      chunk
      |> Enum.map(fn %{advisory: advisory} ->
        advisory_row(advisory, provider, feed_key, generation, now)
      end)
      |> dedupe_advisory_rows()

    {_, returned} =
      Repo.insert_all("vulnerability_advisories", advisory_rows,
        prefix: @schema,
        on_conflict:
          {:replace,
           [
             :advisory_id,
             :cve_id,
             :title,
             :description,
             :severity,
             :cvss_score,
             :cvss_vector,
             :published_at,
             :modified_at,
             :kev,
             :exploit_available,
             :references,
             :raw,
             :generation,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:provider, :feed_key, :source_object_id],
        returning: [:id, :source_object_id]
      )

    id_by_source =
      Map.new(returned, fn row -> {row.source_object_id, row.id} end)

    coordinate_rows =
      Enum.flat_map(chunk, fn %{advisory: advisory} = record ->
        source_object_id = advisory[:source_object_id] || advisory["source_object_id"]

        case Map.get(id_by_source, source_object_id) do
          nil ->
            []

          advisory_ref ->
            record
            |> Map.get(:coordinates, [])
            |> Enum.map(&coordinate_row(&1, advisory_ref, provider, feed_key, generation, now))
        end
      end)

    coordinates_upserted = insert_coordinates(coordinate_rows)

    {length(advisory_rows), coordinates_upserted}
  end

  defp insert_coordinates([]), do: 0

  defp insert_coordinates(rows) do
    rows
    |> dedupe_coordinate_rows()
    |> Enum.chunk_every(@max_coordinate_insert)
    |> Enum.reduce(0, fn batch, acc ->
      acc + insert_coordinate_batch(batch)
    end)
  end

  # Postgrex ON CONFLICT DO UPDATE cannot touch the same identity twice in one
  # statement. NVD repeats a CPE + version window under different
  # matchCriteriaId values, so the parser's Enum.uniq/1 is not enough.
  @doc false
  def dedupe_coordinate_rows(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc -> Map.put(acc, coordinate_conflict_key(row), row) end)
    |> Map.values()
  end

  defp coordinate_conflict_key(row) do
    {
      Map.fetch!(row, :advisory_ref),
      Map.fetch!(row, :coordinate_type),
      Map.fetch!(row, :value),
      Map.get(row, :version_start),
      Map.get(row, :version_end)
    }
  end

  defp dedupe_advisory_rows(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc -> Map.put(acc, row.source_object_id, row) end)
    |> Map.values()
  end

  defp insert_coordinate_batch(rows) do
    {count, _} =
      Repo.insert_all("advisory_coordinates", rows,
        prefix: @schema,
        on_conflict:
          {:replace,
           [
             :cpe_part,
             :cpe_vendor,
             :cpe_product,
             :cpe_version,
             :version_start_inclusive,
             :version_end_inclusive,
             :generation,
             :metadata,
             :updated_at
           ]},
        conflict_target: [
          :advisory_ref,
          :coordinate_type,
          :value,
          :version_start,
          :version_end
        ],
        returning: false
      )

    count
  end

  defp advisory_row(advisory, provider, feed_key, generation, now) do
    %{
      provider: provider,
      feed_key: feed_key,
      source_object_id: fetch(advisory, :source_object_id),
      advisory_id: fetch(advisory, :advisory_id),
      cve_id: fetch(advisory, :cve_id),
      title: fetch(advisory, :title),
      description: fetch(advisory, :description),
      severity: fetch(advisory, :severity),
      cvss_score: fetch(advisory, :cvss_score),
      cvss_vector: fetch(advisory, :cvss_vector),
      published_at: parse_datetime(fetch(advisory, :published_at)),
      modified_at: parse_datetime(fetch(advisory, :modified_at)),
      kev: fetch(advisory, :kev) || false,
      exploit_available: fetch(advisory, :exploit_available) || false,
      affected_coordinates: [],
      references: fetch(advisory, :references) || [],
      raw: fetch(advisory, :raw) || %{},
      generation: generation,
      current: false,
      metadata: fetch(advisory, :metadata) || %{},
      inserted_at: now,
      updated_at: now
    }
  end

  defp coordinate_row(coordinate, advisory_ref, provider, feed_key, generation, now) do
    %{
      advisory_ref: advisory_ref,
      provider: provider,
      feed_key: feed_key,
      generation: generation,
      coordinate_type: fetch(coordinate, :coordinate_type),
      value: fetch(coordinate, :value),
      cpe_part: fetch(coordinate, :cpe_part),
      cpe_vendor: fetch(coordinate, :cpe_vendor),
      cpe_product: fetch(coordinate, :cpe_product),
      cpe_version: fetch(coordinate, :cpe_version),
      version_start: fetch(coordinate, :version_start),
      version_start_inclusive: fetch(coordinate, :version_start_inclusive),
      version_end: fetch(coordinate, :version_end),
      version_end_inclusive: fetch(coordinate, :version_end_inclusive),
      metadata: fetch(coordinate, :metadata) || %{},
      inserted_at: now,
      updated_at: now
    }
  end

  defp fetch(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> parse_naive(value)
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_naive(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end
end
