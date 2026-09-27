defmodule ServiceRadar.NetworkDiscovery.WorldRetention do
  @moduledoc """
  Reclaims expired coordinate systems without deleting a visible or unfinished world.

  Each transaction removes at most 500 relation or position rows. The current
  layout and the most recently retired layout are retained. Older retired
  layouts and abandoned builds become eligible after 24 hours. Metadata stays
  until every row is gone, so interrupted cleanup resumes on its next pass.
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.NetworkDiscovery.WorldHead
  alias ServiceRadar.NetworkDiscovery.WorldLayout
  alias ServiceRadar.NetworkDiscovery.WorldPosition
  alias ServiceRadar.NetworkDiscovery.WorldRelation
  alias ServiceRadar.NetworkDiscovery.WorldWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query

  @resources [WorldHead, WorldLayout, WorldPosition, WorldRelation]
  @terminal_states ["completed", "discarded", "cancelled"]
  @batch_size 500

  @doc "Deletes one bounded batch from an expired, unowned layout."
  def prune_batch do
    @resources
    |> Ash.transact(fn ->
      with {:ok, _head} <- initialize_head(),
           {:ok, head} <- locked_head(),
           {:ok, retained} <- most_recent_retired(),
           {:ok, candidate} <- candidate(head, retained) do
        prune_candidate(candidate, head, retained)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp initialize_head do
    WorldHead
    |> Ash.Changeset.for_create(:initialize, %{})
    |> Ash.create(actor: actor())
  end

  defp locked_head do
    WorldHead
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == "global")
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(actor: actor())
  end

  defp most_recent_retired do
    WorldLayout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status == :retired)
    |> Ash.Query.sort(updated_at: :desc, layout_version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor())
  end

  defp candidate(head, retained) do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)
    worker = Oban.Worker.to_string(WorldWorker)

    query =
      WorldLayout
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status in [:building, :retired] and updated_at < ^cutoff)
      # Avoid an old incomplete job hiding every eligible layout behind it.
      # Oban and these resources share the platform schema. The selected job
      # rows are locked and checked again before any deletion below.
      |> Ash.Query.filter(
        fragment(
          "NOT EXISTS (SELECT 1 FROM platform.oban_jobs AS job WHERE job.worker = ? AND job.args ->> 'layout_version' = ?::text AND job.state NOT IN ('completed', 'discarded', 'cancelled'))",
          ^worker,
          layout_version
        )
      )
      |> exclude(head.active_layout_version)
      |> exclude(retained && retained.layout_version)
      |> Ash.Query.sort(updated_at: :asc, layout_version: :asc)
      |> Ash.Query.limit(1)

    Ash.read_one(query, actor: actor())
  end

  defp exclude(query, nil), do: query
  defp exclude(query, version), do: Ash.Query.filter(query, layout_version != ^version)

  defp prune_candidate(nil, _head, _retained), do: {:ok, :idle}

  defp prune_candidate(candidate, head, retained) do
    # Retrying a terminal Oban job updates this same row. Hold its lock through
    # deletion so it cannot become an executing owner midway through a batch.
    jobs =
      Repo.all(
        from(job in Oban.Job,
          where: job.worker == ^Oban.Worker.to_string(WorldWorker),
          where: fragment("? ->> 'layout_version'", job.args) == ^candidate.layout_version,
          select: %{id: job.id, state: job.state},
          lock: "FOR UPDATE"
        ),
        prefix: ObanSupport.prefix()
      )

    if Enum.all?(jobs, &(&1.state in @terminal_states)) do
      with {:ok, layout} <- locked_layout(candidate.layout_version) do
        if eligible?(layout, head, retained), do: delete_batch(layout), else: {:ok, :skipped}
      end
    else
      {:ok, :skipped}
    end
  end

  defp locked_layout(version) do
    WorldLayout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(layout_version == ^version)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(actor: actor())
  end

  defp eligible?(nil, _head, _retained), do: false

  defp eligible?(layout, head, retained) do
    layout.status in [:building, :retired] and
      layout.layout_version != head.active_layout_version and
      (is_nil(retained) or layout.layout_version != retained.layout_version) and
      DateTime.diff(DateTime.utc_now(), layout.updated_at, :second) >= 86_400
  end

  defp delete_batch(layout) do
    with {:ok, relations} <- rows(WorldRelation, layout.layout_version) do
      case relations do
        [] -> delete_positions(layout)
        rows -> destroy_rows(rows, layout.layout_version)
      end
    end
  end

  defp delete_positions(layout) do
    with {:ok, positions} <- rows(WorldPosition, layout.layout_version) do
      case positions do
        [] ->
          with :ok <- Ash.destroy(layout, action: :discard, actor: actor()) do
            {:ok,
             %{layout_version: layout.layout_version, deleted_rows: 0, deleted_layout?: true}}
          end

        rows ->
          destroy_rows(rows, layout.layout_version)
      end
    end
  end

  defp rows(resource, version) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(layout_version == ^version)
    |> Ash.Query.limit(@batch_size)
    |> Ash.read(actor: actor(), page: false)
  end

  defp destroy_rows(rows, version) do
    case Ash.bulk_destroy(rows, :discard, %{},
           actor: actor(),
           batch_size: @batch_size,
           return_errors?: true,
           stop_on_error?: true
         ) do
      %Ash.BulkResult{status: :success} ->
        {:ok, %{layout_version: version, deleted_rows: length(rows), deleted_layout?: false}}

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  defp actor, do: SystemActor.system(:topology_world_retention)
end
