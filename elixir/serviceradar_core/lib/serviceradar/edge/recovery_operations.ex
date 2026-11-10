defmodule ServiceRadar.Edge.RecoveryOperations do
  @moduledoc """
  Persists recovery intent before signing and received control evidence before ACK.

  Registration and JetStream receipt are separate facts. Replaying registration
  cannot manufacture received pages. A differing value under an existing identity
  blocks the operation durably; the original evidence is never overwritten.
  These records alone do not prove consumer repair or authorize journal deletion.
  """

  alias Monitoring.EdgeRecoveryRegistration
  alias Monitoring.EdgeRecoveryStatus
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.RecoveryEffects
  alias ServiceRadar.Edge.RecoveryGeneration, as: Generation
  alias ServiceRadar.Edge.RecoveryOperation
  alias ServiceRadar.Edge.RecoveryProjectionCost
  alias ServiceRadar.Edge.RecoveryReceivedPage, as: Page
  alias ServiceRadar.Edge.RecoveryRegistration, as: Registration
  alias ServiceRadar.Edge.RecoveryTransaction
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias Serviceradar.Edge.V1.RecoveryResolvedV1
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

  @doc "Return the original completion, issuing it only after contiguous consumer progress."
  def status(scope, agent_id, recovery_id) do
    with {:ok, key} <- key(scope, agent_id, recovery_id) do
      transaction(fn ->
        case locked(key) do
          {:ok, nil} -> {:error, :registration_missing}
          {:ok, current} -> completion_status(current)
          error -> error
        end
      end)
    end
  end

  defp completion_status(%{blocked_reason: reason}) when not is_nil(reason),
    do: {:ok, %EdgeRecoveryStatus{state: :EDGE_RECOVERY_STATE_BLOCKED, reason: reason}}

  defp completion_status(%{completion_status: raw}) when is_binary(raw) do
    {:ok, EdgeRecoveryStatus.decode(raw)}
  rescue
    _ -> {:error, :completion_corrupt}
  end

  defp completion_status(%{effects_state: :applied} = current) do
    with {:ok, generation} <- locked_generation(current),
         {:ok, generation} <- advance_prefix(generation) do
      if Decimal.compare(generation.applied_through, current.through_sequence) in [:eq, :gt],
        do: persist_completion(current, generation),
        else: pending_status(:pending, "coverage_pending")
    end
  end

  defp completion_status(current), do: pending_status(current.effects_state, "consumer_pending")

  defp pending_status(:blocked, reason),
    do: {:ok, %EdgeRecoveryStatus{state: :EDGE_RECOVERY_STATE_BLOCKED, reason: reason}}

  defp pending_status(_, reason),
    do: {:ok, %EdgeRecoveryStatus{state: :EDGE_RECOVERY_STATE_PENDING, reason: reason}}

  defp persist_completion(current, generation) do
    with {:ok, expected} <- decode_registration(current),
         {:ok, issuer} <- IssuerKey.configured() do
      now = System.system_time(:nanosecond)

      resolved = %RecoveryResolvedV1{
        recovery_id: Ecto.UUID.dump!(current.recovery_id),
        manifest_root_sha256: expected.tombstone.manifest_root_sha256,
        applied_through_sequence: Decimal.to_integer(generation.applied_through),
        resolved_at_unix_nano: now
      }

      # This finite window describes issuance for historical key validation. It
      # is not a production deadline: agents verify it as a completion receipt.
      capability =
        IssuerKey.sign(
          %EdgeSignedCapabilityV1{
            not_before_unix_nano: now,
            expires_at_unix_nano: now + 15 * 60 * 1_000_000_000,
            claims:
              {:source,
               %EdgeSourceClaimsV1{
                 kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
                 network_scope_id: Ecto.UUID.dump!(current.network_scope_id),
                 origin_principal_id: current.agent_id,
                 context_id: resolved.recovery_id,
                 scope_id: resolved.recovery_id,
                 scope_sha256: HashGrammar.resolved_scope_digest(resolved)
               }}
          },
          issuer
        )

      status = %EdgeRecoveryStatus{
        state: :EDGE_RECOVERY_STATE_RESOLVED,
        resolved: resolved,
        resolution_capability: capability
      }

      with {:ok, _} <-
             update(current, :complete, %{completion_status: EdgeRecoveryStatus.encode(status)}),
           do: {:ok, status}
    end
  end

  @doc """
  Receives an authenticated JetStream control record and commits its repair effects.
  An incomplete manifest returns received after storing its exact bytes, allowing
  the broker window to deliver the remaining pages. Complete manifests with mapping
  failures return pending/blocked and must be deferred after commit. Only complete,
  applied manifests return applied. Registration cannot call here.
  """
  def consume_control(scope, agent_id, raw, declared_cost) do
    with {:ok, payload} <- WireDecode.decode_recovery_control(raw),
         {:ok, {recovery_id, _}} <- RecoveryValidate.control_body(payload),
         {:ok, key} <- key(scope, agent_id, recovery_id),
         :ok <- agent_body(payload) do
      transaction(fn ->
        with {:ok, current} when not is_nil(current) <- locked(key),
             {:ok, expected} <- decode_registration(current),
             :ok <- RecoveryProjectionCost.validate(expected.pages, declared_cost),
             {:ok, current} <- receive_body(current, expected, payload, raw),
             {:ok, generation} <- locked_generation(current),
             {:ok, state} <- apply_received(current, expected),
             {:ok, _} <- advance_prefix(generation) do
          {:ok, state}
        else
          {:ok, nil} -> {:error, :registration_missing}
          error -> error
        end
      end)
    end
  end

  defp apply_received(%{blocked_reason: reason}, _) when not is_nil(reason), do: {:ok, :blocked}

  defp apply_received(%{effects_state: :applied}, _), do: {:ok, :applied}
  defp apply_received(%{tombstone_received: false}, _), do: {:ok, :received}

  defp apply_received(current, expected) do
    count_query =
      Page
      |> Ash.Query.filter(
        network_scope_id == ^current.network_scope_id and agent_id == ^current.agent_id
      )
      |> Ash.Query.filter(recovery_id == ^current.recovery_id)

    with {:ok, count} <- Ash.count(count_query, actor: actor()) do
      if count == length(expected.pages) do
        with {:ok, state} <-
               RecoveryEffects.apply_manifest(
                 Ecto.UUID.dump!(current.network_scope_id),
                 current.agent_id,
                 expected.tombstone,
                 expected.pages
               ),
             {:ok, _} <- update(current, :apply_effects, %{effects_state: state}),
             do: {:ok, state}
      else
        {:ok, :received}
      end
    end
  end

  # A complete union describes only its selected interval. Unknown earlier
  # intervals stop progress; absence from a later manifest cannot close a hole.
  # Each transaction visits at most 64 intervals, not the source's whole tail.
  defp advance_prefix(generation) do
    query =
      Registration
      |> generation_query(generation)
      |> Ash.Query.filter(
        interval_registered == true and from_sequence > ^generation.applied_through
      )
      |> Ash.Query.sort(from_sequence: :asc)
      |> Ash.Query.limit(64)

    with {:ok, intervals} <- Ash.read(query, actor: actor()) do
      prefix =
        Enum.reduce_while(intervals, Decimal.to_integer(generation.applied_through), fn interval,
                                                                                        prefix ->
          if Decimal.to_integer(interval.from_sequence) == prefix + 1 and
               interval.effects_state == :applied and is_nil(interval.blocked_reason),
             do: {:cont, Decimal.to_integer(interval.through_sequence)},
             else: {:halt, prefix}
        end)

      if Decimal.equal?(generation.applied_through, prefix),
        do: {:ok, generation},
        else: update(generation, :advance, %{applied_through: Decimal.new(prefix)})
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

  defp transaction(fun),
    do:
      RecoveryTransaction.run(
        [Registration, Page, Generation] ++ RecoveryEffects.resources(),
        fun
      )
end
