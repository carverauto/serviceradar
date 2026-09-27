defmodule ServiceRadar.NetworkDiscovery.World do
  @moduledoc """
  Persists topology coordinate systems and publishes complete geometry revisions.

  A layout version changes only on explicit relayout. Incremental publications
  keep existing placements, including inactive positions, and update the shared
  generation after all relation and membership changes commit. Geometry tile
  revisions belong to the tile engine and must not include this generation.

  Bootstrap streams bounded batches under a shared head lock. Every publisher
  locks that same row before changing visible data. Callbacks should only feed
  their native builder; finish the index after `stream_active/2` returns.
  """

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.NetworkDiscovery.WorldHead
  alias ServiceRadar.NetworkDiscovery.WorldLayout
  alias ServiceRadar.NetworkDiscovery.WorldPosition
  alias ServiceRadar.NetworkDiscovery.WorldRelation
  alias ServiceRadar.NetworkDiscovery.WorldWorker
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query

  @batch_size 500
  # Initial million-device stages write three million rows without holding the
  # active head. Leave time within WorldWorker's 15-minute deadline for source
  # reads and placement; readers and visible publications retain a shorter lease.
  @staging_timeout to_timeout(minute: 10)
  @publication_timeout to_timeout(minute: 5)
  @resources [WorldHead, WorldLayout, WorldPosition, WorldRelation]
  @manifest_fields [
    :layout_version,
    :extent,
    :algorithm_version,
    :zmax,
    :source_digest,
    :node_count,
    :relation_count
  ]

  @doc "Stages a new coordinate system without changing the active world."
  def stage_relayout(scope, attrs) do
    WorldLayout
    |> Ash.Changeset.for_create(:stage, attrs)
    |> Ash.create(scope: scope)
  end

  @doc "Authorizes and atomically records a new coordinate system and its background build."
  def request_relayout(scope) do
    @resources
    |> Ash.transact(fn ->
      with {:ok, layout} <-
             stage_relayout(scope, %{source_digest: "pending", node_count: 0, relation_count: 0}),
           {:ok, job} <- enqueue_relayout(layout.layout_version) do
        {:ok, %{layout_version: layout.layout_version, job_id: job.id}}
      end
    end)
    |> transaction_result()
  end

  @doc "Replaces an unpublished retry stage with bounded candidate streams without locking the active head."
  def stage_candidate(layout_version, metadata, positions, relations) do
    attrs =
      metadata
      |> Map.take([:algorithm_version, :zmax, :source_digest, :node_count, :relation_count])
      |> Map.put(:layout_version, layout_version)

    @resources
    |> Ash.transact(
      fn ->
        with {:ok, _layout} <-
               WorldLayout
               |> Ash.Changeset.for_create(:initialize_stage, attrs)
               |> Ash.create(actor: actor()),
             {:ok, layout} <- locked_layout(layout_version),
             :ok <- building?(layout),
             :ok <- clear_stage_rows(WorldRelation, layout_version),
             :ok <- clear_stage_rows(WorldPosition, layout_version),
             :ok <- insert_positions(layout_version, positions),
             :ok <- upsert_relations(layout_version, relations),
             :ok <-
               verify_counts(
                 layout,
                 Map.fetch!(metadata, :node_count),
                 Map.fetch!(metadata, :relation_count)
               ),
             {:ok, _layout} <-
               update(
                 layout,
                 :publish,
                 Map.take(metadata, [:source_digest, :node_count, :relation_count])
               ) do
          :ok
        end
      end,
      timeout: @staging_timeout
    )
    |> transaction_result()
  end

  @doc "Appends a bounded batch to an unpublished layout; positions must precede their relations."
  def append_stage(layout_version, positions, relations)
      when is_list(positions) and is_list(relations) and length(positions) <= @batch_size and
             length(relations) <= @batch_size do
    @resources
    |> Ash.transact(fn ->
      with {:ok, layout} <- locked_layout(layout_version),
           :ok <- building?(layout),
           :ok <- insert_positions(layout_version, positions) do
        upsert_relations(layout_version, relations)
      end
    end)
    |> transaction_result()
  end

  def append_stage(_layout_version, _positions, _relations), do: {:error, :batch_too_large}

  @doc "Activates a fully staged relayout only if its base publication is still current."
  def activate_relayout(expected_generation, layout_version) do
    with :ok <- ensure_head() do
      @resources
      |> Ash.transact(
        fn ->
          with {:ok, head} <- locked_head("FOR UPDATE"),
               :ok <- expected_generation?(head, expected_generation),
               {:ok, layout} <- locked_layout(layout_version),
               :ok <- building?(layout),
               :ok <- verify_counts(layout, layout.node_count, layout.relation_count),
               :ok <- retire_layout(head.active_layout_version),
               {:ok, layout} <- update(layout, :publish, %{status: :active}),
               {:ok, head} <- publish_head(head, layout_version) do
            {:ok, manifest(head, layout)}
          end
        end,
        timeout: @publication_timeout
      )
      |> transaction_result()
      |> notify_publication()
    end
  end

  @doc """
  Applies a geometry delta atomically, rejecting stale producers.

  The delta contains `insert_positions`, `activate_device_ids`,
  `deactivate_device_ids`, `update_positions`, `upsert_relations`, `deactivate_relation_ids`,
  `source_digest`, `node_count`, and `relation_count`. Collections can be lazy
  enumerables; each database operation consumes at most one bounded batch.
  Existing coordinates and placement metadata are never updated.
  """
  def publish_delta(expected_generation, delta) when is_map(delta) do
    @resources
    |> Ash.transact(
      fn ->
        with {:ok, head} <- locked_head("FOR UPDATE"),
             :ok <- expected_generation?(head, expected_generation),
             {:ok, layout} <- active_layout(head),
             :ok <- insert_positions(layout.layout_version, Map.get(delta, :insert_positions, [])),
             :ok <- update_positions(layout.layout_version, Map.get(delta, :update_positions, [])),
             :ok <-
               set_active(
                 WorldPosition,
                 layout.layout_version,
                 :device_id,
                 Map.get(delta, :activate_device_ids, []),
                 true
               ),
             :ok <-
               set_active(
                 WorldRelation,
                 layout.layout_version,
                 :relation_id,
                 Map.get(delta, :deactivate_relation_ids, []),
                 false
               ),
             :ok <- upsert_relations(layout.layout_version, Map.get(delta, :upsert_relations, [])),
             :ok <-
               retire_positions(layout.layout_version, Map.get(delta, :deactivate_device_ids, [])),
             :ok <-
               verify_counts(
                 layout,
                 Map.fetch!(delta, :node_count),
                 Map.fetch!(delta, :relation_count)
               ),
             {:ok, layout} <-
               update(
                 layout,
                 :publish,
                 Map.take(delta, [:source_digest, :node_count, :relation_count])
               ),
             {:ok, head} <- publish_head(head, layout.layout_version) do
          {:ok, manifest(head, layout)}
        end
      end,
      timeout: @publication_timeout
    )
    |> transaction_result()
    |> notify_publication()
  end

  @doc "Returns the current publication without exposing device or relation rows."
  def active_manifest(scope) do
    @resources
    |> Ash.transact(fn ->
      with {:ok, head} <- locked_head("FOR SHARE", scope),
           {:ok, layout} <- active_layout(head, scope) do
        {:ok, manifest(head, layout)}
      end
    end)
    |> transaction_result()
  end

  @doc """
  Streams a coherent published world into a caller-owned accumulator.

  The callback receives `{:manifest, manifest}`, `{:positions, rows}`, and
  `{:relations, rows}` and returns `{:ok, accumulator}` or `{:error, reason}`.
  Inactive positions are included so incremental placement can reuse them.
  Only active relations are needed to reconstruct the published world.
  """
  def stream_active(accumulator, callback) when is_function(callback, 2) do
    @resources
    |> Ash.transact(
      fn ->
        with {:ok, head} <- locked_head("FOR SHARE"),
             {:ok, layout} <- active_layout(head),
             {:ok, accumulator} <- callback.({:manifest, manifest(head, layout)}, accumulator),
             {:ok, accumulator} <-
               stream_rows(
                 WorldPosition,
                 layout.layout_version,
                 :positions,
                 accumulator,
                 callback
               ) do
          stream_rows(WorldRelation, layout.layout_version, :relations, accumulator, callback)
        end
      end,
      timeout: @publication_timeout
    )
    |> transaction_result()
  end

  @doc "Looks up an active device's persisted placement under inventory read authorization."
  def lookup_device(scope, layout_version, device_id) do
    WorldPosition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(layout_version == ^layout_version and device_id == ^device_id and active)
    |> Ash.Query.filter(layout.status in [:active, :retired])
    |> Ash.read_one(scope: scope)
  end

  defp ensure_head do
    WorldHead
    |> Ash.Changeset.for_create(:initialize, %{})
    |> Ash.create(actor: actor())
    |> case do
      {:ok, _head} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_relayout(layout_version) do
    %{"mode" => "relayout", "layout_version" => layout_version}
    |> WorldWorker.new(
      unique: [period: :infinity, keys: [:mode, :layout_version], states: :incomplete]
    )
    |> ObanSupport.safe_insert()
    |> case do
      {:ok, %{id: id} = job} when is_integer(id) -> {:ok, job}
      _result -> reject(:scheduler_unavailable)
    end
  end

  defp clear_stage_rows(resource, layout_version) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(layout_version == ^layout_version)
    |> Ash.bulk_destroy(:discard, %{}, bulk_options())
    |> bulk_result()
  end

  defp locked_head(lock, scope \\ :system) do
    WorldHead
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == "global")
    |> Ash.Query.lock(lock)
    |> Ash.read_one(read_options(scope))
    |> present()
  end

  defp locked_layout(layout_version) do
    WorldLayout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(layout_version == ^layout_version)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor())
    |> present()
  end

  defp active_layout(head, scope \\ :system)
  defp active_layout(%{active_layout_version: nil}, _scope), do: reject(:not_ready)

  defp active_layout(%{active_layout_version: version}, scope) do
    WorldLayout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(layout_version == ^version and status == :active)
    |> Ash.read_one(read_options(scope))
    |> present()
  end

  defp present({:ok, nil}), do: reject(:not_ready)
  defp present(result), do: result
  defp building?(%{status: :building}), do: :ok
  defp building?(_layout), do: reject(:layout_already_published)

  defp expected_generation?(%{generation: generation}, generation), do: :ok
  defp expected_generation?(_head, _expected), do: reject(:stale_generation)

  defp retire_layout(nil), do: :ok

  defp retire_layout(layout_version) do
    with {:ok, previous} <- locked_layout(layout_version),
         {:ok, _retired} <- update(previous, :publish, %{status: :retired}) do
      :ok
    end
  end

  defp publish_head(head, layout_version) do
    update(head, :publish, %{
      active_layout_version: layout_version,
      generation: head.generation + 1
    })
  end

  defp update(record, action, attrs) do
    record
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(actor: actor())
  end

  defp insert_positions(version, rows) do
    each_batch(rows, fn batch ->
      batch
      |> Enum.map(&Map.put(&1, :layout_version, version))
      |> Ash.bulk_create(WorldPosition, :insert, bulk_options())
      |> bulk_result()
    end)
  end

  defp upsert_relations(version, rows) do
    each_batch(rows, fn batch ->
      with :ok <- verify_relation_endpoints(version, batch) do
        batch
        |> Enum.map(&Map.put(&1, :layout_version, version))
        |> Ash.bulk_create(WorldRelation, :upsert, bulk_options())
        |> bulk_result()
      end
    end)
  end

  defp verify_relation_endpoints(version, rows) do
    expected =
      rows
      |> Enum.filter(&Map.get(&1, :active, true))
      |> Enum.flat_map(&[Map.get(&1, :source_id), Map.get(&1, :target_id)])
      |> MapSet.new()

    ids = MapSet.to_list(expected)

    with {:ok, positions} <-
           WorldPosition
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(layout_version == ^version and device_id in ^ids and active)
           |> Ash.Query.select([:device_id])
           |> Ash.read(actor: actor(), page: false) do
      actual = MapSet.new(positions, & &1.device_id)
      if actual == expected, do: :ok, else: reject(:invalid_relation_endpoint)
    end
  end

  defp set_active(resource, version, id_field, ids, active) do
    each_batch(ids, fn batch ->
      resource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(layout_version == ^version)
      |> Ash.Query.filter(^[{id_field, [in: batch]}])
      |> Ash.bulk_update(:set_active, %{active: active}, bulk_options())
      |> bulk_result()
    end)
  end

  defp update_positions(version, rows) do
    each_batch(rows, fn batch ->
      batch
      |> Enum.map(fn %{device_id: id} = row ->
        {%{layout_version: version, device_id: id}, Map.take(row, [:label, :min_zoom])}
      end)
      |> Ash.update_many(WorldPosition, :update_display,
        actor: actor(),
        batch_size: @batch_size,
        return_errors?: true
      )
      |> bulk_result()
    end)
  end

  defp retire_positions(version, ids) do
    each_batch(ids, fn batch ->
      with :ok <- set_active(WorldPosition, version, :device_id, batch, false),
           {:ok, count} <-
             WorldRelation
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(
               layout_version == ^version and active and
                 (source_id in ^batch or target_id in ^batch)
             )
             |> Ash.count(actor: actor()) do
        if count == 0, do: :ok, else: reject(:active_relation_to_retired_device)
      end
    end)
  end

  defp verify_counts(layout, expected_nodes, expected_relations) do
    with {:ok, nodes} <- active_count(WorldPosition, layout.layout_version),
         {:ok, relations} <- active_count(WorldRelation, layout.layout_version) do
      if nodes == expected_nodes and relations == expected_relations do
        :ok
      else
        reject(:incomplete_world)
      end
    end
  end

  defp active_count(resource, version) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(layout_version == ^version and active)
    |> Ash.count(actor: actor())
  end

  defp stream_rows(resource, version, event, accumulator, callback) do
    id_field = if resource == WorldPosition, do: :device_id, else: :relation_id

    query =
      resource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(layout_version == ^version)
      |> Ash.Query.sort([{id_field, :asc}])
      |> Ash.Query.limit(@batch_size)

    query = if resource == WorldRelation, do: Ash.Query.filter(query, active), else: query

    # The held head lock fixes the layout, so the row ID is a complete cursor.
    # Ash's composite primary-key cursor adds an OR over layout_version; generic
    # PostgreSQL plans then rescan preceding rows on every page of a large world.
    nil
    |> Stream.unfold(fn cursor ->
      page =
        if cursor, do: Ash.Query.filter(query, ^[{id_field, [greater_than: cursor]}]), else: query

      case Ash.read!(page, actor: actor(), page: false) do
        [] -> nil
        rows -> {rows, rows |> List.last() |> Map.fetch!(id_field)}
      end
    end)
    |> Enum.reduce_while({:ok, accumulator}, fn rows, {:ok, acc} ->
      case callback.({event, rows}, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp each_batch(rows, callback) do
    rows
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case callback.(batch) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp bulk_options do
    [
      actor: actor(),
      return_errors?: true,
      return_records?: false,
      stop_on_error?: true,
      batch_size: @batch_size
    ]
  end

  defp bulk_result(%Ash.BulkResult{status: :success}), do: :ok
  defp bulk_result(%Ash.BulkResult{errors: errors}), do: {:error, errors}

  defp manifest(head, layout),
    do: layout |> Map.take(@manifest_fields) |> Map.put(:generation, head.generation)

  defp notify_publication({:ok, manifest} = result) do
    if Process.whereis(ServiceRadar.PubSub) do
      Phoenix.PubSub.broadcast(
        ServiceRadar.PubSub,
        "topology:world",
        {:topology_world_changed, Map.take(manifest, [:layout_version, :generation])}
      )
    end

    result
  end

  defp notify_publication(result), do: result

  defp reject(reason) do
    {:error,
     InvalidArgument.exception(
       field: :world,
       value: reason,
       message: "topology world validation failed"
     )}
  end

  defp transaction_result({:ok, result}), do: result

  defp transaction_result({:error, %InvalidArgument{field: :world, value: reason}}),
    do: {:error, reason}

  defp transaction_result(
         {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{field: :world, value: reason}]}}
       ),
       do: {:error, reason}

  defp transaction_result({:error, _reason} = error), do: error
  defp read_options(:system), do: [actor: actor(), timeout: @publication_timeout]
  defp read_options(scope), do: [scope: scope]
  defp actor, do: SystemActor.system(:topology_world)
end
