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
        registration: EdgeRecoveryRegistration.encode(registration)
      }

      transaction(fn ->
        with {:ok, _} <- create(Registration, :register, attrs),
             {:ok, current} <- locked(attrs) do
          if current.registration == attrs.registration,
            do: {:ok, current},
            else: block(current, "registration_conflict")
        end
      end)
    end
  end

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

  defp transaction(fun), do: RecoveryTransaction.run([Registration, Page], fun)
end
