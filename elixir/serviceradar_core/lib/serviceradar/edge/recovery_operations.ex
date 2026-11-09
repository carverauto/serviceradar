defmodule ServiceRadar.Edge.RecoveryOperations do
  @moduledoc """
  Persists recovery intent before signing and received control evidence before ACK.

  Registration and JetStream receipt are separate facts. Replaying registration
  cannot manufacture received pages. A differing value under an existing identity
  blocks the operation durably; the original evidence is never overwritten.
  These records alone do not prove consumer repair or authorize journal deletion.
  """

  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.RecoveryGeneration, as: Generation
  alias ServiceRadar.Edge.RecoveryOperation
  alias ServiceRadar.Edge.RecoveryReceivedPage, as: Page
  alias ServiceRadar.Edge.RecoveryRegistration, as: Registration
  alias ServiceRadar.Edge.RecoveryTransaction
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias ServiceRadar.Edge.WireDecode

  require Ash.Query

  @doc "Register a validated plan under the independently authenticated agent."
  def register(agent_id, registration) do
    with :ok <- principal(agent_id),
         {:ok, _} <- RecoveryOperation.validate(registration) do
      attrs = %{
        network_scope_id: Ecto.UUID.cast!(registration.network_scope_id),
        agent_id: agent_id,
        recovery_id: Ecto.UUID.cast!(registration.recovery_id),
        registration: EdgeRecoveryRegistration.encode(registration),
        prior_spool_id: Ecto.UUID.cast!(registration.prior_spool_id),
        from_sequence: Decimal.new(registration.from_sequence),
        through_sequence: Decimal.new(registration.through_sequence)
      }

      transaction(fn ->
        with {:ok, _} <- create(Registration, :register, attrs),
             {:ok, current} <- locked(attrs) do
          if current.registration == attrs.registration,
            do: register_interval(current, registration),
            else: block(current, "registration_conflict")
        end
      end)
    end
  end

  # Lock the operation before its generation throughout this owner. Generation
  # progress reads sibling operations without taking their row locks, so two
  # completed intervals cannot acquire these locks in opposite orders.
  defp register_interval(%{blocked_reason: reason} = current, _) when not is_nil(reason),
    do: {:ok, current}

  defp register_interval(current, registration) do
    attrs = %{
      network_scope_id: current.network_scope_id,
      agent_id: current.agent_id,
      prior_spool_id: current.prior_spool_id,
      route_profile:
        Serviceradar.Edge.V1.EdgeRecordRouteProfile.value(registration.route_profile),
      traffic_class:
        Serviceradar.Edge.V1.EdgeRecordTrafficClass.value(registration.traffic_class),
      source_high_water: Decimal.new(registration.source_high_water),
      reclaim_watermark: Decimal.new(registration.source_reclaim_watermark),
      applied_through: Decimal.new(registration.source_reclaim_watermark)
    }

    with {:ok, _} <- create(Generation, :freeze, attrs),
         {:ok, generation} <- locked_generation(current) do
      if same_generation?(generation, attrs),
        do: disjoint_interval(current),
        else: block(current, "source_generation_conflict")
    end
  end

  defp same_generation?(generation, attrs) do
    generation.route_profile == attrs.route_profile and
      generation.traffic_class == attrs.traffic_class and
      Decimal.equal?(generation.source_high_water, attrs.source_high_water) and
      Decimal.equal?(generation.reclaim_watermark, attrs.reclaim_watermark)
  end

  defp disjoint_interval(current) do
    # The predecessor by start is enough because every admitted interval is
    # disjoint. Bound both database work and returned rows; never load a tail.
    nearest =
      Registration
      |> generation_query(current)
      |> Ash.Query.filter(
        interval_registered == true and id != ^current.id and
          from_sequence <= ^current.through_sequence
      )
      |> Ash.Query.sort(from_sequence: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one(actor: actor())

    case nearest do
      {:ok, nil} ->
        update(current, :admit_interval, %{})

      {:ok, other} ->
        if Decimal.compare(other.through_sequence, current.from_sequence) == :lt,
          do: update(current, :admit_interval, %{}),
          else: block(current, "source_interval_overlap")

      error ->
        error
    end
  end

  defp generation_query(resource, key) do
    resource
    |> Ash.Query.filter(network_scope_id == ^key.network_scope_id and agent_id == ^key.agent_id)
    |> Ash.Query.filter(prior_spool_id == ^key.prior_spool_id)
  end

  defp locked_generation(key),
    do:
      Generation
      |> generation_query(key)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(actor: actor())

  @doc "Read intent using the full authenticated namespace. Missing is not resolved."
  def fetch(scope, agent_id, recovery_id) do
    with {:ok, key} <- key(scope, agent_id, recovery_id) do
      key |> query() |> Ash.read_one(actor: actor())
    end
  end

  @doc """
  Record a page or tombstone delivered by the recovery consumer after composed
  record authorization. An RPC registration never calls this receipt boundary.
  A conflict is returned as a committed blocked row so callers can quarantine
  the offending delivery without rolling back the integrity fence.
  """
  def receive_control(scope, agent_id, raw) do
    with {:ok, payload} <- WireDecode.decode_recovery_control(raw),
         {:ok, {recovery_id, _}} <- RecoveryValidate.control_body(payload),
         {:ok, key} <- key(scope, agent_id, recovery_id),
         :ok <- agent_body(payload) do
      transaction(fn ->
        with {:ok, current} when not is_nil(current) <- locked(key),
             {:ok, expected} <- decode_registration(current) do
          receive_body(current, expected, payload, raw)
        else
          {:ok, nil} -> {:error, :registration_missing}
          error -> error
        end
      end)
    end
  end

  @doc "Decode and revalidate stored intent before using it to issue authority."
  def decode_registration(%Registration{registration: bytes}) do
    with {:ok, registration} <- WireDecode.decode_recovery_registration(bytes) do
      RecoveryOperation.validate(registration)
    end
  end

  defp receive_body(%{blocked_reason: reason} = current, _, _, _) when not is_nil(reason),
    do: {:ok, current}

  defp receive_body(current, expected, %{body: {:tombstone, tombstone}}, _raw) do
    if tombstone == expected.tombstone,
      do: update(current, :receive_tombstone, %{}),
      else: block(current, "tombstone_conflict")
  end

  defp receive_body(current, expected, %{body: {:manifest_page, page}}, raw) do
    if Enum.at(expected.pages, page.page_index) == page do
      attrs = %{
        network_scope_id: current.network_scope_id,
        agent_id: current.agent_id,
        recovery_id: current.recovery_id,
        page_index: page.page_index,
        page_sha256: page.page_sha256,
        payload: raw
      }

      with {:ok, received} <- create(Page, :receive, attrs) do
        if received.page_sha256 == page.page_sha256,
          do: {:ok, current},
          else: block(current, "page_conflict")
      end
    else
      block(current, "page_conflict")
    end
  end

  defp agent_body(%EdgeRecoveryControlPayloadV1{body: {kind, _}})
       when kind in [:manifest_page, :tombstone], do: :ok

  defp agent_body(_), do: {:error, :agent_resolution_forbidden}

  defp key(scope, agent_id, recovery_id) do
    with :ok <- principal(agent_id),
         {:ok, scope} <- Ecto.UUID.cast(scope),
         {:ok, recovery_id} <- Ecto.UUID.cast(recovery_id) do
      {:ok, %{network_scope_id: scope, agent_id: agent_id, recovery_id: recovery_id}}
    else
      _ -> {:error, :recovery_identity}
    end
  end

  defp principal(agent) when is_binary(agent) and byte_size(agent) in 1..256 do
    if String.valid?(agent) and not String.contains?(agent, <<0>>),
      do: :ok,
      else: {:error, :authenticated_agent}
  end

  defp principal(_), do: {:error, :authenticated_agent}

  defp query(key) do
    Registration
    |> Ash.Query.filter(network_scope_id == ^key.network_scope_id)
    |> Ash.Query.filter(agent_id == ^key.agent_id and recovery_id == ^key.recovery_id)
  end

  defp locked(key),
    do: key |> query() |> Ash.Query.lock(:for_update) |> Ash.read_one(actor: actor())

  defp block(%{blocked_reason: nil} = current, reason),
    do: update(current, :block, %{blocked_reason: reason})

  defp block(current, _reason), do: {:ok, current}

  defp create(resource, action, attrs),
    do:
      resource
      |> Ash.Changeset.for_create(action, attrs, actor: actor())
      |> Ash.create(actor: actor())

  defp update(record, action, attrs),
    do:
      record
      |> Ash.Changeset.for_update(action, attrs, actor: actor())
      |> Ash.update(actor: actor())

  defp actor, do: SystemActor.system(:edge_recovery)

  defp transaction(fun), do: RecoveryTransaction.run([Registration, Page, Generation], fun)
end
