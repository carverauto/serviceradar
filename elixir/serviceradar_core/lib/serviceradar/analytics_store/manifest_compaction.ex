defmodule ServiceRadar.AnalyticsStore.ManifestCompaction do
  @moduledoc """
  Primary-side publication of immutable compacted files.

  Object IO finishes before the transaction. Publication locks the captured
  source rows, checks that none changed, then replaces the entire visible set
  in one commit. Readers that already captured the old keys can finish against
  retained objects; new manifest reads see only the compacted object.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AnalyticsStore.FileManifest
  alias ServiceRadar.Repo

  require Ash.Query

  @snapshot_fields [
    :id,
    :table_name,
    :object_key,
    :staging_key,
    :partition_date,
    :row_count,
    :min_timestamp,
    :max_timestamp,
    :content_checksum,
    :batch_id,
    :archive_batch_id,
    :status,
    :updated_at
  ]
  @max_sources 256
  @max_rows 500_000
  @max_rewrite_rows 10_000_000
  @reader_grace_seconds 86_400

  @doc "Minimum grace before deleting objects retired by a manifest replacement."
  def reader_grace_seconds, do: @reader_grace_seconds

  def compaction_candidates(table, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    before = Keyword.get(opts, :older_than, DateTime.add(now, -600, :second))
    max_files = Keyword.get(opts, :max_files, @max_sources)
    max_rows = Keyword.get(opts, :max_rows, @max_rows)
    max_source_rows = div(max_rows, 2)

    if max_files in 2..@max_sources and max_rows in 1..@max_rows do
      FileManifest
      |> Ash.Query.filter(
        table_name == ^table and status == :published and row_count > 0 and
          row_count <= ^max_source_rows and not is_nil(min_timestamp) and
          max_timestamp < ^before and inserted_at < ^before and
          exists(
            partition_files,
            id != parent(id) and status == :published and row_count > 0 and
              row_count <= ^max_source_rows and not is_nil(min_timestamp) and
              max_timestamp < ^before and inserted_at < ^before
          )
      )
      |> Ash.Query.sort(partition_date: :asc, min_timestamp: :asc, id: :asc)
      |> Ash.Query.limit(1_024)
      |> Ash.read(actor: actor())
      |> case do
        {:ok, files} -> {:ok, select_group(files, max_files, max_rows)}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_compaction_limits}
    end
  end

  @doc "Select a bounded same-day group without splitting any source object."
  def select_group(files, max_files, max_rows) do
    files
    |> Enum.chunk_by(& &1.partition_date)
    |> Enum.find_value([], fn group ->
      {selected, _, _} =
        Enum.reduce(group, {[], 0, 0}, fn file, {selected, count, rows} = acc ->
          if count < max_files and rows + file.row_count <= max_rows do
            {[file | selected], count + 1, rows + file.row_count}
          else
            acc
          end
        end)

      if length(selected) >= 2, do: Enum.reverse(selected)
    end)
  end

  def replace_sources(sources, attrs, opts \\ []) do
    with :ok <- validate_replacement(sources, attrs) do
      publish_replacement(sources, attrs, opts)
    end
  end

  def rewrite_source(table, manifest_id, opts \\ [])

  def rewrite_source(_table, manifest_id, _opts)
      when not is_integer(manifest_id) or manifest_id <= 0,
      do: {:error, :invalid_rewrite_manifest_id}

  def rewrite_source(table, manifest_id, opts) do
    with {:ok, source} <-
           FileManifest
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(table_name == ^table and id == ^manifest_id)
           |> Ash.read_one(actor: actor()),
         :ok <- validate_rewrite_source(source, opts) do
      {:ok, source}
    end
  end

  def replace_rewrite(source, attrs, opts \\ []) do
    with :ok <- validate_rewrite(source, attrs, opts),
         true <- verified_checksum?(attrs[:content_checksum]) do
      publish_replacement([source], attrs, opts)
    else
      false -> {:error, :unverified_rewrite_candidate}
      {:error, _} = error -> error
    end
  end

  @doc "Validate the separate single-file rewrite budget before any object IO."
  def validate_rewrite_source(source, opts \\ [])

  def validate_rewrite_source(source, opts) when is_map(source) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    before = DateTime.add(now, -600, :second)

    cond do
      not is_integer(Map.get(source, :id)) or Map.get(source, :id) <= 0 or
        Map.get(source, :table_name) != "timeseries_metrics" or
        Map.get(source, :status) != :published or
        not is_integer(Map.get(source, :row_count)) or
          Map.get(source, :row_count) not in 1..@max_rewrite_rows ->
        {:error, :invalid_rewrite_source}

      not rewrite_bounds_valid?(source, before) ->
        {:error, :invalid_rewrite_source}

      is_binary(Map.get(source, :content_checksum)) and
          String.starts_with?(source.content_checksum, "row-hash-v1:") ->
        {:error, :rewrite_source_already_sorted}

      true ->
        :ok
    end
  end

  def validate_rewrite_source(_source, _opts), do: {:error, :invalid_rewrite_source}

  def validate_rewrite(source, attrs, opts \\ []) do
    with :ok <- validate_rewrite_source(source, opts) do
      validate_target([source], attrs, @max_rewrite_rows)
    end
  end

  defp rewrite_bounds_valid?(source, before) do
    with %Date{} = day <- Map.get(source, :partition_date),
         %DateTime{utc_offset: 0, std_offset: 0} = first <- Map.get(source, :min_timestamp),
         %DateTime{utc_offset: 0, std_offset: 0} = last <- Map.get(source, :max_timestamp),
         %DateTime{} = inserted <- Map.get(source, :inserted_at) do
      DateTime.to_date(first) == day and DateTime.to_date(last) == day and
        DateTime.compare(first, last) != :gt and DateTime.compare(last, before) != :gt and
        DateTime.compare(inserted, before) != :gt
    else
      _ -> false
    end
  end

  defp verified_checksum?(checksum),
    do: is_binary(checksum) and Regex.match?(~r/\Arow-hash-v1:[0-9a-f]{64}\z/, checksum)

  defp publish_replacement(sources, attrs, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ids = Enum.map(sources, & &1.id)

    FileManifest
    |> Ash.transact(fn ->
      locked =
        FileManifest
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.lock(:for_update)
        |> Ash.read!(actor: actor())

      if snapshot(locked) != snapshot(sources),
        do: Repo.rollback(:compaction_sources_changed)

      attrs = Map.drop(attrs, [:status, :archive_batch_id])

      FileManifest
      |> Ash.Changeset.for_create(:compact, attrs)
      |> Ash.create!(actor: actor())

      Enum.each(locked, fn source ->
        source
        |> Ash.Changeset.for_update(:supersede, %{
          retired_at: now,
          replacement_key: attrs.object_key
        })
        |> Ash.update!(actor: actor())
      end)

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, error}
  end

  @doc "Reject a target whose verified row count or bounds differ from its source envelope."
  def validate_replacement(sources, attrs) when is_list(sources) and is_map(attrs) do
    if length(sources) in 2..@max_sources and valid_sources?(sources) do
      validate_target(sources, attrs, @max_rows)
    else
      {:error, :invalid_compaction_sources}
    end
  end

  def validate_replacement(_, _), do: {:error, :invalid_compaction_sources}

  defp valid_sources?(sources) do
    length(Enum.uniq_by(sources, & &1.id)) == length(sources) and
      Enum.all?(sources, fn source ->
        source.status == :published and is_integer(source.row_count) and source.row_count > 0 and
          match?(%DateTime{}, source.min_timestamp) and
          match?(%DateTime{}, source.max_timestamp)
      end)
  end

  defp validate_target(sources, attrs, max_rows) do
    first = hd(sources)
    rows = Enum.sum(Enum.map(sources, & &1.row_count))

    min_time =
      Enum.min_by(sources, &DateTime.to_unix(&1.min_timestamp, :microsecond)).min_timestamp

    max_time =
      Enum.max_by(sources, &DateTime.to_unix(&1.max_timestamp, :microsecond)).max_timestamp

    key = Map.get(attrs, :object_key)

    same_partition? =
      Enum.all?(sources, fn source ->
        source.table_name == first.table_name and source.partition_date == first.partition_date
      end)

    expected = %{
      table_name: first.table_name,
      partition_date: first.partition_date,
      row_count: rows,
      min_timestamp: min_time,
      max_timestamp: max_time
    }

    key_prefix = "analytics/v1/#{first.table_name}/_candidates/date=#{first.partition_date}/"

    if same_partition? and rows <= max_rows and Map.take(attrs, Map.keys(expected)) == expected and
         is_binary(key) and attrs[:staging_key] == key and String.starts_with?(key, key_prefix) and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\.parquet\z/, String.replace_prefix(key, key_prefix, "")) and
         Enum.all?(sources, &(&1.object_key != key and &1.staging_key != key)) and
         is_binary(attrs[:content_checksum]) and attrs[:content_checksum] != "" and
         attrs[:archive_batch_id] == nil and attrs[:status] in [nil, :published] do
      :ok
    else
      {:error, :compaction_candidate_mismatch}
    end
  end

  @doc "Hide expired published files in one short transaction, retaining their physical keys for cleanup."
  def retire_expired(table, %Date{} = cutoff, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    limit = Keyword.get(opts, :limit, @max_sources)

    if limit in 1..@max_sources do
      Ash.transact(FileManifest, fn ->
        files =
          FileManifest
          |> Ash.Query.filter(
            table_name == ^table and partition_date < ^cutoff and status == :published
          )
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.limit(limit)
          |> Ash.Query.lock(:for_update)
          |> Ash.read!(actor: actor())

        Enum.each(files, fn file ->
          file
          |> Ash.Changeset.for_update(:expire, %{retired_at: now})
          |> Ash.update!(actor: actor())
        end)

        length(files)
      end)
    else
      {:error, :invalid_retirement_limit}
    end
  rescue
    error -> {:error, error}
  end

  def retired_files(table, before, limit \\ @max_sources) do
    grace_cutoff = DateTime.add(DateTime.utc_now(), -@reader_grace_seconds, :second)
    before = Enum.min_by([before, grace_cutoff], &DateTime.to_unix(&1, :microsecond))

    FileManifest
    |> Ash.Query.filter(
      table_name == ^table and status in [:superseded, :expired] and retired_at < ^before and
        is_nil(objects_deleted_at)
    )
    |> Ash.Query.sort(retired_at: :asc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor())
  end

  def mark_objects_deleted(id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    before = DateTime.add(now, -@reader_grace_seconds, :second)

    with {:ok, %FileManifest{} = file} <-
           FileManifest
           |> Ash.Query.filter(
             id == ^id and status in [:superseded, :expired] and retired_at <= ^before
           )
           |> Ash.read_one(actor: actor()),
         {:ok, _} <-
           file
           |> Ash.Changeset.for_update(:mark_objects_deleted, %{objects_deleted_at: now})
           |> Ash.update(actor: actor()) do
      :ok
    else
      {:ok, nil} -> {:error, :compaction_reader_grace_active}
      {:error, _} = error -> error
    end
  end

  defp snapshot(files),
    do: files |> Enum.map(&Map.take(&1, @snapshot_fields)) |> Enum.sort_by(& &1.id)

  defp actor, do: SystemActor.system(:analytics_compaction)
end
