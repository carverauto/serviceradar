defmodule ServiceRadar.SweepJobs.RecoveryRetryIntents do
  @moduledoc """
  Records the disposition of recovery work after the existing lease pass has
  reconciled current desired work successfully. It never expands an old plan's
  target tail or recreates obsolete lifecycle rows. Original range loss remains
  explicit even when desired work has moved to a new plan or is now obsolete.
  """

  alias ServiceRadar.Edge.RecoveryAssignment
  alias ServiceRadar.Edge.RecoveryRetryIntent
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ash.Query

  @scheduled_sweep Serviceradar.Edge.V1.EdgeSourceAuthorizationKind.value(
                     :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP
                   )

  @doc "Drain at most 100 intents that existed before this successful lease pass began."
  def reconciled_before(%DateTime{} = started_at) do
    with {:ok, intents} <-
           RecoveryRetryIntent
           |> Ash.Query.filter(
             scheduler == :sweep and disposition == :pending and inserted_at <= ^started_at
           )
           |> Ash.Query.sort(inserted_at: :asc, id: :asc)
           |> Ash.Query.limit(100)
           |> Ash.read(actor: actor()) do
      Enum.reduce_while(intents, {:ok, 0}, fn intent, {:ok, count} ->
        with {:ok, work?} <- current_work?(intent),
             {:ok, _} <- mark(intent, if(work?, do: :reconciled, else: :obsolete)) do
          {:cont, {:ok, count + 1}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp current_work?(
         %{intent_key: %{"kind" => "generation", "prior_spool_id" => prior} = key} = intent
       )
       when map_size(key) == 2 do
    case Ecto.UUID.cast(prior) do
      {:ok, _} -> intent |> assignments() |> Ash.exists(actor: actor())
      :error -> {:error, :corrupt_retry_intent}
    end
  end

  defp current_work?(
         %{intent_key: %{"kind" => "range", "mapping_key" => mapping_key} = key} = intent
       )
       when map_size(key) == 2 do
    namespace = [
      Base.encode16(Ecto.UUID.dump!(intent.network_scope_id), case: :lower),
      intent.agent_id
    ]

    with :ok <- RecoveryAssignment.validate_value(mapping_key, intent.mapping_value),
         true <- mapping_key["trust_namespace"] == namespace do
      case restrict_scheduled_group(assignments(intent), mapping_key) do
        {:error, _} = error -> error
        query -> Ash.exists(query, actor: actor())
      end
    else
      _ -> {:error, :corrupt_retry_intent}
    end
  end

  defp current_work?(_), do: {:error, :corrupt_retry_intent}

  # Only scheduled-sweep source authority makes the production scope a sweep group.
  defp restrict_scheduled_group(query, %{
         "span_identity" => [_, _, _, _, group, _, _, [@scheduled_sweep, _, _, _] | _]
       }) do
    group_id = group |> Base.decode16!(case: :lower) |> Ecto.UUID.cast!()
    Ash.Query.filter(query, sweep_group_id == ^group_id)
  end

  defp restrict_scheduled_group(_query, _), do: {:error, :unsupported_retry_source}

  defp assignments(intent),
    do:
      Ash.Query.filter(
        SweepProducerAssignment,
        network_scope_id == ^intent.network_scope_id and agent_id == ^intent.agent_id and
          state == :active
      )

  defp mark(intent, disposition) do
    intent
    |> Ash.Changeset.for_update(:reconcile, %{disposition: disposition}, actor: actor())
    |> Ash.Changeset.filter(disposition: :pending)
    |> Ash.update()
    |> case do
      {:error, %Ash.Error.Invalid{errors: errors}} = error ->
        if errors != [] and Enum.all?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
          do: {:ok, :already_reconciled},
          else: error

      result ->
        result
    end
  end

  defp actor, do: ServiceRadar.Actors.SystemActor.system(:recovery_retry_intents)
end
