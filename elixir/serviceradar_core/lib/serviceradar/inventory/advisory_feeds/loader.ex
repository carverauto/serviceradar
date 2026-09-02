defmodule ServiceRadar.Inventory.AdvisoryFeeds.Loader do
  @moduledoc """
  Chunked bulk loader for advisories + coordinates (design D4, tasks 3.5/1.4).

  Records arrive as a `Stream` of `%{advisory: map, coordinates: [map]}` from a
  parser. This module accumulates **bounded chunks** (default 2,000 advisories)
  and flushes them with `Repo.insert_all` upserts — never one Ash create per row.

  ## Skipping unchanged advisories

  A feed re-publishes its whole corpus every run, but only a handful of
  advisories actually change. `unchanged_advisory?/2` compares the incoming
  `modified_at` against what is already stored and drops the record before it
  ever reaches an `insert_all`. This is the difference between rewriting ~360k
  advisories / ~2.5M coordinates every 6 hours and writing almost nothing:
  measured at ~5.9 TB of WAL per steady state before the guard worked.

  The guard is load-bearing, not an optimisation. `feed_worker` logs
  `advisories_skipped` and alarms when it is zero against a non-empty corpus,
  because a silently-inert guard looks exactly like a healthy run.

  ## Generation swap

  Each run gets a fresh integer `generation`. Changed rows are written tagged
  with that generation and `current: false`; `finalize/4` promotes them to
  `current: true`. **Skipped rows keep their older generation and stay
  `current: true`** — the matcher joins on `current`, never on `generation`, so a
  stale generation on a live row is harmless.

  That makes `current` (not `generation`) the liveness bit, which is why
  `reap_old_generations/3` deletes only rows that are already `current: false`.
  Demoting rows the feed did not mention is therefore only safe on a **full
  sweep** — a run that skipped nothing — and `finalize/4` requires the caller to
  say so explicitly via `:demote_missing`.

  Advisories upsert on `(provider, feed_key, source_object_id)`; coordinates on
  the coordinate identity.

  Bounded memory: only one chunk of rows is resident at a time, independent of
  total feed size.
  """

  import Ecto.Query

  alias ServiceRadar.Repo

  require Logger

  @default_chunk_size 2_000
  # Each coordinate row is 17 bind params. The binding limit is NOT the
  # constraint that matters: 2_000 rows is ~34k params, which fits Postgrex's
  # 65_535 cap fine and still produced 42 MB of WAL per statement, held row locks
  # across an 800 ms transaction, and — because log_min_duration_statement is
  # 500 ms — made Postgres echo ~742 KB of bind parameters into its own log for
  # every batch. Size this against transaction cost, not the wire protocol.
  @max_coordinate_insert 500
  @schema "platform"
  @content_hash_feeds MapSet.new(~w(cisa-kev vulncheck-kev))
  @advisory_content_fields [
    :source_object_id,
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
    :affected_coordinates,
    :references,
    :raw,
    :metadata
  ]
  @coordinate_content_fields [
    :coordinate_type,
    :value,
    :cpe_part,
    :cpe_vendor,
    :cpe_product,
    :cpe_version,
    :version_start,
    :version_start_inclusive,
    :version_end,
    :version_end_inclusive,
    :metadata
  ]

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
    query =
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key,
        select: max(a.generation)
      )

    case Repo.one(query, prefix: @schema) do
      nil -> 1
      max -> max + 1
    end
  end

  @doc """
  Load a stream of parsed records for one feed run.

  `records` is an enumerable of `%{advisory: map, coordinates: [map]}`.
  Records whose `modified_at` already matches the stored row are skipped
  entirely — see the "Skipping unchanged advisories" note above.

  Options: `:provider`, `:feed_key` (required), `:generation`, `:chunk_size`,
  `:now`, `:existing_comparison_state`.
  """
  @spec load_stream(Enumerable.t(), keyword()) :: load_result()
  def load_stream(records, opts) do
    provider = Keyword.fetch!(opts, :provider)
    feed_key = Keyword.fetch!(opts, :feed_key)

    generation =
      Keyword.get_lazy(opts, :generation, fn -> next_generation(provider, feed_key) end)

    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    existing_state =
      Keyword.get_lazy(opts, :existing_comparison_state, fn ->
        existing_comparison_state(provider, feed_key)
      end)

    comparison = comparison_for_feed(feed_key)

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
        Enum.split_with(
          chunk,
          &(not unchanged_advisory?(&1, existing_state, comparison: comparison))
        )

      {adv, coord} = flush_chunk(changed, provider, feed_key, generation, now)

      %{
        acc
        | advisories_upserted: acc.advisories_upserted + adv,
          coordinates_upserted: acc.coordinates_upserted + coord,
          advisories_skipped: acc.advisories_skipped + length(skipped)
      }
    end)
  end

  @doc """
  Map of `source_object_id => %{modified_at: modified_at, content_hash: content_hash}`
  for the feed's live advisories.

  Scoped to `current == true` on purpose: a row that is not current is either
  half-written by an aborted run or already demoted, and must be rewritten
  rather than skipped.
  """
  @spec existing_comparison_state(String.t(), String.t()) :: %{
          optional(String.t()) => %{
            modified_at: DateTime.t() | nil,
            content_hash: String.t() | nil
          }
        }
  def existing_comparison_state(provider, feed_key) do
    # `modified_at` is a `timestamp without time zone` column and this is a
    # schemaless query, so Ecto types the field as :any and hands back Postgrex's
    # raw %NaiveDateTime{}. type/2 loads it as a UTC DateTime to match the
    # DateTime the guard compares against. Same hazard and same fix as
    # topology_graph/canonical_rebuild.ex:139-147. Without this cast the guard
    # compares a NaiveDateTime to a DateTime, silently returns false for every
    # record, and the whole corpus is rewritten every run.
    query =
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key and a.current == true,
        select:
          {a.source_object_id,
           %{modified_at: type(a.modified_at, :utc_datetime_usec), content_hash: a.content_hash}}
      )

    query
    |> Repo.all(prefix: @schema)
    |> Map.new()
  end

  @doc "Map of live advisory source IDs to `modified_at` values, retained for timestamp callers."
  @spec existing_modified_at(String.t(), String.t()) :: %{
          optional(String.t()) => DateTime.t() | nil
        }
  def existing_modified_at(provider, feed_key) do
    provider
    |> existing_comparison_state(feed_key)
    |> Map.new(fn {source_object_id, %{modified_at: modified_at}} ->
      {source_object_id, modified_at}
    end)
  end

  @doc "True when the stored advisory already matches the incoming comparison mode."
  @spec unchanged_advisory?(map(), map()) :: boolean()
  def unchanged_advisory?(record, existing_state),
    do: unchanged_advisory?(record, existing_state, comparison: :modified_at)

  @spec unchanged_advisory?(map(), map(), keyword()) :: boolean()
  def unchanged_advisory?(%{advisory: advisory} = record, existing_state, opts) do
    source_object_id = fetch(advisory, :source_object_id)

    case {Keyword.get(opts, :comparison, :modified_at),
          Map.fetch(existing_state, source_object_id)} do
      {:modified_at, {:ok, existing}} ->
        same_modified?(
          existing_modified_at(existing),
          parse_datetime(fetch(advisory, :modified_at))
        )

      {:content_hash, {:ok, %{content_hash: stored_hash}}} when is_binary(stored_hash) ->
        stored_hash == content_hash(record)

      {_, :error} ->
        false

      _ ->
        false
    end
  end

  def unchanged_advisory?(_record, _existing_state, _opts), do: false

  @doc "Number of live rows whose state can participate in the feed's skip guard."
  @spec comparable_count(String.t(), map()) :: non_neg_integer()
  def comparable_count(feed_key, existing_state) do
    state_key =
      if comparison_for_feed(feed_key) == :content_hash, do: :content_hash, else: :modified_at

    Enum.count(existing_state, fn {_source_object_id, state} ->
      not is_nil(Map.get(state, state_key))
    end)
  end

  defp existing_modified_at(%{modified_at: modified_at}), do: modified_at
  defp existing_modified_at(modified_at), do: modified_at

  defp comparison_for_feed(feed_key) do
    if MapSet.member?(@content_hash_feeds, feed_key), do: :content_hash, else: :modified_at
  end

  # nil means "unknown", never "unchanged" — a feed that omits modified_at (KEV
  # does) must keep writing rather than silently stop updating.
  defp same_modified?(nil, _incoming), do: false
  defp same_modified?(_existing, nil), do: false

  defp same_modified?(existing, incoming) do
    with %DateTime{} = left <- to_utc(existing),
         %DateTime{} = right <- to_utc(incoming) do
      # MUST be compare/2, never ==. Postgres round-trips the value with
      # microsecond precision metadata ({123000, 6}) while the parsed input may
      # carry ({123000, 3}); those are the same instant but are not ==.
      DateTime.compare(left, right) == :eq
    else
      _ -> false
    end
  end

  # Accept both shapes so the guard cannot fail open if a caller supplies a map
  # built from a raw schemaless read.
  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc(_), do: nil

  @doc """
  True when this run rewrote the whole corpus, making it safe to demote rows the
  feed did not mention.

  A run that skipped anything did NOT see the full corpus in writable form: the
  skipped rows are the live ones, still carrying an older generation. Demoting
  on such a run hides them from the matcher and hands them to
  `reap_old_generations/3`, which cascade-deletes their coordinates. This is the
  gate for `finalize/4`'s `:demote_missing`.
  """
  @spec full_sweep?(load_result()) :: boolean()
  def full_sweep?(%{advisories_upserted: upserted, advisories_skipped: skipped}),
    do: upserted > 0 and skipped == 0

  @doc """
  Promote this run's rows to current, and optionally demote rows the feed did
  not mention.

  Required option `:demote_missing` — there is deliberately no default. When
  advisories were skipped, the rows still carrying an older generation are the
  *unchanged live* ones, and demoting them would hide the bulk of the corpus
  from the matcher and then feed it to `reap_old_generations/3`. Only a caller
  that knows it performed a full sweep may pass `true`; see
  `FeedWorker.full_sweep?/1`.
  """
  @spec finalize(String.t(), String.t(), integer(), keyword()) :: :ok
  def finalize(provider, feed_key, generation, opts) do
    demote_missing = Keyword.fetch!(opts, :demote_missing)
    # nist-nvd2 flips ~360k rows. Demo CNPG's default statement_timeout
    # cancelled this UPDATE and Oban retried the whole download.
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)

    Repo.transaction(fn ->
      {:ok, _} =
        Repo.query("SELECT set_config('statement_timeout', $1, true)", [
          Integer.to_string(timeout_ms)
        ])

      # Promote only rows this run actually wrote. Rows already current stay
      # untouched, so a steady-state run rewrites nothing here.
      Repo.update_all(
        from(a in "vulnerability_advisories",
          where:
            a.provider == ^provider and a.feed_key == ^feed_key and
              a.generation == ^generation and a.current == false
        ),
        [set: [current: true]],
        prefix: @schema
      )

      if demote_missing do
        demote_missing_rows(provider, feed_key, generation)
      end

      if Keyword.get(opts, :reap, true) do
        reap_old_generations(provider, feed_key, generation)
      end
    end)

    :ok
  end

  # Demote rows the feed did not re-publish. Guarded: if this would demote an
  # implausible share of the live corpus the run is treated as untrustworthy
  # (truncated download, partial parse) and nothing is demoted or reaped, because
  # a wrong demote silently hides vulnerability data from the matcher.
  defp demote_missing_rows(provider, feed_key, generation) do
    scope =
      from(a in "vulnerability_advisories",
        where: a.provider == ^provider and a.feed_key == ^feed_key
      )

    candidates =
      Repo.aggregate(
        from(a in scope, where: a.generation != ^generation and a.current == true),
        :count,
        prefix: @schema
      )

    live = Repo.aggregate(from(a in scope, where: a.current == true), :count, prefix: @schema)

    if candidates > max(100, div(live, 20)) do
      Logger.error(
        "advisory_feeds: refusing to demote #{candidates} of #{live} live #{feed_key} " <>
          "advisories; treating run as partial and skipping demote+reap"
      )

      :skipped
    else
      Repo.update_all(
        from(a in scope, where: a.generation != ^generation and a.current == true),
        [set: [current: false]],
        prefix: @schema
      )

      :ok
    end
  end

  @doc "Delete advisories (cascade coordinates) older than the kept generation."
  @spec reap_old_generations(String.t(), String.t(), integer()) :: :ok
  def reap_old_generations(provider, feed_key, current_generation) do
    keep = current_generation - 1

    # `and a.current == false` is load-bearing. Skipped advisories keep an older
    # generation while remaining live, and both advisory_coordinates.advisory_ref
    # and endpoint_vulnerability_matches reference this row ON DELETE CASCADE —
    # so dropping this predicate deletes live advisories and their coordinates.
    query =
      from(a in "vulnerability_advisories",
        where:
          a.provider == ^provider and a.feed_key == ^feed_key and
            a.generation < ^keep and a.current == false
      )

    count = Repo.aggregate(query, :count, prefix: @schema)

    if count > 0 do
      Logger.warning("advisory_feeds: reaping #{count} demoted #{feed_key} advisories")
      Repo.delete_all(query, prefix: @schema)
    end

    :ok
  end

  # A fully-skipped chunk must not open a transaction or issue an empty
  # insert_all.
  defp flush_chunk([], _provider, _feed_key, _generation, _now), do: {0, 0}

  defp flush_chunk(chunk, provider, feed_key, generation, now) do
    # Advisories and their coordinates land atomically: a chunk that fails
    # halfway would otherwise leave advisories pointing at a partial coordinate
    # set, which the matcher would read as "this CVE affects nothing".
    {:ok, result} =
      Repo.transaction(fn -> flush_chunk_body(chunk, provider, feed_key, generation, now) end)

    result
  end

  defp flush_chunk_body(chunk, provider, feed_key, generation, now) do
    advisory_rows =
      chunk
      |> Enum.map(fn %{advisory: advisory} = record ->
        record
        |> content_hash()
        |> then(
          &Map.put(advisory_row(advisory, provider, feed_key, generation, now), :content_hash, &1)
        )
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
             :content_hash,
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

  # `:generation` is deliberately absent from the replace list below.
  # advisory_coordinates_generation_idx indexes that column, so replacing it
  # makes every upsert a non-HOT update that re-inserts all six indexes —
  # including the 416 MB GIN trigram on `value`. Production measured
  # n_tup_hot_upd = 0 against 155M n_tup_upd because of this one field. Leaving
  # it out lets a byte-identical coordinate take the HOT path. The column keeps
  # its insert-time value; nothing reads it as a liveness signal (see the
  # generation-swap note in the moduledoc).
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

  @doc "Stable SHA-256 hash of the advisory and coordinates persisted for a feed record."
  @spec content_hash(map()) :: String.t()
  def content_hash(%{advisory: advisory} = record) do
    coordinate_binaries =
      record
      |> Map.get(:coordinates, [])
      |> normalized_coordinate_tuples()
      |> Enum.map(&:erlang.term_to_binary(&1, [:deterministic]))
      |> Enum.sort()

    {normalized_advisory_tuple(advisory), coordinate_binaries}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalized_advisory_tuple(advisory) do
    @advisory_content_fields
    |> Enum.map(&normalized_advisory_value(advisory, &1))
    |> List.to_tuple()
  end

  defp normalized_advisory_value(advisory, field) when field in [:published_at, :modified_at],
    do: parse_datetime(fetch(advisory, field))

  defp normalized_advisory_value(advisory, field) when field in [:kev, :exploit_available],
    do: fetch(advisory, field) || false

  defp normalized_advisory_value(_advisory, :affected_coordinates), do: []

  defp normalized_advisory_value(advisory, field) when field in [:references, :raw, :metadata],
    do: fetch(advisory, field) || default_advisory_value(field)

  defp normalized_advisory_value(advisory, field), do: fetch(advisory, field)

  defp default_advisory_value(:references), do: []
  defp default_advisory_value(_field), do: %{}

  defp normalized_coordinate_tuples(coordinates) do
    coordinates
    |> Enum.map(&normalized_coordinate_tuple/1)
    |> Enum.reduce(%{}, fn tuple, acc -> Map.put(acc, coordinate_tuple_identity(tuple), tuple) end)
    |> Map.values()
  end

  defp normalized_coordinate_tuple(coordinate) do
    @coordinate_content_fields
    |> Enum.map(&normalized_coordinate_value(coordinate, &1))
    |> List.to_tuple()
  end

  defp normalized_coordinate_value(coordinate, :metadata), do: fetch(coordinate, :metadata) || %{}
  defp normalized_coordinate_value(coordinate, field), do: fetch(coordinate, field)

  defp coordinate_tuple_identity(tuple) do
    {elem(tuple, 0), elem(tuple, 1), elem(tuple, 6), elem(tuple, 8)}
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

  defp parse_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp parse_datetime(_), do: nil

  defp parse_naive(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end
end
