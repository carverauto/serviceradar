defmodule ServiceRadarAgentGateway.EdgeContractRegistry do
  @moduledoc """
  The output-contract registry snapshot the gateway admits edge records against, and the
  admission decision itself (unify-sweep-results-proto task 3.8, NARROWED SLICE).

  ## What this slice is, and what it deliberately is not

  Task 3.8 asks the gateway to load "the same signed output-contract/route registry epoch as the
  agent and EventWriter". No such signed format exists yet: tasks 1.10/1.11 DEFINE the signed
  snapshot, the bundle digest contents, the lifecycle transitions and the readiness attestation,
  and neither is done. Neither the agent nor EventWriter loads a registry today. Inventing that
  format inside the gateway would silently decide 1.10/1.11, so this module does not.

  What it does instead is the part that does not depend on the format:

    * a `c:snapshot/0` behaviour, so a later signed loader replaces the SOURCE without touching
      the admission rules or their caller;
    * `ServiceRadarAgentGateway.EdgeContractRegistry.Static`, an installation-static
      implementation configured per deployment (for task 0.12, exactly the Sweep contract);
    * `admit/3`, which classifies every frame BEFORE anything is published.

  DEFERRED until 1.10/1.11 define the format, and NOT implemented here: signed snapshot loading
  and verification, signed readiness reporting, the atomic active-epoch switch and stale
  generation fencing that goes with it, and planned-retirement backlog continuation under an
  exact draining bundle and watermark. Task 3.8 therefore stays unchecked.

  ## The decision

  `admit/3` returns one of four classes, and the caller treats each differently:

    * `{:ok, route}` -- publish, using ONLY the route the registry entry pins
      (`route_profile`, `traffic_class`, `partition_rule`). Nothing on the frame selects them.
    * `{:reject, reason}` -- proven invalid for this session and snapshot; resolves as a
      permanent rejection. Only claims that cannot be explained by rollout lag land here: a record
      naming no output contract, a route or cost model the bundle does not pin, or provenance
      that disagrees with the authenticated session.
    * `{:withhold, reason}` -- not publishable NOW, but not proof of poison: no registry loaded,
      an epoch or snapshot the gateway does not hold, a contract the held snapshot does not
      contain or registers under a different bundle digest, or a bundle that is not `active`
      (candidate, ready, draining, retired). The sequence stays unresolved. A rollout mismatch is
      never converted into poison. Until 1.10/1.11 define a signed snapshot, the epoch and
      snapshot digest are operator-supplied labels nothing verifies against the contract list, so
      two documents can carry the same labels and differ in their contracts; a record naming the
      held labels but a contract or bundle digest this snapshot lacks is therefore still lag.
    * `{:hold, reason}` -- a `security_revoked` bundle. Never published and never resolved, and
      reported separately from a withhold: compromise is not ordinary retirement.

  ## Provenance is compared, never trusted

  The session -- the authenticated agent identity and the opened lane -- is the authority. The
  record's `origin_principal_id` must equal the authenticated component id, and its route
  profile and traffic class must equal both the lane and the bundle. The gateway still derives
  the published subject, partition and destination from the registry entry and the authenticated
  slot, so a guest-supplied value can at most cause a rejection, never a different placement.

  Network scope is NOT compared against the session here: the session carries no network scope,
  and binding scope to the agent is the effective-grant verification of task 3.2.
  """

  alias Serviceradar.Edge.V1.EdgeRecordV1

  @type state :: :candidate | :ready | :active | :draining | :retired | :security_revoked

  @type entry :: %{
          contract_id: String.t(),
          contract_version: pos_integer(),
          contract_bundle_sha256: <<_::256>>,
          state: state(),
          route_profile: atom(),
          traffic_class: atom(),
          partition_rule: atom(),
          cost_model_version: pos_integer()
        }

  @type snapshot :: %{
          registry_epoch: pos_integer(),
          registry_snapshot_sha256: <<_::256>>,
          contracts: %{optional({String.t(), pos_integer()}) => entry()}
        }

  @type session :: %{
          authenticated_agent_id: String.t(),
          route_profile: atom(),
          traffic_class: atom()
        }

  @type route :: %{route_profile: atom(), traffic_class: atom(), partition_rule: atom()}

  @type decision ::
          {:ok, route()}
          | {:reject, atom()}
          | {:withhold, atom() | {atom(), state()}}
          | {:hold, :security_revoked}

  @doc "The snapshot this gateway currently admits against, or why none is available."
  @callback snapshot() :: {:ok, snapshot()} | {:error, term()}

  @doc "The configured registry implementation."
  @spec impl() :: module()
  def impl do
    Application.get_env(
      :serviceradar_agent_gateway,
      :edge_record_contract_registry_impl,
      __MODULE__.Static
    )
  end

  @doc "Whether a snapshot is loaded. A gateway without one would withhold every frame."
  @spec available?() :: boolean()
  def available? do
    match?({:ok, _snapshot}, impl().snapshot())
  end

  @doc """
  Classifies one decoded record for one authenticated session against the current snapshot.

  See the moduledoc for the four classes. Session checks run first: they need no registry, and a
  frame whose provenance disagrees with its session is invalid whatever the registry says.
  """
  @spec admit(EdgeRecordV1.t(), session(), {:ok, snapshot()} | {:error, term()}) :: decision()
  def admit(%EdgeRecordV1{} = record, session, loaded) do
    with :ok <- provenance(record, session),
         {:ok, snapshot} <- available(loaded),
         {:ok, entry} <- lookup(record.output_contract, snapshot),
         :ok <- lifecycle(entry),
         :ok <- pinned(record, entry) do
      {:ok, Map.take(entry, [:route_profile, :traffic_class, :partition_rule])}
    end
  end

  defp provenance(record, session) do
    principal = record.producer_context && record.producer_context.origin_principal_id

    cond do
      principal != session.authenticated_agent_id -> {:reject, :principal_mismatch}
      record.route_profile != session.route_profile -> {:reject, :lane_conflict}
      record.traffic_class != session.traffic_class -> {:reject, :lane_conflict}
      true -> :ok
    end
  end

  defp available({:ok, snapshot}), do: {:ok, snapshot}
  defp available(_), do: {:withhold, :registry_unavailable}

  defp lookup(nil, _snapshot), do: {:reject, :contract_missing}

  defp lookup(contract, snapshot) do
    cond do
      contract.registry_epoch > snapshot.registry_epoch ->
        {:withhold, :registry_epoch_ahead}

      contract.registry_epoch < snapshot.registry_epoch ->
        {:withhold, :registry_epoch_stale}

      contract.registry_snapshot_sha256 != snapshot.registry_snapshot_sha256 ->
        {:withhold, :registry_snapshot_mismatch}

      true ->
        case Map.fetch(snapshot.contracts, {contract.contract_id, contract.contract_version}) do
          :error ->
            {:withhold, :unknown_contract}

          {:ok, %{contract_bundle_sha256: digest} = entry} when digest == contract.contract_bundle_sha256 ->
            {:ok, entry}

          {:ok, _entry} ->
            {:withhold, :contract_digest_mismatch}
        end
    end
  end

  defp lifecycle(%{state: :active}), do: :ok
  defp lifecycle(%{state: :security_revoked}), do: {:hold, :security_revoked}
  defp lifecycle(%{state: state}), do: {:withhold, {:contract_not_active, state}}

  # The session already equals the record's lane (provenance/2), so comparing the record here also
  # binds the lane to the bundle's pinned route.
  defp pinned(record, entry) do
    cond do
      record.route_profile != entry.route_profile -> {:reject, :route_conflict}
      record.traffic_class != entry.traffic_class -> {:reject, :route_conflict}
      record.cost_model_version != entry.cost_model_version -> {:reject, :cost_model_mismatch}
      true -> :ok
    end
  end
end
