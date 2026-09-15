defmodule ServiceRadar.AnalyticsStore.ArchiveBatch do
  @moduledoc """
  Durable EventWriter archive payloads, committed with the corresponding hot rows.

  Payloads remain until a verified candidate becomes the batch's single published
  manifest entry. Oban jobs contain only the batch ID and can be recreated without
  losing data. The buffer limit applies to pending payloads, never to receipt rows.
  """

  use Ash.Resource,
    domain: ServiceRadar.AnalyticsStore.Catalog,
    data_layer: AshPostgres.DataLayer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.FileManifest
  alias ServiceRadar.EventWriter.ArchivePublisher
  alias ServiceRadar.Repo

  require Ash.Query

  @table "timeseries_metrics"
  @schema_version 1
  @max_rows 10_000
  @max_payload_bytes 8_388_608
  @buffer_lock 1_832_647_019
  @columns ~w(timestamp gateway_id agent_id metric_name metric_type device_id value unit tags partition scale is_delta target_device_ip if_index metadata created_at series_key counter_width)a
  @column_names Enum.map(@columns, &Atom.to_string/1)

  postgres do
    table "analytics_archive_batches"
    repo Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [
        :id,
        :table_name,
        :partition_date,
        :min_timestamp,
        :max_timestamp,
        :payload,
        :payload_bytes,
        :content_checksum,
        :schema_version,
        :row_count
      ]
    end

    update :publish do
      accept [:published_object_key]
      change set_attribute(:state, :published)
      change set_attribute(:payload, nil)
      change set_attribute(:payload_bytes, 0)
    end

    update :reconciled do
      accept [:last_reconciled_at]
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :table_name, :string, allow_nil?: false
    attribute :partition_date, :date, allow_nil?: false
    attribute :min_timestamp, :utc_datetime_usec, allow_nil?: false
    attribute :max_timestamp, :utc_datetime_usec, allow_nil?: false
    attribute :payload, :binary, sensitive?: true
    attribute :payload_bytes, :integer, allow_nil?: false
    attribute :content_checksum, :string, allow_nil?: false
    attribute :schema_version, :integer, allow_nil?: false
    attribute :row_count, :integer, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :published]]

    attribute :published_object_key, :string
    attribute :last_reconciled_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc "Commit bounded payloads and their jobs in the current primary transaction."
  def enqueue_rows(table, rows, opts \\ [])
  def enqueue_rows(@table, [], _opts), do: {:ok, 0}

  def enqueue_rows(table, rows, opts) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, batches} <- prepare_batches(table, rows) do
      Ash.transact(__MODULE__, fn ->
        repo.query!("SELECT pg_advisory_xact_lock($1)", [@buffer_lock], log: false)

        pending =
          __MODULE__
          |> Ash.Query.filter(state == :pending)
          |> Ash.sum!(:payload_bytes, actor: actor())

        bytes = Enum.sum(Enum.map(batches, & &1.payload_bytes))
        limit = Map.get(cfg, :archive_buffer_max_bytes, 268_435_456)

        if (pending || 0) + bytes > limit, do: repo.rollback(:archive_buffer_full)

        Enum.each(batches, fn attrs ->
          batch =
            __MODULE__
            |> Ash.Changeset.for_create(:enqueue, attrs)
            |> Ash.create!(actor: actor())

          case Keyword.get(opts, :enqueue_job, &ArchivePublisher.enqueue/1).(batch.id) do
            {:ok, _} -> :ok
            {:error, reason} -> repo.rollback(reason)
          end
        end)

        length(batches)
      end)
    end
  rescue
    error -> {:error, error}
  end

  @doc "Build immutable, versioned payloads split by UTC date and row/byte limits."
  def prepare_batches(@table, rows) when is_list(rows) do
    with {:ok, rows} <- normalize_rows(rows) do
      rows
      |> Enum.group_by(&DateTime.to_date(&1.timestamp))
      |> Enum.sort_by(&elem(&1, 0), Date)
      |> Enum.reduce_while({:ok, []}, fn {date, rows}, {:ok, batches} ->
        case encode_partition(date, rows) do
          {:ok, encoded} -> {:cont, {:ok, batches ++ encoded}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  def prepare_batches(_table, _rows), do: {:error, :unsupported_archive_table}

  @doc "Validate the stored version, checksum and bounds before any archive IO."
  def decode_payload(
        %{table_name: @table, schema_version: @schema_version, payload: payload} = batch
      )
      when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    with true <- byte_size(payload) == batch.payload_bytes,
         true <- checksum(payload) == batch.content_checksum,
         {:ok, %{"rows" => rows}} when is_list(rows) <- Jason.decode(payload),
         true <- length(rows) == batch.row_count and length(rows) in 1..@max_rows,
         {:ok, rows} <- normalize_rows(rows),
         true <- Enum.all?(rows, &(DateTime.to_date(&1.timestamp) == batch.partition_date)),
         true <- matching_bounds?(rows, batch) do
      {:ok, rows}
    else
      _ -> {:error, :invalid_archive_payload}
    end
  end

  def decode_payload(_batch), do: {:error, :invalid_archive_payload}

  @doc "Load one batch without changing its publication state."
  def fetch(id), do: Ash.get(__MODULE__, id, actor: actor())

  @doc "Select pending IDs for reconciliation without loading their payloads."
  def pending_ids(limit \\ 100) do
    __MODULE__
    |> Ash.Query.filter(state == :pending)
    |> Ash.Query.select([:id])
    |> Ash.Query.sort(last_reconciled_at: :asc_nils_first, inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor())
    |> case do
      {:ok, batches} -> {:ok, Enum.map(batches, & &1.id)}
      {:error, _} = error -> error
    end
  end

  @doc "Rotate successfully reconciled IDs behind untouched pending batches."
  def mark_reconciled(id) do
    with {:ok, batch} when not is_nil(batch) <- fetch(id),
         {:ok, _} <-
           batch
           |> Ash.Changeset.for_update(:reconciled, %{last_reconciled_at: DateTime.utc_now()})
           |> Ash.update(actor: actor()) do
      :ok
    else
      {:ok, nil} -> {:error, :archive_batch_missing}
      {:error, _} = error -> error
    end
  end

  @doc "Snapshot pending batches overlapping a query window before waiting for publication."
  def pending_ids_for_window(table, {start_at, end_at}, opts \\ []) do
    query = Ash.Query.filter(__MODULE__, table_name == ^table and state == :pending)
    query = if start_at, do: Ash.Query.filter(query, max_timestamp >= ^start_at), else: query
    query = if end_at, do: Ash.Query.filter(query, min_timestamp <= ^end_at), else: query

    query
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1_001)
    |> Ash.read(actor: actor(), timeout: Keyword.get(opts, :timeout, 5_000))
    |> case do
      {:ok, batches} when length(batches) <= 1_000 -> {:ok, Enum.map(batches, & &1.id)}
      {:ok, _batches} -> {:error, :analytics_archive_not_ready}
      {:error, _} = error -> error
    end
  end

  @doc "Check only the captured IDs, so ongoing ingestion cannot extend a query's wait."
  def published_ids?(ids, opts \\ [])
  def published_ids?([], _opts), do: {:ok, true}

  def published_ids?(ids, opts) do
    ids = Enum.uniq(ids)

    __MODULE__
    |> Ash.Query.filter(id in ^ids and state == :published)
    |> Ash.count(actor: actor(), timeout: Keyword.get(opts, :timeout, 5_000))
    |> case do
      {:ok, count} -> {:ok, count == length(ids)}
      {:error, _} = error -> error
    end
  end

  @doc "Atomically publish one verified candidate; a concurrent loser stays invisible."
  def complete(id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case Ash.transact(__MODULE__, fn ->
           batch =
             __MODULE__
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.lock(:for_update)
             |> Ash.read_one!(actor: actor())

           complete_locked(batch, attrs, repo)
         end) do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, error}
  end

  defp complete_locked(nil, _attrs, repo), do: repo.rollback(:archive_batch_missing)
  defp complete_locked(%{state: :published}, _attrs, _repo), do: :ok

  defp complete_locked(batch, attrs, repo) do
    if attrs.table_name != batch.table_name or attrs.partition_date != batch.partition_date or
         attrs.row_count != batch.row_count or attrs.status != :published or
         DateTime.compare(attrs.min_timestamp, batch.min_timestamp) != :eq or
         DateTime.compare(attrs.max_timestamp, batch.max_timestamp) != :eq do
      repo.rollback(:archive_candidate_mismatch)
    end

    manifest = Map.merge(attrs, %{archive_batch_id: batch.id, batch_id: batch.id})

    case FileManifest.record(manifest) do
      :ok -> :ok
      {:error, reason} -> repo.rollback(reason)
    end

    batch
    |> Ash.Changeset.for_update(:publish, %{published_object_key: attrs.object_key})
    |> Ash.update!(actor: actor())

    :ok
  end

  defp normalize_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case normalize_row(row) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _} = error -> error
    end
  end

  defp matching_bounds?(rows, batch) do
    {earliest, latest} =
      Enum.min_max_by(Enum.map(rows, & &1.timestamp), &DateTime.to_unix(&1, :microsecond))

    DateTime.compare(earliest, batch.min_timestamp) == :eq and
      DateTime.compare(latest, batch.max_timestamp) == :eq
  end

  defp normalize_row(row) when is_map(row) do
    names = Enum.map(Map.keys(row), &to_string/1)

    if Enum.sort(names) == Enum.sort(@column_names) do
      row =
        Map.new(@columns, fn key ->
          {key, Map.get(row, key, Map.get(row, Atom.to_string(key)))}
        end)

      with {:ok, timestamp} <- timestamp(row.timestamp),
           {:ok, created_at} <- optional_timestamp(row.created_at),
           true <- is_binary(row.gateway_id) and is_binary(row.series_key) do
        {:ok, %{row | timestamp: timestamp, created_at: created_at}}
      else
        _ -> {:error, :invalid_archive_row}
      end
    else
      {:error, :invalid_archive_columns}
    end
  end

  defp normalize_row(_row), do: {:error, :invalid_archive_row}

  defp optional_timestamp(nil), do: {:ok, nil}
  defp optional_timestamp(value), do: timestamp(value)
  defp timestamp(%DateTime{} = value), do: {:ok, DateTime.shift_zone!(value, "Etc/UTC")}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, value, _offset} -> timestamp(value)
      _ -> {:error, :invalid_archive_timestamp}
    end
  end

  defp timestamp(_value), do: {:error, :invalid_archive_timestamp}

  defp encode_partition(date, rows) do
    rows
    |> Enum.chunk_every(@max_rows)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case encode_chunk(date, chunk) do
        {:ok, batches} -> {:cont, {:ok, acc ++ batches}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp encode_chunk(date, rows) do
    case Jason.encode(%{rows: rows}) do
      {:ok, payload} when byte_size(payload) <= @max_payload_bytes ->
        {min_timestamp, max_timestamp} =
          Enum.min_max_by(Enum.map(rows, & &1.timestamp), &DateTime.to_unix(&1, :microsecond))

        {:ok,
         [
           %{
             id: Ecto.UUID.generate(),
             table_name: @table,
             partition_date: date,
             min_timestamp: min_timestamp,
             max_timestamp: max_timestamp,
             payload: payload,
             payload_bytes: byte_size(payload),
             content_checksum: checksum(payload),
             schema_version: @schema_version,
             row_count: length(rows)
           }
         ]}

      {:ok, _payload} when length(rows) > 1 ->
        {left, right} = Enum.split(rows, div(length(rows), 2))

        with {:ok, left} <- encode_chunk(date, left),
             {:ok, right} <- encode_chunk(date, right) do
          {:ok, left ++ right}
        end

      {:ok, _payload} ->
        {:error, :archive_row_too_large}

      {:error, _} ->
        {:error, :invalid_archive_row}
    end
  end

  defp checksum(payload), do: :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)
  defp actor, do: SystemActor.system(:analytics_store)
end
