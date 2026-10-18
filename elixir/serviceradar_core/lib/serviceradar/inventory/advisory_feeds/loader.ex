defmodule ServiceRadar.Inventory.AdvisoryFeeds.Loader do
  @moduledoc """
  Chunked bulk loader for advisories, coordinates, package definitions, and
  assertions.

  Records arrive as `%{advisory: map, coordinates: [map], assertions: [map]}`
  with optional `products` and `product_sets` lists from a parser. This module
  accumulates bounded chunks (default 2,000 advisories or 16 MiB, whichever
  comes first; a single record larger than the byte cap commits alone in its own
  chunk, since splitting it would tear the advisory) and flushes them with
  `Repo.insert_all` upserts — never one Ash create per row.

  ## Skipping unchanged advisories

  A feed re-publishes its whole corpus every run, but only a handful of
  advisories actually change. The comparison is feed-specific: `cisa-kev` and
  `vulncheck-kev` use a stable SHA-256 hash of persisted advisory and coordinate
  content, while timestamp feeds compare `modified_at`, normalization version,
  and any projection digest. Matching records are dropped before they reach an
  `insert_all`. Legacy KEV rows without a hash are treated as changed and
  rewritten once to backfill it. This is the difference between rewriting
  ~360k advisories / ~2.5M coordinates every 6 hours and writing almost nothing:
  measured at ~5.9 TB of WAL per steady state before the guard worked.

  The guard is load-bearing, not an optimisation. `feed_worker` logs
  `advisories_skipped` and alarms when it is zero against a non-empty corpus,
  because a silently-inert guard looks exactly like a healthy run.

  ## Batched commits and generation swap

  Each chunk commits in its own transaction: its product definitions, changed
  advisory rows, and their complete coordinate, configuration, and assertion
  replacements. An advisory row and its children are always written together,
  so while a run is in progress the served corpus is a mix of old and new
  versions per advisory, never a torn advisory. A first full nist-nvd2 rewrite
  is therefore bounded by the chunk byte cap per transaction instead of being
  one ~1 GB transaction.

  A new advisory is written with `current = false`, and nothing current is
  withdrawn, until the whole run has loaded and validated. A run that fails or
  is incomplete leaves every previously current advisory current; a changed
  advisory it already committed keeps its new, self-consistent content, and its
  assertions carry the unpromoted generation.

  Every advisory row has a bigint `ordinal` from a sequence. The run records
  the ordinal of every source object it observes, written or skipped, in an
  in-memory `OrdinalSet`; nothing is written for an unchanged object.
  Finalization runs only after the observed count matches the validated
  snapshot count: it promotes the run's new rows and withdraws the feed's
  current rows whose ordinal was not observed, each in bounded batches that
  commit separately.

  `current` remains the matcher liveness bit. Skipped rows retain their content
  generation and timestamps.

  Advisories upsert on `(provider, feed_key, source_object_id)`; coordinates on
  the coordinate identity. An NVD advisory row stores each referenced
  configuration expression once (`nvd_configurations`) and its coordinates
  reference it by index, so a record's write volume stays linear in its
  coordinate count plus its configuration size.

  Bounded memory: only one chunk of rows is resident at a time, independent of
  total feed size.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.AdvisoryFeeds.NvdApplicability
  alias ServiceRadar.Inventory.AdvisoryFeeds.OrdinalSet
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
  @max_assertion_insert 500
  @max_product_insert 1_000
  @max_product_insert_bytes 4 * 1_024 * 1_024
  @max_product_set_insert 100
  @max_product_set_insert_bytes 16 * 1_024 * 1_024
  @max_assertion_lock_batch 1_000
  @default_chunk_bytes 16 * 1_024 * 1_024
  # Per chunk transaction. A chunk is bounded by row count and bytes, so this is
  # headroom for a slow disk, not a budget for a whole run.
  @default_transaction_timeout_ms 600_000
  @finalize_batch_size 1_000
  @default_finalize_timeout_ms 600_000
  @current_ordinal_page_size 10_000
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
          assertions_upserted: non_neg_integer(),
          products_upserted: non_neg_integer(),
          product_sets_upserted: non_neg_integer(),
          advisories_skipped: non_neg_integer(),
          source_objects_seen: non_neg_integer(),
          parse_errors: non_neg_integer(),
          read_errors: non_neg_integer(),
          generation: integer()
        }

  @doc """
  Allocate a globally monotonic generation (and therefore monotonic per feed).
  """
  @spec next_generation(String.t(), String.t()) :: integer()
  def next_generation(_provider, _feed_key) do
    %{rows: [[generation]]} =
      Repo.query!("SELECT nextval('platform.advisory_feed_generation_seq')")

    generation
  end

  @doc """
  Load one feed run and promote it when it validates.

  `records` is an enumerable of the complete loader record contract.
  Records matching the feed-specific stored comparison state are skipped
  entirely. A KEV row with no stored hash is rewritten once to backfill it.
  See the "Skipping unchanged advisories" note above.

  Each chunk commits on its own (see "Batched commits and generation swap").
  The run is promoted only when `:completeness` validates before the load and
  the number of distinct advisories the load observed equals its
  `source_objects_seen`. Otherwise nothing is promoted or withdrawn.

  Options: `:provider`, `:feed_key`, `:completeness` (required), `:generation`,
  `:chunk_size`, `:chunk_bytes`, `:now`, `:existing_state`,
  `:existing_comparison_state`, `:existing_modified`, `:normalization_version`,
  `:transaction_timeout_ms` (each chunk transaction), and `:timeout_ms` (each
  finalization statement).

  Existing state precedence is `:existing_state`,
  `:existing_comparison_state`, `:existing_modified`, then the database.
  """
  @spec load_and_finalize(Enumerable.t(), keyword()) :: {:ok, load_result()} | {:error, term()}
  def load_and_finalize(records, opts) do
    completeness = Keyword.fetch!(opts, :completeness)

    with :ok <- validate_completeness(completeness),
         {result, seen} = load_chunks(records, opts, completeness),
         :ok <- validate_seen_count(completeness, OrdinalSet.size(seen)) do
      :ok = finalize_generation(opts, result.generation, seen)

      {:ok,
       Map.merge(result, %{
         source_objects_seen: OrdinalSet.size(seen),
         complete_generation_at: DateTime.utc_now(),
         validation: get(completeness, :validation),
         complete_snapshot?: true
       })}
    end
  end

  @doc "Validate the explicit structural and error-count evidence for a complete snapshot."
  @spec validate_completeness(map()) :: :ok | {:error, {:incomplete_snapshot, [term()]}}
  def validate_completeness(completeness) when is_map(completeness) do
    seen = get(completeness, :source_objects_seen)
    minimum = get(completeness, :expected_minimum)
    required = get(completeness, :required_trees)
    validation = get(completeness, :validation)
    minimum_reason = below_expected_minimum_reason(completeness, seen, minimum)

    reasons =
      []
      |> require_reason(get(completeness, :complete_snapshot?) == true, :not_complete)
      |> require_reason(is_integer(seen) and seen > 0, :empty_snapshot)
      |> require_reason(
        is_integer(minimum) and minimum > 0 and is_integer(seen) and seen >= minimum,
        minimum_reason
      )
      |> require_reason(get(completeness, :parse_errors) == 0, :parse_errors)
      |> require_reason(get(completeness, :read_errors) == 0, :read_errors)
      |> require_reason(is_list(required) and required != [], :missing_required_trees)
      |> validate_required_trees(required, validation)
      |> Enum.reverse()

    case reasons do
      [] -> :ok
      reasons -> {:error, {:incomplete_snapshot, reasons}}
    end
  end

  def validate_completeness(_), do: {:error, {:incomplete_snapshot, [:missing_completeness]}}

  defp below_expected_minimum_reason(completeness, seen, minimum) do
    case get(completeness, :retained_count_floor) do
      floor when is_map(floor) ->
        {:below_expected_minimum,
         floor
         |> Map.put("observed_count", seen)
         |> Map.put("minimum_count", minimum)}

      _ ->
        :below_expected_minimum
    end
  end

  # Distinct advisories, not records: a source object repeated in the stream
  # resolves to one ordinal and cannot satisfy the claimed snapshot count twice.
  defp validate_seen_count(completeness, observed) do
    expected = get(completeness, :source_objects_seen)

    if observed == expected do
      :ok
    else
      {:error, {:source_count_changed, expected: expected, observed: observed}}
    end
  end

  defp load_chunks(records, opts, completeness) do
    provider = Keyword.fetch!(opts, :provider)
    feed_key = Keyword.fetch!(opts, :feed_key)

    generation =
      Keyword.get_lazy(opts, :generation, fn -> next_generation(provider, feed_key) end)

    context = %{
      provider: provider,
      feed_key: feed_key,
      generation: generation,
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      existing_state: existing_state(opts, provider, feed_key),
      comparison: comparison_for_feed(feed_key),
      normalization_version: Keyword.get(opts, :normalization_version),
      transaction_timeout_ms:
        Keyword.get(opts, :transaction_timeout_ms, @default_transaction_timeout_ms)
    }

    init = %{
      advisories_upserted: 0,
      coordinates_upserted: 0,
      assertions_upserted: 0,
      products_upserted: 0,
      product_sets_upserted: 0,
      advisories_skipped: 0,
      source_objects_seen: 0,
      parse_errors: get(completeness, :parse_errors),
      read_errors: get(completeness, :read_errors),
      generation: generation
    }

    records
    |> chunk_records(opts)
    |> Enum.reduce({init, OrdinalSet.new()}, fn chunk, {acc, seen} ->
      load_chunk(chunk, context, acc, seen)
    end)
  end

  defp load_chunk(chunk, context, acc, seen) do
    Enum.each(chunk, &validate_record!/1)

    {skipped, changed} = classify_chunk(chunk, context)

    {adv, coord, assertions, products, product_sets, written_ordinals} =
      flush_chunk(chunk, changed, context)

    seen =
      seen
      |> OrdinalSet.put_all(Enum.map(skipped, &elem(&1, 1)))
      |> OrdinalSet.put_all(written_ordinals)

    acc = %{
      acc
      | advisories_upserted: acc.advisories_upserted + adv,
        coordinates_upserted: acc.coordinates_upserted + coord,
        assertions_upserted: acc.assertions_upserted + assertions,
        products_upserted: acc.products_upserted + products,
        product_sets_upserted: acc.product_sets_upserted + product_sets,
        advisories_skipped: acc.advisories_skipped + length(skipped),
        source_objects_seen: acc.source_objects_seen + length(chunk)
    }

    {acc, seen}
  end

  # Splits a chunk into `{record, ordinal}` pairs that are skipped and records
  # that are written. A skipped record still has to be observed, so it needs the
  # ordinal of its current row. State read by `existing_comparison_state/2`
  # carries it; for state that does not (a caller-supplied map), the ordinal is
  # read from the current row. A record that matches the comparison state but
  # has no current numbered row is written, which numbers it (see
  # `number_unnumbered/1`): skipping it would leave it unobserved.
  defp classify_chunk(chunk, context) do
    classified =
      Enum.map(chunk, fn record ->
        unchanged? =
          unchanged_advisory?(record, context.existing_state,
            comparison: context.comparison,
            normalization_version: context.normalization_version
          )

        {record, unchanged?}
      end)

    {stated, unstated} =
      for {%{advisory: advisory}, true} <- classified, reduce: {%{}, []} do
        {stated, unstated} ->
          source_object_id = fetch(advisory, :source_object_id)

          case state_ordinal(context.existing_state, source_object_id) do
            nil -> {stated, [source_object_id | unstated]}
            ordinal -> {Map.put(stated, source_object_id, ordinal), unstated}
          end
      end

    ordinals =
      unstated
      |> current_ordinals(context.provider, context.feed_key)
      |> Map.merge(stated)

    Enum.reduce(Enum.reverse(classified), {[], []}, fn
      {%{advisory: advisory} = record, true}, {skipped, changed} ->
        case Map.fetch(ordinals, fetch(advisory, :source_object_id)) do
          {:ok, ordinal} -> {[{record, ordinal} | skipped], changed}
          :error -> {skipped, [record | changed]}
        end

      {record, false}, {skipped, changed} ->
        {skipped, [record | changed]}
    end)
  end

  defp state_ordinal(state, source_object_id) do
    case Map.fetch(state, source_object_id) do
      {:ok, %{ordinal: ordinal}} when is_integer(ordinal) -> ordinal
      _ -> nil
    end
  end

  defp current_ordinals([], _provider, _feed_key), do: %{}

  defp current_ordinals(source_object_ids, provider, feed_key) do
    from(a in "vulnerability_advisories",
      where:
        a.provider == ^provider and a.feed_key == ^feed_key and a.current == true and
          not is_nil(a.ordinal) and a.source_object_id in ^source_object_ids,
      select: {a.source_object_id, a.ordinal}
    )
    |> Repo.all(prefix: @schema)
    |> Map.new()
  end

  @doc false
  @spec default_chunk_bytes() :: pos_integer()
  def default_chunk_bytes, do: @default_chunk_bytes

  @doc false
  @spec chunk_records(Enumerable.t(), keyword()) :: Enumerable.t()
  def chunk_records(records, opts \\ []) do
    chunk_by_serialized_size(
      records,
      Keyword.get(opts, :chunk_size, @default_chunk_size),
      Keyword.get(opts, :chunk_bytes, @default_chunk_bytes)
    )
  end

  defp require_reason(reasons, true, _reason), do: reasons
  defp require_reason(reasons, false, reason), do: [reason | reasons]

  defp validate_required_trees(reasons, required, validation)
       when is_list(required) and is_map(validation) do
    Enum.reduce(required, reasons, fn tree, acc ->
      tree_result = Map.get(validation, tree) || Map.get(validation, to_string(tree))

      valid? =
        is_map(tree_result) and get(tree_result, :complete) == true and
          is_integer(get(tree_result, :count)) and get(tree_result, :count) > 0

      require_reason(acc, valid?, {:invalid_required_tree, tree})
    end)
  end

  defp validate_required_trees(reasons, _required, _validation),
    do: [{:invalid_validation, :not_a_map} | reasons]

  defp validate_record!(record) do
    valid? =
      is_map(record) and is_map(Map.get(record, :advisory)) and
        Map.has_key?(record, :coordinates) and is_list(Map.get(record, :coordinates)) and
        Map.has_key?(record, :assertions) and is_list(Map.get(record, :assertions)) and
        is_list(Map.get(record, :products, [])) and
        is_list(Map.get(record, :product_sets, []))

    if !valid? do
      raise ArgumentError,
            "loader record contract requires %{advisory: map, coordinates: [map], assertions: [map], optional products: [map], optional product_sets: [map]}"
    end
  end

  @doc """
  Map of
  `source_object_id => %{modified_at:, content_hash:, normalization_version:, projection_digest:, ordinal:}`
  for the feed's live advisories. The ordinal lets a skipped record be observed
  without another read.

  Scoped to `current == true` on purpose: a row that is not current is either
  half-written by an aborted run or already demoted, and must be rewritten
  rather than skipped.
  """
  @spec existing_comparison_state(String.t(), String.t()) :: %{
          optional(String.t()) => %{
            modified_at: DateTime.t() | nil,
            content_hash: String.t() | nil,
            normalization_version: integer() | nil,
            projection_digest: String.t() | nil,
            ordinal: pos_integer() | nil
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
          {a.source_object_id, type(a.modified_at, :utc_datetime_usec), a.content_hash,
           a.metadata, a.ordinal}
      )

    query
    |> Repo.all(prefix: @schema)
    |> Map.new(fn {source_object_id, modified_at, content_hash, metadata, ordinal} ->
      {source_object_id,
       %{
         modified_at: modified_at,
         content_hash: content_hash,
         normalization_version: metadata_normalization_version(metadata),
         projection_digest: metadata_projection_digest(metadata),
         ordinal: ordinal
       }}
    end)
  end

  @doc "Compatibility alias for callers using the distro-aware state name."
  @spec existing_advisory_state(String.t(), String.t()) :: %{
          optional(String.t()) => %{
            modified_at: DateTime.t() | nil,
            content_hash: String.t() | nil,
            normalization_version: integer() | nil,
            projection_digest: String.t() | nil,
            ordinal: pos_integer() | nil
          }
        }
  def existing_advisory_state(provider, feed_key),
    do: existing_comparison_state(provider, feed_key)

  @doc "Map of live advisory source IDs to `modified_at` values."
  @spec existing_modified_at(String.t(), String.t()) :: %{
          optional(String.t()) => DateTime.t() | nil
        }
  def existing_modified_at(provider, feed_key) do
    provider
    |> existing_comparison_state(feed_key)
    |> Map.new(fn {source_object_id, state} -> {source_object_id, state.modified_at} end)
  end

  @doc "True when the default timestamp comparison matches the incoming record."
  @spec unchanged_advisory?(map(), map()) :: boolean()
  def unchanged_advisory?(%{advisory: advisory} = record, existing_state) do
    unchanged_advisory?(
      record,
      existing_state,
      comparison: :modified_at,
      normalization_version: metadata_normalization_version(fetch(advisory, :metadata))
    )
  end

  def unchanged_advisory?(_record, _existing_state), do: false

  @spec unchanged_advisory?(map(), map(), integer() | nil | keyword()) :: boolean()
  def unchanged_advisory?(record, existing_state, normalization_version)
      when is_integer(normalization_version) or is_nil(normalization_version) do
    unchanged_advisory?(record, existing_state,
      comparison: :modified_at,
      normalization_version: normalization_version
    )
  end

  def unchanged_advisory?(%{advisory: advisory} = record, existing_state, opts)
      when is_list(opts) do
    source_object_id = fetch(advisory, :source_object_id)
    state = normalize_existing_state(existing_state)

    case {Keyword.get(opts, :comparison, :modified_at), Map.fetch(state, source_object_id)} do
      {:content_hash, {:ok, %{content_hash: stored_hash}}} when is_binary(stored_hash) ->
        stored_hash == content_hash(record)

      {:modified_at, {:ok, stored}} ->
        same_timestamp_state?(advisory, stored, Keyword.get(opts, :normalization_version))

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

    existing_state
    |> normalize_existing_state()
    |> Enum.count(fn {_source_object_id, state} ->
      not is_nil(Map.get(state, state_key))
    end)
  end

  defp comparison_for_feed(feed_key) do
    if MapSet.member?(@content_hash_feeds, feed_key), do: :content_hash, else: :modified_at
  end

  defp same_timestamp_state?(advisory, stored, normalization_version) do
    same_modified?(
      Map.get(stored, :modified_at),
      parse_datetime(fetch(advisory, :modified_at))
    ) and
      Map.get(stored, :normalization_version) == normalization_version and
      same_projection?(
        Map.get(stored, :projection_digest),
        advisory |> fetch(:metadata) |> metadata_projection_digest()
      )
  end

  defp existing_state(opts, provider, feed_key) do
    case existing_state_from_options(opts) do
      {:ok, state} -> state
      :error -> existing_comparison_state(provider, feed_key)
    end
  end

  @doc false
  @spec existing_state_from_options(keyword()) :: {:ok, map()} | :error
  def existing_state_from_options(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :existing_state) ->
        {:ok, opts |> Keyword.fetch!(:existing_state) |> normalize_existing_state()}

      Keyword.has_key?(opts, :existing_comparison_state) ->
        {:ok, opts |> Keyword.fetch!(:existing_comparison_state) |> normalize_existing_state()}

      Keyword.has_key?(opts, :existing_modified) ->
        {:ok, opts |> Keyword.fetch!(:existing_modified) |> normalize_existing_state()}

      true ->
        :error
    end
  end

  defp normalize_existing_state(state) when is_map(state) do
    Map.new(state, fn {source_object_id, value} ->
      {source_object_id, normalize_state_entry(value)}
    end)
  end

  defp normalize_existing_state(_state), do: %{}

  defp normalize_state_entry(%DateTime{} = modified_at), do: timestamp_state(modified_at)
  defp normalize_state_entry(%NaiveDateTime{} = modified_at), do: timestamp_state(modified_at)

  defp normalize_state_entry(value) when is_map(value) do
    %{
      modified_at: get(value, :modified_at),
      content_hash: get(value, :content_hash),
      normalization_version: get(value, :normalization_version),
      projection_digest: get(value, :projection_digest),
      ordinal: get(value, :ordinal)
    }
  end

  defp normalize_state_entry(modified_at), do: timestamp_state(modified_at)

  defp timestamp_state(modified_at) do
    %{
      modified_at: modified_at,
      content_hash: nil,
      normalization_version: nil,
      projection_digest: nil,
      ordinal: nil
    }
  end

  defp metadata_normalization_version(metadata) when is_map(metadata) do
    case Map.get(metadata, "normalization_version") || Map.get(metadata, :normalization_version) do
      version when is_integer(version) -> version
      _ -> nil
    end
  end

  defp metadata_normalization_version(_metadata), do: nil

  defp metadata_projection_digest(metadata) when is_map(metadata) do
    case Map.get(metadata, "projection_digest") || Map.get(metadata, :projection_digest) do
      digest when is_binary(digest) and digest != "" -> digest
      _ -> nil
    end
  end

  defp metadata_projection_digest(_metadata), do: nil

  # Legacy feeds have no projection digest and retain timestamp/version skip
  # semantics. A projected feed that supplies one must match it exactly: an
  # unchanged upstream timestamp does not prove its normalized content is the
  # same after a projector or source correction.
  defp same_projection?(nil, nil), do: true
  defp same_projection?(existing, incoming), do: existing == incoming

  @doc false
  @spec chunk_by_serialized_size(Enumerable.t(), pos_integer(), pos_integer()) :: Enumerable.t()
  def chunk_by_serialized_size(records, max_rows, max_bytes)
      when is_integer(max_rows) and max_rows > 0 and is_integer(max_bytes) and max_bytes > 0 do
    Stream.chunk_while(
      records,
      {[], 0, 0},
      fn record, {rows, row_count, byte_count} ->
        record_bytes = :erlang.external_size(record)

        if rows != [] and (row_count >= max_rows or byte_count + record_bytes > max_bytes) do
          {:cont, Enum.reverse(rows), {[record], 1, record_bytes}}
        else
          {:cont, {[record | rows], row_count + 1, byte_count + record_bytes}}
        end
      end,
      fn
        {[], _row_count, _byte_count} -> {:cont, []}
        {rows, _row_count, _byte_count} -> {:cont, Enum.reverse(rows), {[], 0, 0}}
      end
    )
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

  # Runs only after the load validated. Each batch commits on its own: a
  # promoted or withdrawn advisory is whole either way, and a batch that fails
  # leaves the next run to finish the job (unpromoted rows are not current, so
  # they are rewritten; withdrawal is recomputed from current rows).
  defp finalize_generation(opts, generation, seen) do
    provider = Keyword.fetch!(opts, :provider)
    feed_key = Keyword.fetch!(opts, :feed_key)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_finalize_timeout_ms)

    promote_generation(provider, feed_key, generation, timeout_ms)
    withdraw_unnumbered(provider, feed_key, generation, timeout_ms)

    provider
    |> unobserved_current_ordinals(feed_key, seen)
    |> Enum.chunk_every(@finalize_batch_size)
    |> Enum.each(&withdraw_batch(&1, provider, feed_key, generation, timeout_ms))
  end

  defp promote_generation(provider, feed_key, generation, timeout_ms) do
    %{num_rows: promoted} =
      bounded_statement(
        """
        UPDATE platform.vulnerability_advisories
        SET current = TRUE
        WHERE id IN (
          SELECT id
          FROM platform.vulnerability_advisories
          WHERE provider = $1
            AND feed_key = $2
            AND generation = $3
            AND current = FALSE
          LIMIT $4
        )
        """,
        [provider, feed_key, generation, @finalize_batch_size],
        timeout_ms
      )

    if promoted > 0 do
      promote_generation(provider, feed_key, generation, timeout_ms)
    else
      :ok
    end
  end

  # The withdrawal set is computed in full before any of it is applied. Current
  # ordinals are read in keyset pages so neither side holds the corpus as rows.
  defp unobserved_current_ordinals(provider, feed_key, seen) do
    0
    |> Stream.unfold(fn
      :done ->
        nil

      after_ordinal ->
        page =
          Repo.all(
            from(a in "vulnerability_advisories",
              where:
                a.provider == ^provider and a.feed_key == ^feed_key and a.current == true and
                  a.ordinal > ^after_ordinal,
              order_by: a.ordinal,
              limit: ^@current_ordinal_page_size,
              select: a.ordinal
            ),
            prefix: @schema
          )

        next = if length(page) < @current_ordinal_page_size, do: :done, else: List.last(page)
        {Enum.reject(page, &OrdinalSet.member?(seen, &1)), next}
    end)
    |> Enum.concat()
  end

  # A current row still without an ordinal was not observed: every row a run
  # observes is numbered (skipped rows already were, written rows are numbered
  # by `number_unnumbered/1`). Such rows exist only until the backfill migration
  # completes; the unique ordinal index answers this probe once it does.
  defp withdraw_unnumbered(provider, feed_key, generation, timeout_ms) do
    %{num_rows: withdrawn} =
      bounded_statement(
        """
        UPDATE platform.vulnerability_advisories
        SET current = FALSE
        WHERE id IN (
          SELECT id
          FROM platform.vulnerability_advisories
          WHERE provider = $1
            AND feed_key = $2
            AND ordinal IS NULL
            AND current = TRUE
            AND generation <> $3
          LIMIT $4
        )
        """,
        [provider, feed_key, generation, @finalize_batch_size],
        timeout_ms
      )

    if withdrawn > 0 do
      withdraw_unnumbered(provider, feed_key, generation, timeout_ms)
    else
      :ok
    end
  end

  # `generation <> $4` never withdraws a row this run wrote.
  defp withdraw_batch(ordinals, provider, feed_key, generation, timeout_ms) do
    bounded_statement(
      """
      UPDATE platform.vulnerability_advisories
      SET current = FALSE
      WHERE provider = $1
        AND feed_key = $2
        AND ordinal = ANY($3::bigint[])
        AND current = TRUE
        AND generation <> $4
      """,
      [provider, feed_key, ordinals, generation],
      timeout_ms
    )
  end

  defp bounded_statement(sql, params, timeout_ms) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
            Integer.to_string(timeout_ms)
          ])

          Repo.query!(sql, params, timeout: timeout_ms)
        end,
        timeout: timeout_ms
      )

    result
  end

  @doc "Delete advisories (cascade coordinates) older than the kept generation."
  @spec reap_old_generations(String.t(), String.t(), integer()) :: :ok
  def reap_old_generations(provider, feed_key, current_generation) do
    keep = current_generation - 1

    # Bind archive and delete to one locked set in one statement. Re-evaluating
    # the dynamic `current = FALSE` predicate in a later DELETE can otherwise
    # include an advisory demoted after the history copy and cascade-delete its
    # assertions without provenance.
    %{rows: [[count]]} =
      Repo.query!(
        """
        WITH reaped AS MATERIALIZED (
          SELECT advisory.id
          FROM platform.vulnerability_advisories AS advisory
          WHERE advisory.provider = $1
            AND advisory.feed_key = $2
            AND advisory.generation < $3
            AND advisory.current = FALSE
          ORDER BY advisory.id
          FOR UPDATE
        ), archived AS (
          INSERT INTO platform.advisory_package_assertion_history (
            assertion_key,
            advisory_ref,
            provider,
            feed_key,
            generation,
            cve_id,
            authority,
            source_kind,
            source_timestamp,
            disposition,
            statement_fingerprint,
            snapshot,
            recorded_at
          )
          SELECT
            assertion.assertion_key,
            assertion.advisory_ref,
            assertion.provider,
            assertion.feed_key,
            assertion.generation,
            assertion.cve_id,
            assertion.authority,
            assertion.source_kind,
            assertion.source_timestamp,
            assertion.disposition,
            assertion.statement_fingerprint,
            #{assertion_snapshot_sql()},
            assertion.updated_at
          FROM platform.advisory_package_assertions AS assertion
          INNER JOIN reaped ON reaped.id = assertion.advisory_ref
          ON CONFLICT (assertion_key, generation, content_sha256) DO NOTHING
          RETURNING 1
        ), archive_barrier AS (
          SELECT count(*) AS archived_count FROM archived
        ), deleted AS (
          DELETE FROM platform.vulnerability_advisories AS advisory
          USING reaped, archive_barrier
          WHERE advisory.id = reaped.id
          RETURNING advisory.id
        )
        SELECT count(*)::bigint FROM deleted
        """,
        [provider, feed_key, keep]
      )

    if count > 0,
      do: Logger.warning("advisory_feeds: reaping #{count} demoted #{feed_key} advisories")

    :ok
  end

  # One transaction per chunk, never one per run: an advisory row commits with
  # its complete coordinate, configuration, and assertion replacement, and the
  # product definitions its assertions reference.
  defp flush_chunk(all_records, changed, context) do
    %{provider: provider, feed_key: feed_key, generation: generation, now: now} = context

    {:ok, result} =
      Repo.transaction(
        fn ->
          {products_upserted, product_sets_upserted} =
            insert_product_definitions(all_records, now)

          {advisories_upserted, coordinates_upserted, assertions_upserted, ordinals} =
            flush_chunk_body(changed, provider, feed_key, generation, now)

          {
            advisories_upserted,
            coordinates_upserted,
            assertions_upserted,
            products_upserted,
            product_sets_upserted,
            ordinals
          }
        end,
        timeout: context.transaction_timeout_ms
      )

    result
  end

  defp flush_chunk_body([], _provider, _feed_key, _generation, _now), do: {0, 0, 0, []}

  defp flush_chunk_body(chunk, provider, feed_key, generation, now) do
    hash_content? = comparison_for_feed(feed_key) == :content_hash

    advisory_rows =
      chunk
      |> Enum.map(fn %{advisory: advisory} = record ->
        Map.put(
          advisory_row(advisory, provider, feed_key, generation, now),
          :content_hash,
          if(hash_content?, do: content_hash(record))
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
             :nvd_configurations,
             :updated_at
           ]},
        conflict_target: [:provider, :feed_key, :source_object_id],
        returning: [:id, :source_object_id, :ordinal]
      )

    id_by_source =
      Map.new(returned, fn row -> {row.source_object_id, row.id} end)

    advisory_refs = Map.values(id_by_source)

    if advisory_refs != [] do
      Repo.delete_all(
        from(c in "advisory_coordinates", where: c.advisory_ref in ^advisory_refs),
        prefix: @schema
      )
    end

    # Coordinates come from the same record whose advisory row won the dedupe:
    # NVD coordinates reference configurations stored on that advisory row, so
    # a losing duplicate's coordinates would reference configurations that were
    # never written.
    coordinate_rows =
      chunk
      |> last_record_per_source()
      |> Enum.flat_map(fn %{advisory: advisory} = record ->
        source_object_id = fetch(advisory, :source_object_id)

        case Map.get(id_by_source, source_object_id) do
          nil ->
            []

          advisory_ref ->
            record
            |> Map.fetch!(:coordinates)
            |> Enum.map(&coordinate_row(&1, advisory_ref, provider, feed_key, generation, now))
        end
      end)

    coordinates_upserted = insert_coordinates(coordinate_rows)

    assertion_rows =
      Enum.flat_map(chunk, fn %{advisory: advisory} = record ->
        source_object_id = fetch(advisory, :source_object_id)

        case Map.get(id_by_source, source_object_id) do
          nil ->
            []

          advisory_ref ->
            record
            |> Map.fetch!(:assertions)
            |> Enum.map(&assertion_row(&1, advisory_ref, provider, feed_key, generation, now))
        end
      end)

    archive_stored_assertions(advisory_refs)
    archive_assertions(assertion_rows)
    assertions_upserted = insert_assertions(assertion_rows)

    reap_stale_assertions(advisory_refs, generation)

    {length(advisory_rows), coordinates_upserted, assertions_upserted,
     number_unnumbered(returned)}
  end

  # A row that predates the ordinal column keeps a NULL ordinal until the
  # backfill migration numbers it, and an upsert never assigns the column
  # default to an existing row. Number such a row here, in its chunk's
  # transaction, so every written advisory is observed.
  defp number_unnumbered(returned) do
    {numbered, unnumbered} = Enum.split_with(returned, &is_integer(&1.ordinal))

    assigned =
      case Enum.map(unnumbered, & &1.id) do
        [] ->
          []

        ids ->
          %{rows: rows} =
            Repo.query!(
              """
              UPDATE platform.vulnerability_advisories
              SET ordinal = COALESCE(ordinal, nextval('platform.vulnerability_advisories_ordinal_seq'))
              WHERE id = ANY($1::uuid[])
              RETURNING ordinal
              """,
              [ids]
            )

          Enum.map(rows, &hd/1)
      end

    Enum.map(numbered, & &1.ordinal) ++ assigned
  end

  # History is deliberately append-only and separate from the authoritative
  # current assertion table. This preserves superseded distro statements for
  # provenance without allowing them to participate in matcher reads.
  defp archive_assertions(rows) do
    rows
    |> Enum.map(&assertion_history_row/1)
    |> Enum.chunk_every(@max_assertion_insert)
    |> Enum.each(fn batch ->
      Repo.insert_all("advisory_package_assertion_history", batch,
        prefix: @schema,
        on_conflict: :nothing,
        conflict_target: [:assertion_key, :generation, :content_sha256],
        returning: false
      )
    end)

    :ok
  end

  defp archive_stored_assertions([]), do: :ok

  defp archive_stored_assertions(advisory_refs) do
    # A changed advisory may shrink from a historically enormous product set to
    # one small incoming row. Archive the old side in Postgres so loader memory
    # remains bounded by the incoming chunk, not by prior corpus size.
    Repo.query!(
      """
      INSERT INTO platform.advisory_package_assertion_history (
        assertion_key,
        advisory_ref,
        provider,
        feed_key,
        generation,
        cve_id,
        authority,
        source_kind,
        source_timestamp,
        disposition,
        statement_fingerprint,
        snapshot,
        recorded_at
      )
      SELECT
        assertion.assertion_key,
        assertion.advisory_ref,
        assertion.provider,
        assertion.feed_key,
        assertion.generation,
        assertion.cve_id,
        assertion.authority,
        assertion.source_kind,
        assertion.source_timestamp,
        assertion.disposition,
        assertion.statement_fingerprint,
        #{assertion_snapshot_sql()},
        assertion.updated_at
      FROM platform.advisory_package_assertions AS assertion
      WHERE assertion.advisory_ref = ANY($1::uuid[])
      ON CONFLICT (assertion_key, generation, content_sha256) DO NOTHING
      """,
      [advisory_refs]
    )

    :ok
  end

  defp assertion_snapshot_sql do
    """
    jsonb_build_object(
      'assertion_key', assertion.assertion_key,
      'advisory_ref', assertion.advisory_ref,
      'provider', assertion.provider,
      'feed_key', assertion.feed_key,
      'generation', assertion.generation,
      'cve_id', assertion.cve_id,
      'authority', assertion.authority,
      'source_kind', assertion.source_kind,
      'source_timestamp', CASE
        WHEN assertion.source_timestamp IS NULL THEN NULL
        ELSE to_char(assertion.source_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
      END,
      'assertion_shape', assertion.assertion_shape,
      'product_set_ref', assertion.product_set_ref,
      'statement_fingerprint', assertion.statement_fingerprint,
      'package_type', assertion.package_type,
      'namespace', assertion.namespace,
      'release', assertion.release,
      'release_channel', assertion.release_channel,
      'product_scope', assertion.product_scope,
      'source_package', assertion.source_package,
      'binary_package', assertion.binary_package,
      'architecture', assertion.architecture,
      'version_scheme', assertion.version_scheme,
      'disposition', assertion.disposition,
      'introduced_version', assertion.introduced_version,
      'fixed_version', assertion.fixed_version,
      'affected_versions', assertion.affected_versions,
      'package_purl', assertion.package_purl,
      'justification', assertion.justification,
      'status_text', assertion.status_text,
      'action_text', assertion.action_text,
      'validation', assertion.validation,
      'raw', assertion.raw,
      'metadata', assertion.metadata,
      'inserted_at', to_char(assertion.inserted_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'updated_at', to_char(assertion.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
    """
  end

  defp assertion_history_row(row) do
    snapshot =
      row
      |> Map.update!(:advisory_ref, &json_safe_uuid/1)
      |> Map.update!(:product_set_ref, &json_safe_uuid/1)
      |> json_safe_assertion_snapshot()

    %{
      assertion_key: row.assertion_key,
      advisory_ref: row.advisory_ref,
      provider: row.provider,
      feed_key: row.feed_key,
      generation: row.generation,
      cve_id: row.cve_id,
      authority: row.authority,
      source_kind: row.source_kind,
      source_timestamp: row.source_timestamp,
      disposition: row.disposition,
      statement_fingerprint: row.statement_fingerprint,
      snapshot: snapshot,
      recorded_at: row.updated_at
    }
  end

  defp json_safe_assertion_snapshot(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Map.update!(:microsecond, fn {microsecond, _precision} -> {microsecond, 6} end)
    |> DateTime.to_iso8601()
  end

  defp json_safe_assertion_snapshot(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> json_safe_assertion_snapshot()

  defp json_safe_assertion_snapshot(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, json_safe_assertion_snapshot(item)} end)
  end

  defp json_safe_assertion_snapshot(value) when is_list(value),
    do: Enum.map(value, &json_safe_assertion_snapshot/1)

  defp json_safe_assertion_snapshot(value), do: value

  defp json_safe_uuid(<<_::128>> = uuid), do: load_uuid!(uuid)
  defp json_safe_uuid(uuid), do: uuid

  defp insert_product_definitions(records, now) do
    product_rows =
      records
      |> Enum.flat_map(&Map.get(&1, :products, []))
      |> Enum.map(&product_row(&1, now))
      |> dedupe_immutable_rows!(:product)

    product_set_rows =
      records
      |> Enum.flat_map(&Map.get(&1, :product_sets, []))
      |> Enum.map(&product_set_row(&1, now))
      |> dedupe_immutable_rows!(:product_set)

    products_upserted = insert_products(product_rows)
    product_sets_upserted = insert_product_sets(product_set_rows)

    {products_upserted, product_sets_upserted}
  end

  defp insert_products([]), do: 0

  defp insert_products(rows) do
    stored = stored_products(rows)
    validate_immutable_collisions!(rows, stored, :product)

    existing_ids = MapSet.new(stored, & &1.id)

    parent_ids =
      rows
      |> Enum.map(& &1.parent_product_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    available_ids = MapSet.union(existing_ids, fetch_product_ids(parent_ids))

    pending = Enum.reject(rows, &MapSet.member?(existing_ids, &1.id))

    inserted = insert_products_topologically(pending, available_ids, 0)
    validate_persisted_digests!(rows, stored_products(rows), :product)
    inserted
  end

  defp insert_products_topologically([], _available_ids, inserted), do: inserted

  defp insert_products_topologically(pending, available_ids, inserted) do
    pending_ids = MapSet.new(pending, & &1.id)

    missing_parent_ids =
      pending
      |> Enum.map(& &1.parent_product_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&MapSet.member?(available_ids, &1))
      |> Enum.reject(&MapSet.member?(pending_ids, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if missing_parent_ids != [] do
      raise ArgumentError,
            "missing parent product(s): #{Enum.join(missing_parent_ids, ", ")}"
    end

    {ready, waiting} =
      Enum.split_with(pending, fn row ->
        is_nil(row.parent_product_id) or MapSet.member?(available_ids, row.parent_product_id)
      end)

    if ready == [] do
      cycle_ids = waiting |> Enum.map(& &1.id) |> Enum.sort()
      raise ArgumentError, "cyclic parent products: #{Enum.join(cycle_ids, ", ")}"
    end

    {count, ready_ids} =
      ready
      |> Enum.sort_by(& &1.id)
      |> chunk_by_serialized_size(@max_product_insert, @max_product_insert_bytes)
      |> Enum.reduce({0, []}, fn batch, {count, ids} ->
        database_batch = Enum.map(batch, &dump_product_uuids!/1)

        {inserted_count, _} =
          Repo.insert_all("advisory_products", database_batch,
            prefix: @schema,
            on_conflict: :nothing,
            conflict_target: [:id],
            returning: false
          )

        {count + inserted_count, Enum.map(batch, & &1.id) ++ ids}
      end)

    insert_products_topologically(
      waiting,
      Enum.reduce(ready_ids, available_ids, &MapSet.put(&2, &1)),
      inserted + count
    )
  end

  defp insert_product_sets([]), do: 0

  defp insert_product_sets(rows) do
    member_ids = rows |> Enum.flat_map(& &1.product_ids) |> Enum.uniq()
    ensure_ids_exist!(member_ids, fetch_product_ids(member_ids), "product")

    stored = stored_product_sets(rows)
    validate_immutable_collisions!(rows, stored, :product_set)
    existing_ids = MapSet.new(stored, & &1.id)

    inserted =
      rows
      |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
      |> Enum.sort_by(& &1.id)
      |> chunk_by_serialized_size(@max_product_set_insert, @max_product_set_insert_bytes)
      |> Enum.reduce(0, fn batch, count ->
        database_batch = Enum.map(batch, &dump_product_set_uuids!/1)

        {inserted_count, _} =
          Repo.insert_all("advisory_product_sets", database_batch,
            prefix: @schema,
            on_conflict: :nothing,
            conflict_target: [:id],
            returning: false
          )

        count + inserted_count
      end)

    validate_persisted_digests!(rows, stored_product_sets(rows), :product_set)
    inserted
  end

  defp dedupe_immutable_rows!(rows, kind) do
    {by_id, _by_digest} =
      Enum.reduce(rows, {%{}, %{}}, fn row, {by_id, by_digest} ->
        case Map.fetch(by_id, row.id) do
          {:ok, existing} ->
            validate_same_immutable_row!(existing, row, kind)

          :error ->
            :ok
        end

        case Map.fetch(by_digest, row.content_sha256) do
          {:ok, existing_id} when existing_id != row.id ->
            raise_immutable_collision!(kind, :digest, row.content_sha256)

          _ ->
            :ok
        end

        {Map.put_new(by_id, row.id, row), Map.put_new(by_digest, row.content_sha256, row.id)}
      end)

    Map.values(by_id)
  end

  defp validate_immutable_collisions!(rows, stored, kind) do
    incoming_by_id = Map.new(rows, &{&1.id, &1})
    incoming_by_digest = Map.new(rows, &{&1.content_sha256, &1.id})

    Enum.each(stored, fn stored_row ->
      case Map.fetch(incoming_by_id, stored_row.id) do
        {:ok, incoming_row} ->
          validate_same_immutable_row!(stored_row, incoming_row, kind)

        :error ->
          :ok
      end

      case Map.fetch(incoming_by_digest, stored_row.content_sha256) do
        {:ok, incoming_id} when incoming_id != stored_row.id ->
          raise_immutable_collision!(kind, :digest, stored_row.content_sha256)

        _ ->
          :ok
      end
    end)
  end

  defp validate_persisted_digests!(rows, stored, kind) do
    validate_immutable_collisions!(rows, stored, kind)
    stored_by_id = Map.new(stored, &{&1.id, &1})

    Enum.each(rows, fn row ->
      case Map.fetch(stored_by_id, row.id) do
        {:ok, _stored_row} ->
          :ok

        :error ->
          raise ArgumentError,
                "advisory #{immutable_kind_name(kind)} #{row.id} was not persisted"
      end
    end)
  end

  defp validate_same_immutable_row!(left, right, kind) do
    cond do
      left.content_sha256 != right.content_sha256 ->
        raise_immutable_collision!(kind, :id, right.id)

      immutable_identity(left, kind) != immutable_identity(right, kind) ->
        raise ArgumentError,
              "advisory #{immutable_kind_name(kind)} immutable content mismatch for #{right.id}"

      true ->
        :ok
    end
  end

  defp immutable_identity(row, :product) do
    Map.take(row, [
      :id,
      :content_sha256,
      :lookup_key,
      :normalization_version,
      :package_type,
      :namespace,
      :package_name,
      :package_version,
      :release,
      :release_channel,
      :architecture,
      :source_package,
      :source_version,
      :canonical_purl,
      :product_scope,
      :parent_product_id,
      :qualifiers
    ])
  end

  defp immutable_identity(row, :product_set) do
    Map.take(row, [
      :id,
      :content_sha256,
      :normalization_version,
      :product_ids,
      :product_count,
      :canonical_size_bytes
    ])
  end

  defp raise_immutable_collision!(kind, :id, id) do
    raise ArgumentError, "advisory #{immutable_kind_name(kind)} ID collision for #{id}"
  end

  defp raise_immutable_collision!(kind, :digest, digest) do
    raise ArgumentError, "advisory #{immutable_kind_name(kind)} digest collision for #{digest}"
  end

  defp immutable_kind_name(:product), do: "product"
  defp immutable_kind_name(:product_set), do: "product set"

  defp stored_products(rows) do
    ids = Enum.map(rows, &dump_uuid!(&1.id))
    digests = Enum.map(rows, & &1.content_sha256)

    Repo.all(
      from(product in "advisory_products",
        where: product.id in ^ids or product.content_sha256 in ^digests,
        select: %{
          id: type(product.id, :binary_id),
          content_sha256: product.content_sha256,
          lookup_key: type(product.lookup_key, :binary_id),
          normalization_version: product.normalization_version,
          package_type: product.package_type,
          namespace: product.namespace,
          package_name: product.package_name,
          package_version: product.package_version,
          release: product.release,
          release_channel: product.release_channel,
          architecture: product.architecture,
          source_package: product.source_package,
          source_version: product.source_version,
          canonical_purl: product.canonical_purl,
          product_scope: product.product_scope,
          parent_product_id: type(product.parent_product_id, :binary_id),
          qualifiers: product.qualifiers
        }
      ),
      prefix: @schema
    )
  end

  defp stored_product_sets(rows) do
    ids = Enum.map(rows, &dump_uuid!(&1.id))
    digests = Enum.map(rows, & &1.content_sha256)

    from(product_set in "advisory_product_sets",
      where: product_set.id in ^ids or product_set.content_sha256 in ^digests,
      select: %{
        id: type(product_set.id, :binary_id),
        content_sha256: product_set.content_sha256,
        normalization_version: product_set.normalization_version,
        product_ids: product_set.product_ids,
        product_count: product_set.product_count,
        canonical_size_bytes: product_set.canonical_size_bytes
      }
    )
    |> Repo.all(prefix: @schema)
    |> Enum.map(fn product_set ->
      Map.update!(product_set, :product_ids, &Enum.map(&1, fn id -> load_uuid!(id) end))
    end)
  end

  defp fetch_product_ids([]), do: MapSet.new()

  defp fetch_product_ids(ids) do
    ids = Enum.map(ids, &dump_uuid!/1)

    from(product in "advisory_products",
      where: product.id in ^ids,
      select: type(product.id, :binary_id)
    )
    |> Repo.all(prefix: @schema)
    |> MapSet.new()
  end

  defp fetch_product_set_ids([]), do: MapSet.new()

  defp fetch_product_set_ids(ids) do
    ids = Enum.map(ids, &dump_uuid!/1)

    from(product_set in "advisory_product_sets",
      where: product_set.id in ^ids,
      select: type(product_set.id, :binary_id)
    )
    |> Repo.all(prefix: @schema)
    |> MapSet.new()
  end

  defp ensure_ids_exist!(expected_ids, actual_ids, kind) do
    missing =
      expected_ids
      |> MapSet.new()
      |> MapSet.difference(actual_ids)
      |> Enum.sort()

    if missing != [] do
      raise ArgumentError, "missing advisory #{kind}(s): #{Enum.join(missing, ", ")}"
    end
  end

  # Schemaless Ecto queries and insert_all calls do not have an Ash/Ecto schema
  # from which to infer :binary_id dumping. Keep canonical UUID strings in all
  # validation and identity maps, and convert only at the Postgrex boundary.
  defp dump_product_uuids!(row) do
    row
    |> Map.update!(:id, &dump_uuid!/1)
    |> Map.update!(:lookup_key, &dump_uuid!/1)
    |> Map.update!(:parent_product_id, &maybe_dump_uuid!/1)
  end

  defp dump_product_set_uuids!(row) do
    row
    |> Map.update!(:id, &dump_uuid!/1)
    |> Map.update!(:product_ids, &Enum.map(&1, fn id -> dump_uuid!(id) end))
  end

  defp dump_assertion_uuids!(row) do
    Map.update!(row, :product_set_ref, &maybe_dump_uuid!/1)
  end

  defp maybe_dump_uuid!(nil), do: nil
  defp maybe_dump_uuid!(uuid), do: dump_uuid!(uuid)

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> raise ArgumentError, "invalid UUID #{inspect(uuid)}"
    end
  end

  defp load_uuid!(uuid) when is_binary(uuid) and byte_size(uuid) == 16 do
    case Ecto.UUID.load(uuid) do
      {:ok, loaded} -> loaded
      :error -> raise ArgumentError, "invalid stored UUID"
    end
  end

  defp load_uuid!(uuid) when is_binary(uuid), do: uuid

  defp product_row(product, now) do
    %{
      id: fetch(product, :id),
      content_sha256: fetch(product, :content_sha256),
      lookup_key: fetch(product, :lookup_key),
      normalization_version: fetch(product, :normalization_version),
      package_type: fetch(product, :package_type),
      namespace: fetch(product, :namespace),
      package_name: fetch(product, :package_name),
      package_version: fetch(product, :package_version),
      release: fetch(product, :release),
      release_channel: fetch(product, :release_channel),
      architecture: fetch(product, :architecture),
      source_package: fetch(product, :source_package),
      source_version: fetch(product, :source_version),
      canonical_purl: fetch(product, :canonical_purl),
      product_scope: fetch(product, :product_scope),
      parent_product_id: fetch(product, :parent_product_id),
      qualifiers: fetch(product, :qualifiers) || %{},
      metadata: fetch(product, :metadata) || %{},
      inserted_at: now,
      updated_at: now
    }
  end

  defp product_set_row(product_set, now) do
    %{
      id: fetch(product_set, :id),
      content_sha256: fetch(product_set, :content_sha256),
      normalization_version: fetch(product_set, :normalization_version),
      product_ids: fetch(product_set, :product_ids) || [],
      product_count: fetch(product_set, :product_count),
      canonical_size_bytes: fetch(product_set, :canonical_size_bytes),
      metadata: fetch(product_set, :metadata) || %{},
      inserted_at: now,
      updated_at: now
    }
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

  defp insert_assertions([]), do: 0

  defp insert_assertions(rows) do
    rows =
      rows
      |> Enum.reduce(%{}, fn row, acc ->
        case Map.fetch(acc, row.assertion_key) do
          :error ->
            Map.put(acc, row.assertion_key, row)

          {:ok, ^row} ->
            acc

          {:ok, _different} ->
            raise ArgumentError, "conflicting assertion_key #{row.assertion_key}"
        end
      end)
      |> Map.values()

    lock_assertion_keys!(rows)
    ensure_assertion_ownership!(rows)

    product_set_ids =
      rows
      |> Enum.map(& &1.product_set_ref)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ensure_ids_exist!(product_set_ids, fetch_product_set_ids(product_set_ids), "product set")

    rows
    |> Enum.chunk_every(@max_assertion_insert)
    |> Enum.reduce(0, fn batch, acc ->
      database_batch = Enum.map(batch, &dump_assertion_uuids!/1)

      {count, _} =
        Repo.insert_all("advisory_package_assertions", database_batch,
          prefix: @schema,
          on_conflict:
            {:replace,
             [
               :provider,
               :feed_key,
               :generation,
               :cve_id,
               :authority,
               :source_kind,
               :source_timestamp,
               :assertion_shape,
               :product_set_ref,
               :statement_fingerprint,
               :package_type,
               :namespace,
               :release,
               :release_channel,
               :product_scope,
               :source_package,
               :binary_package,
               :architecture,
               :version_scheme,
               :disposition,
               :introduced_version,
               :fixed_version,
               :affected_versions,
               :package_purl,
               :justification,
               :status_text,
               :action_text,
               :validation,
               :raw,
               :metadata,
               :updated_at
             ]},
          conflict_target: [:assertion_key],
          returning: false
        )

      acc + count
    end)
  end

  # An assertion key is a global semantic identity, not a feed-local upsert key.
  # Row locking cannot protect an absent key, so serialize contenders on the
  # domain-separated key before checking ownership. The transaction-scoped lock
  # is retained through the insert (until the chunk transaction commits) and
  # prevents a losing feed from updating the winner after a check/insert race.
  defp lock_assertion_keys!(rows) do
    rows
    |> Enum.map(& &1.assertion_key)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(@max_assertion_lock_batch)
    |> Enum.each(fn keys ->
      Repo.query!(
        """
        SELECT pg_advisory_xact_lock(
                 hashtextextended('serviceradar:advisory-assertion:' || assertion_key, 0)
               )
        FROM unnest($1::text[]) AS incoming(assertion_key)
        ORDER BY assertion_key
        """,
        [keys]
      )
    end)

    :ok
  end

  defp ensure_assertion_ownership!(rows) do
    incoming = Map.new(rows, &{&1.assertion_key, load_uuid!(&1.advisory_ref)})
    keys = Map.keys(incoming)

    from(assertion in "advisory_package_assertions",
      where: assertion.assertion_key in ^keys,
      select: {assertion.assertion_key, type(assertion.advisory_ref, :binary_id)}
    )
    |> Repo.all(prefix: @schema)
    |> Enum.each(fn {key, advisory_ref} ->
      if Map.fetch!(incoming, key) != advisory_ref do
        raise ArgumentError, "assertion_key #{key} belongs to a different advisory"
      end
    end)
  end

  defp reap_stale_assertions([], _generation), do: :ok

  defp reap_stale_assertions(advisory_refs, generation) do
    Repo.delete_all(
      from(assertion in "advisory_package_assertions",
        where: assertion.advisory_ref in ^advisory_refs and assertion.generation != ^generation
      ),
      prefix: @schema
    )

    :ok
  end

  # Postgrex ON CONFLICT DO UPDATE cannot touch the same identity twice in one
  # statement. NVD repeats a CPE + version window under different
  # matchCriteriaId values, so the parser's Enum.uniq/1 is not enough.
  @doc false
  def dedupe_coordinate_rows(rows) do
    merge_coordinate_winners(rows, &coordinate_conflict_key/1)
  end

  defp merge_coordinate_rows(left, right) do
    base =
      if normalized_coordinate_tuple(left) <= normalized_coordinate_tuple(right),
        do: left,
        else: right

    base
    |> Map.put(
      :metadata,
      NvdApplicability.merge_metadata(Map.get(left, :metadata), Map.get(right, :metadata))
    )
    |> Map.put(
      :version_start_inclusive,
      inclusive_superset(
        Map.get(left, :version_start_inclusive),
        Map.get(right, :version_start_inclusive)
      )
    )
    |> Map.put(
      :version_end_inclusive,
      inclusive_superset(
        Map.get(left, :version_end_inclusive),
        Map.get(right, :version_end_inclusive)
      )
    )
  end

  defp inclusive_superset(true, _right), do: true
  defp inclusive_superset(_left, true), do: true
  defp inclusive_superset(false, _right), do: false
  defp inclusive_superset(_left, false), do: false
  defp inclusive_superset(_left, _right), do: nil

  defp coordinate_conflict_key(row) do
    {
      Map.fetch!(row, :advisory_ref),
      coordinate_identity(row)
    }
  end

  defp coordinate_identity(coordinate) do
    {
      fetch(coordinate, :coordinate_type),
      fetch(coordinate, :value),
      fetch(coordinate, :version_start),
      fetch(coordinate, :version_end)
    }
  end

  defp dedupe_advisory_rows(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc -> Map.put(acc, row.source_object_id, row) end)
    |> Map.values()
  end

  # Same last-wins choice as `dedupe_advisory_rows/1`, applied to whole records.
  defp last_record_per_source(records) do
    records
    |> Enum.reduce(%{}, fn %{advisory: advisory} = record, acc ->
      Map.put(acc, fetch(advisory, :source_object_id), record)
    end)
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
      published_at: persisted_datetime(fetch(advisory, :published_at)),
      modified_at: persisted_datetime(fetch(advisory, :modified_at)),
      kev: fetch(advisory, :kev) || false,
      exploit_available: fetch(advisory, :exploit_available) || false,
      affected_coordinates: [],
      references: fetch(advisory, :references) || [],
      raw: fetch(advisory, :raw) || %{},
      generation: generation,
      current: false,
      metadata: fetch(advisory, :metadata) || %{},
      nvd_configurations: fetch(advisory, :nvd_configurations),
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

    advisory
    |> fetch(:nvd_configurations)
    |> hashed_content(normalized_advisory_tuple(advisory), coordinate_binaries)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Configurations are hashed only when present so records without them (every
  # hash-compared feed today) keep their stored hashes and are not rewritten.
  defp hashed_content(nil, advisory_tuple, coordinates), do: {advisory_tuple, coordinates}

  defp hashed_content(configurations, advisory_tuple, coordinates),
    do: {advisory_tuple, coordinates, configurations}

  defp normalized_advisory_tuple(advisory) do
    @advisory_content_fields
    |> Enum.map(&normalized_advisory_value(advisory, &1))
    |> List.to_tuple()
  end

  defp normalized_advisory_value(advisory, field) when field in [:published_at, :modified_at],
    do: persisted_datetime(fetch(advisory, field))

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
    |> merge_coordinate_winners(&coordinate_identity/1)
    |> Enum.map(&normalized_coordinate_tuple/1)
  end

  defp normalized_coordinate_tuple(coordinate) do
    @coordinate_content_fields
    |> Enum.map(&normalized_coordinate_value(coordinate, &1))
    |> List.to_tuple()
  end

  defp normalized_coordinate_value(coordinate, :metadata), do: fetch(coordinate, :metadata) || %{}
  defp normalized_coordinate_value(coordinate, field), do: fetch(coordinate, field)

  # Use the same deterministic, lossless reduction for inserted rows and hash
  # calculation. Otherwise reversing repeated NVD criteria could leave the
  # persisted row unchanged while changing the advisory content hash.
  defp merge_coordinate_winners(coordinates, identity_fun) do
    coordinates
    |> Enum.reduce(%{}, fn coordinate, acc ->
      Map.update(
        acc,
        identity_fun.(coordinate),
        coordinate,
        &merge_coordinate_rows(&1, coordinate)
      )
    end)
    |> Map.values()
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

  defp assertion_row(assertion, advisory_ref, provider, feed_key, generation, now) do
    %{
      assertion_key: fetch(assertion, :assertion_key),
      advisory_ref: advisory_ref,
      provider: provider,
      feed_key: feed_key,
      generation: generation,
      cve_id: fetch(assertion, :cve_id),
      authority: fetch(assertion, :authority),
      source_kind: fetch(assertion, :source_kind),
      source_timestamp: parse_datetime(fetch(assertion, :source_timestamp)),
      assertion_shape: fetch(assertion, :assertion_shape) || "scalar",
      product_set_ref: fetch(assertion, :product_set_ref),
      statement_fingerprint: fetch(assertion, :statement_fingerprint),
      package_type: fetch(assertion, :package_type),
      namespace: fetch(assertion, :namespace),
      release: fetch(assertion, :release),
      release_channel: fetch(assertion, :release_channel),
      product_scope: fetch(assertion, :product_scope),
      source_package: fetch(assertion, :source_package),
      binary_package: fetch(assertion, :binary_package),
      architecture: fetch(assertion, :architecture),
      version_scheme: fetch(assertion, :version_scheme),
      disposition: fetch(assertion, :disposition),
      introduced_version: fetch(assertion, :introduced_version),
      fixed_version: fetch(assertion, :fixed_version),
      affected_versions: fetch(assertion, :affected_versions) || [],
      package_purl: fetch(assertion, :package_purl),
      justification: fetch(assertion, :justification),
      status_text: fetch(assertion, :status_text),
      action_text: fetch(assertion, :action_text),
      validation: fetch(assertion, :validation) || %{},
      raw: fetch(assertion, :raw) || %{},
      metadata: fetch(assertion, :metadata) || %{},
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

  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
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

  defp persisted_datetime(value) do
    case parse_datetime(value) do
      %DateTime{microsecond: {microsecond, _precision}} = datetime ->
        %{datetime | microsecond: {microsecond, 6}}

      nil ->
        nil
    end
  end

  defp parse_naive(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end
end
