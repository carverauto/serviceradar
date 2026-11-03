defmodule ServiceRadar.Edge.DeliveryGrants do
  @moduledoc """
  Issues the per-record delivery grants a reconnecting agent drains its spool backlog under
  (unify-sweep-results-proto M2.0g, "Delivery after reconnect" in `design.md`).

  A spooled record carries the production grant it was produced under. When an agent stays
  disconnected past that grant's window, the gateway refuses the record as `authority_expired`
  and it can never be delivered as it stands: its bytes are immutable, so it cannot be re-signed.
  A delivery grant is the separate authority that lets those exact bytes drain: an
  `EdgeDeliveryClaimsV1` same-spool RENEWAL naming the record's `event_id`, `record_sha256`,
  `spool_id` and `sequence`, signed by core's issuer key for the `delivery` purpose. It grants no
  production or source right, and it does not relax collection: the gateway still checks the
  record's event time against its original collection window.

  The gateway verifies the record bytes, their production grant and their origin against the
  authenticated agent before it calls this, and passes the record's coordinates. This module
  decides the one thing only core knows: whether the authority the record names is one this
  agent still holds. A grant is issued only for a record whose producer assignment exists,
  belongs to the requesting agent under the record's network scope and run shard, and is
  `active`. A revoked assignment gets no delivery grant: its records are then refused at the
  gateway as a stale fence. An active assignment whose epoch has moved on does get one, and the
  gateway publishes such a record for audit only (`LATE_FENCED_DELIVERY`).

  A grant is short-lived (`ttl_seconds/0`): it authorizes a drain that is happening now, and the
  agent asks again for whatever it has not delivered when the grant lapses.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrant
  alias Serviceradar.Edge.V1.EdgeDeliveryClaimsV1
  alias Serviceradar.Edge.V1.EdgeDeliveryRenewalV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ash.Query

  @ttl_seconds 15 * 60
  @max_items 64

  @type item :: %{
          sequence: pos_integer(),
          spool_id: <<_::128>>,
          event_id: <<_::128>>,
          record_sha256: <<_::256>>,
          network_scope_id: <<_::128>>,
          producer_assignment_id: <<_::128>>,
          run_shard: non_neg_integer()
        }

  @type result :: %{
          sequence: pos_integer(),
          delivery_capability: EdgeSignedCapabilityV1.t() | nil,
          refusal: atom() | nil
        }

  @doc "How long an issued grant authorizes delivery."
  def ttl_seconds, do: @ttl_seconds

  @doc "The most records one call may name."
  def max_items, do: @max_items

  @doc """
  Issues a grant, or a refusal, for each item, in order, using the configured issuer key.

  Refusals: `:unknown_assignment`, `:assignment_revoked`, `:not_assignment_owner` (another agent,
  network scope or run shard). `{:error, :not_configured}` when core has no issuer key and
  `{:error, :too_many_items}` past `max_items/0`.
  """
  @spec issue(String.t(), [item()]) :: {:ok, [result()]} | {:error, term()}
  def issue(agent_id, items) do
    with {:ok, key} <- IssuerKey.configured(), do: issue(agent_id, items, key, DateTime.utc_now())
  end

  @doc false
  @spec issue(String.t(), [item()], IssuerKey.t(), DateTime.t()) ::
          {:ok, [result()]} | {:error, term()}
  def issue(_agent_id, items, _key, _now) when length(items) > @max_items,
    do: {:error, :too_many_items}

  def issue(agent_id, items, %IssuerKey{} = key, %DateTime{} = now)
      when is_binary(agent_id) and is_list(items) do
    with {:ok, assignments} <- read_assignments(items) do
      {:ok, Enum.map(items, &result(&1, agent_id, assignments, key, now))}
    end
  end

  defp result(item, agent_id, assignments, key, now) do
    case authority(item, agent_id, assignments) do
      :ok -> %{sequence: item.sequence, delivery_capability: sign(item, key, now), refusal: nil}
      {:error, reason} -> %{sequence: item.sequence, delivery_capability: nil, refusal: reason}
    end
  end

  defp authority(item, agent_id, assignments) do
    case Map.fetch(assignments, item.producer_assignment_id) do
      :error ->
        {:error, :unknown_assignment}

      {:ok, assignment} ->
        cond do
          assignment.agent_id != agent_id ->
            {:error, :not_assignment_owner}

          dump(assignment.network_scope_id) != item.network_scope_id ->
            {:error, :not_assignment_owner}

          assignment.run_shard != item.run_shard ->
            {:error, :not_assignment_owner}

          assignment.state != :active ->
            {:error, :assignment_revoked}

          true ->
            :ok
        end
    end
  end

  defp sign(item, key, now) do
    not_before = DateTime.to_unix(now, :nanosecond)
    expires = not_before + @ttl_seconds * 1_000_000_000

    claims = %EdgeDeliveryClaimsV1{
      event_id: item.event_id,
      record_sha256: item.record_sha256,
      spool_id: item.spool_id,
      sequence: item.sequence,
      transition:
        {:renewal,
         %EdgeDeliveryRenewalV1{
           renewed_not_before_unix_nano: not_before,
           renewed_expires_unix_nano: expires
         }}
    }

    IssuerKey.sign(
      %EdgeSignedCapabilityV1{
        not_before_unix_nano: not_before,
        expires_at_unix_nano: expires,
        claims: {:delivery, claims}
      },
      key
    )
  end

  # Both authority kinds the trust snapshot fences (`ServiceRadar.Edge.RecordTrust`), keyed by their
  # raw 16-byte id, which is what a record names.
  defp read_assignments(items) do
    ids =
      for id <- Enum.uniq(Enum.map(items, & &1.producer_assignment_id)),
          {:ok, uuid} <- [Ecto.UUID.cast(id)],
          do: uuid

    with {:ok, sweeps} <- read(SweepProducerAssignment, ids),
         {:ok, grants} <- read(OutputGrant, ids) do
      {:ok, Map.new(sweeps ++ grants, &{dump(&1.id), &1})}
    end
  end

  defp read(_resource, []), do: {:ok, []}

  defp read(resource, ids) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :agent_id, :network_scope_id, :run_shard, :state])
    |> Ash.read(actor: SystemActor.system(:edge_delivery_grants))
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
end
