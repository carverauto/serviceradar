defmodule ServiceRadar.Edge.RecoveryCoverage do
  @moduledoc """
  Reads consumer-committed coverage for one authenticated source generation.

  Registration alone leaves the prefix at the frozen reclaim watermark. Only
  RecoveryOperations advances it after consumer effects commit. This read issues
  no completion proof and cannot advance a gateway's ordinary delivery prefix.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.RecoveryEffects
  alias ServiceRadar.Edge.RecoveryGeneration
  alias Serviceradar.Edge.V1.EdgeRecordRouteProfile
  alias Serviceradar.Edge.V1.EdgeRecordTrafficClass

  require Ash.Query

  @doc "Read one exact generation and lane; missing data and unavailable storage are distinct."
  def lookup(scope, agent, prior_spool, route, traffic)
      when is_binary(scope) and byte_size(scope) == 16 and is_binary(prior_spool) and
             byte_size(prior_spool) == 16 and
             is_binary(agent) and byte_size(agent) in 1..256 do
    with {:ok, _lane} <- PublisherLane.for_lane(route, traffic),
         {:ok, scope_id} <- Ecto.UUID.cast(scope),
         {:ok, spool_id} <- Ecto.UUID.cast(prior_spool),
         {:ok, generation} <-
           RecoveryGeneration
           |> Ash.Query.filter(
             network_scope_id == ^scope_id and agent_id == ^agent and prior_spool_id == ^spool_id
           )
           |> Ash.read_one(actor: SystemActor.system(:edge_recovery_coverage)) do
      coverage(generation, scope, agent, prior_spool, route, traffic)
    else
      :error -> {:error, :recovery_identity}
      error -> error
    end
  end

  def lookup(_, _, _, _, _), do: {:error, :recovery_identity}

  defp coverage(nil, _scope, _agent, _prior, _route, _traffic), do: {:ok, :none}

  defp coverage(generation, scope, agent, prior, route, traffic) do
    if generation.route_profile == EdgeRecordRouteProfile.value(route) and
         generation.traffic_class == EdgeRecordTrafficClass.value(traffic) do
      with {:ok, fenced} <- RecoveryEffects.generation_fenced?(scope, agent, prior) do
        {:ok,
         %{
           applied_through: Decimal.to_integer(generation.applied_through),
           source_high_water: Decimal.to_integer(generation.source_high_water),
           reclaim_watermark: Decimal.to_integer(generation.reclaim_watermark),
           fenced: fenced
         }}
      end
    else
      {:error, :recovery_lane_conflict}
    end
  end
end
