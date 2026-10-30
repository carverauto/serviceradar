defmodule ServiceRadar.SweepJobs.LeaseDelivery do
  @moduledoc """
  Sends each agent its sweep schedule lease and records what the agent acknowledged.

  A push is a `Serviceradar.Edge.V1.SweepLeaseV1` window replacement (see its proto comment):

    * a FULL push carries every unrun slot of the lease, in a window from now. A new lease ends
      that window just after its last slot. The same lease ends it at the later of that and the
      high water already sent, so the agent drops slots it may still hold. It is sent for a
      new lease (first delivery, or a fence bump or reissue, which changes the lease id), after
      core dropped a delivered slot that has not started, when a slot no push has carried sits
      behind the cursor, while the last push lacks a successful installation acknowledgement. When that lease
      was already delivered and no unrun slot remains, the full push still goes out, with an
      empty slot list and no production capability, in a window that reaches the high water;
    * otherwise a TAIL push carries only the slots minted since the cursor, in a window starting
      at the cursor and ending just after its last slot, and nothing is sent when there are none.

  Two positions are recorded. The cursor (`delivered_window_end`) is just after the last slot
  the push carried, so a slot the lease pass mints later (it mints a bounded number per pass)
  falls in a later window. An empty full push carries no slot; its cursor is its window start,
  so slots minted afterward still fall in a later window. The high water
  (`delivered_high_water`) is the furthest window end sent for the current lease id and starts
  again at the window end when the lease id changes. A drop is looked for up to the high water.

  A position alone does not prove a slot was sent, so each slot records when a push carried
  it (`delivered_at`). A slot minted behind the cursor (the re-minted slots of a restored
  horizon, a mint retried after an error) has no mark, and only a full window sends it: a
  tail starts at the cursor and would pass it by forever.

  Every push of one lease signs the same issuance time (`lease_issued_at`, the first push of
  the lease). A push that carries slots signs a production capability from there to the end of
  the last slot pushed, so the newest capability the agent holds covers every slot it was given.

  A group that no longer leases to an agent gets a `revoked` push, and its delivery row is
  removed once the agent acknowledges installing its revocation. The row has no foreign key,
  so it remains when the assignment or the group is destroyed; `withdraw_orphans/3` sends that same revocation
  for a row whose assignment is missing or revoked, or whose group is missing. An
  acknowledgement is stored only when its payload digest is the one last pushed.

  Core pushes only to agents advertising `capability/0` on their control stream; an agent that
  is not connected simply receives the full window on the next pass that reaches it.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.SweepContract
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SweepLeaseSlotV1
  alias Serviceradar.Edge.V1.SweepLeaseV1
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseCapabilities
  alias ServiceRadar.SweepJobs.LeasePass
  alias ServiceRadar.SweepJobs.SweepExecutionSlot
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepLeaseDelivery
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ash.Query
  require Logger

  @capability "sweep_lease_v1"
  @ack_grace_seconds 600

  @type authority :: %{key: IssuerKey.t(), contract: SweepContract.t()}
  @type sender :: (String.t(), Ecto.UUID.t(), binary() -> :ok | {:error, term()})
  @type outcome :: :pushed | :up_to_date | {:not_delivered, term()}
  @type horizon_status ::
          :acknowledged | :awaiting_acknowledgement | :acknowledgement_overdue | :refused
  @type horizon :: %{
          sweep_group_id: Ecto.UUID.t(),
          producer_assignment_id: Ecto.UUID.t(),
          agent_id: String.t(),
          status: horizon_status(),
          acknowledged_through: DateTime.t() | nil,
          remaining_seconds: non_neg_integer() | nil,
          acknowledged_slot_count: non_neg_integer() | nil,
          acknowledged_at: DateTime.t() | nil,
          delivered_at: DateTime.t(),
          error: String.t() | nil
        }

  @doc "The control-stream capability an agent advertises to receive leases."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "How long a push may go unacknowledged before its status is overdue."
  @spec ack_grace_seconds() :: pos_integer()
  def ack_grace_seconds, do: @ack_grace_seconds

  @doc "The issuer key and sweep contract to sign with, or `nil` when core issues no leases."
  @spec authority() :: authority() | nil
  def authority do
    with {:ok, key} <- IssuerKey.configured(),
         {:ok, contract} <- SweepContract.current() do
      %{key: key, contract: contract}
    else
      _ -> nil
    end
  end

  @doc "Pushes the assignment's lease if the agent is missing any of it."
  @spec deliver(SweepProducerAssignment.t(), authority(), DateTime.t(), sender()) ::
          {:ok, outcome()} | {:error, term()}
  def deliver(%SweepProducerAssignment{} = assignment, authority, %DateTime{} = now, sender) do
    lease_id = LeasePass.lease_id(assignment)

    with {:ok, state} <- get(assignment.id),
         {:ok, unrun} <- ExecutionSlots.list_unrun(assignment.id, now),
         {:ok, dropped?} <- dropped_since?(assignment, state, now) do
      case plan(state, lease_id, dropped? or undelivered_behind?(state, unrun), unrun, now) do
        :up_to_date ->
          {:ok, :up_to_date}

        push ->
          push = Map.put(push, :ack_pending_since, pending_since(state, lease_id, now))
          send_push(assignment, lease_id, push, authority, now, sender)
      end
    end
  end

  @doc """
  Withdraws the group's lease from every agent with a delivery that is not in `keep`. A row is
  removed once the agent acknowledges installing the revocation; otherwise the next pass retries.
  Returns how many were withdrawn.
  """
  @spec withdraw_except(Ecto.UUID.t(), [String.t()], DateTime.t(), sender()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def withdraw_except(sweep_group_id, keep, %DateTime{} = now, sender) when is_list(keep) do
    query =
      Ash.Query.filter(
        SweepLeaseDelivery,
        sweep_group_id == ^sweep_group_id and agent_id not in ^keep
      )

    with {:ok, rows} <- Ash.read(query, actor: actor()) do
      {:ok, Enum.count(rows, &withdraw(&1, now, sender))}
    end
  end

  @doc """
  Revokes every delivery whose producer assignment no longer exists or is revoked, or whose
  sweep group no longer exists. A row is removed once the agent acknowledges installing
  the revocation; otherwise the next pass retries. Returns how many were withdrawn.
  """
  @spec withdraw_orphans(DateTime.t(), sender()) :: {:ok, non_neg_integer()} | {:error, term()}
  def withdraw_orphans(%DateTime{} = now, sender) do
    with {:ok, rows} <- orphan_rows() do
      {:ok, Enum.count(rows, &withdraw(&1, now, sender))}
    end
  end

  @doc """
  Records an agent's answer to the lease push last delivered. `ack` is the decoded
  `Monitoring.SweepLeaseAck` fields: `:sweep_group_id`, `:payload_sha256`, `:installed`,
  `:error`, `:installed_through_unix_nano` and `:installed_slot_count`. An ack is stored only
  when `:payload_sha256` equals that push's digest; an ack for an older push, or for a group
  the agent holds no delivery for, changes nothing.
  """
  @spec record_ack(String.t(), map(), DateTime.t()) :: :ok | {:error, term()}
  def record_ack(agent_id, ack, now \\ DateTime.utc_now()) when is_binary(agent_id) do
    with {:ok, group_id} <- Ecto.UUID.cast(Map.get(ack, :sweep_group_id)),
         {:ok, %SweepLeaseDelivery{} = row} <- get_by_group_agent(group_id, agent_id) do
      if Map.get(ack, :payload_sha256) == row.delivered_payload_sha256 do
        apply_ack(row, ack, now)
      else
        :ok
      end
    else
      :error -> {:error, :invalid_sweep_group_id}
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The delivery row of every agent of a group."
  @spec list_for_group(Ecto.UUID.t()) :: {:ok, [SweepLeaseDelivery.t()]} | {:error, term()}
  def list_for_group(sweep_group_id) do
    SweepLeaseDelivery
    |> Ash.Query.filter(sweep_group_id == ^sweep_group_id)
    |> Ash.read(actor: actor())
  end

  @doc """
  The acknowledged lease horizon of every agent with a delivery in `group_ids`, grouped by
  sweep group and ordered by agent within each group.

  The horizon is taken only from an installed acknowledgement. A newer unacknowledged push
  does not erase the horizon from the last installed acknowledgement, but it does change the
  status from `:acknowledged` to `:awaiting_acknowledgement` (or
  `:acknowledgement_overdue` once the acknowledgement grace has passed). A refused latest
  push has no horizon in this projection.
  """
  @spec horizons_for_groups([Ecto.UUID.t()], DateTime.t()) ::
          {:ok, %{optional(Ecto.UUID.t()) => [horizon()]}} | {:error, term()}
  def horizons_for_groups(group_ids, now \\ DateTime.utc_now())

  def horizons_for_groups([], %DateTime{}), do: {:ok, %{}}

  def horizons_for_groups(group_ids, %DateTime{} = now) when is_list(group_ids) do
    query =
      SweepLeaseDelivery
      |> Ash.Query.filter(sweep_group_id in ^group_ids)
      |> Ash.Query.sort(sweep_group_id: :asc, agent_id: :asc)

    with {:ok, rows} <- Ash.read(query, actor: actor()) do
      {:ok, Enum.group_by(Enum.map(rows, &horizon(&1, now)), & &1.sweep_group_id)}
    end
  end

  defp horizon(%SweepLeaseDelivery{} = row, %DateTime{} = now) do
    installed? = row.ack_installed == true
    acknowledged_through = if installed?, do: row.acked_through
    acknowledged_slot_count = if installed?, do: row.acked_slot_count

    %{
      sweep_group_id: row.sweep_group_id,
      producer_assignment_id: row.producer_assignment_id,
      agent_id: row.agent_id,
      status: horizon_status(row, now),
      acknowledged_through: acknowledged_through,
      remaining_seconds: remaining_seconds(acknowledged_through, now),
      acknowledged_slot_count: acknowledged_slot_count,
      acknowledged_at: row.acked_at,
      delivered_at: row.delivered_at,
      error: current_ack_error(row)
    }
  end

  # An acknowledgement error belongs to the push it answered; once a newer push is
  # delivered, the old refusal no longer describes the lease state.
  defp current_ack_error(%SweepLeaseDelivery{} = row) do
    if row.acked_payload_sha256 == row.delivered_payload_sha256, do: row.ack_error
  end

  defp horizon_status(%SweepLeaseDelivery{} = row, %DateTime{} = now) do
    cond do
      row.acked_payload_sha256 == row.delivered_payload_sha256 and row.ack_installed == true ->
        :acknowledged

      ack_failed?(row) ->
        :refused

      ack_lost?(row, now) ->
        :acknowledgement_overdue

      true ->
        :awaiting_acknowledgement
    end
  end

  defp remaining_seconds(%DateTime{} = acknowledged_through, %DateTime{} = now) do
    acknowledged_through
    |> DateTime.diff(now, :second)
    |> max(0)
  end

  defp remaining_seconds(_acknowledged_through, %DateTime{}), do: nil

  # What to push, or :up_to_date. `replace?` is a dropped delivered slot or a
  # never-carried slot behind the cursor: only a full window sets either right.
  defp plan(state, lease_id, replace?, unrun, now) do
    same_lease? = match?(%SweepLeaseDelivery{}, state) and state.lease_id == lease_id

    if same_lease? and is_nil(state.revoked_at) and not replace? and state.ack_installed == true and
         state.acked_payload_sha256 == state.delivered_payload_sha256 do
      tail(state, unrun)
    else
      full(state, same_lease?, unrun, now)
    end
  end

  defp full(nil, false, [], _now), do: :up_to_date

  defp full(%SweepLeaseDelivery{} = state, true, [], now) do
    bare(state.lease_issued_at, now, clearing_end(now, state.delivered_high_water))
  end

  defp full(_state, false, [], now) do
    bare(now, now, DateTime.add(now, 1, :microsecond))
  end

  defp full(state, same_lease?, unrun, now) do
    cursor = carried_end(unrun)

    window_end =
      if(same_lease?, do: latest(cursor, state.delivered_high_water), else: cursor)

    %{
      kind: :full,
      issued_at: if(same_lease?, do: state.lease_issued_at, else: now),
      window_start: now,
      window_end: window_end,
      cursor: cursor,
      high_water: high_water(state, same_lease?, window_end),
      slots: unrun
    }
  end

  defp bare(issued_at, window_start, window_end) do
    %{
      kind: :full,
      issued_at: issued_at,
      window_start: window_start,
      window_end: window_end,
      cursor: window_start,
      high_water: window_end,
      slots: []
    }
  end

  defp tail(state, unrun) do
    case Enum.filter(unrun, &(DateTime.compare(&1.slot_start, state.delivered_window_end) != :lt)) do
      [] ->
        :up_to_date

      slots ->
        cursor = carried_end(slots)

        %{
          kind: :tail,
          issued_at: state.lease_issued_at,
          window_start: state.delivered_window_end,
          window_end: cursor,
          cursor: cursor,
          high_water: latest(state.delivered_high_water, cursor),
          slots: slots
        }
    end
  end

  defp carried_end(slots), do: window_end_after(List.last(slots))

  defp clearing_end(now, high_water), do: latest(high_water, DateTime.add(now, 1, :microsecond))

  defp high_water(_state, false, window_end), do: window_end
  defp high_water(state, true, window_end), do: latest(state.delivered_high_water, window_end)

  defp window_end_after(%SweepExecutionSlot{slot_start: start}),
    do: DateTime.add(start, 1, :microsecond)

  defp latest(a, b), do: if(DateTime.after?(a, b), do: a, else: b)

  defp ack_failed?(state),
    do:
      state.acked_payload_sha256 == state.delivered_payload_sha256 and
        state.ack_installed == false

  defp ack_lost?(state, now) do
    state.acked_payload_sha256 != state.delivered_payload_sha256 and
      DateTime.diff(now, state.ack_pending_since || state.delivered_at, :second) >
        @ack_grace_seconds
  end

  # A slot no push has carried, minted behind the cursor: a tail starts at the cursor,
  # so only a full window ever sends it.
  defp undelivered_behind?(%SweepLeaseDelivery{} = state, unrun) do
    Enum.any?(unrun, fn slot ->
      is_nil(slot.delivered_at) and
        DateTime.before?(slot.slot_start, state.delivered_window_end)
    end)
  end

  defp undelivered_behind?(nil, _unrun), do: false

  # A delivered slot that has not started and was dropped after the last push: only a full
  # window removes it from the agent.
  defp dropped_since?(_assignment, nil, _now), do: {:ok, false}

  defp dropped_since?(assignment, delivery, now) do
    delivered_at = delivery.delivered_at
    high_water = delivery.delivered_high_water

    SweepExecutionSlot
    |> Ash.Query.filter(
      producer_assignment_id == ^assignment.id and state == :dropped and
        updated_at > ^delivered_at and slot_start > ^now and slot_start < ^high_water
    )
    |> Ash.exists(actor: actor())
  end

  defp send_push(assignment, lease_id, push, %{key: key, contract: contract}, now, sender) do
    with {:ok, capability} <- push_capability(assignment, push, contract, key),
         {:ok, slots} <- lease_slots(assignment, push.slots, key) do
      payload =
        SweepLeaseV1.encode(%SweepLeaseV1{
          lease_version: 1,
          sweep_group_id: uuid(assignment.sweep_group_id),
          lease_id: uuid(lease_id),
          producer_assignment_id: uuid(assignment.id),
          authority_epoch: assignment.authority_epoch,
          production_capability: capability,
          window_start_unix_nano: nanos(push.window_start),
          window_end_unix_nano: nanos(push.window_end),
          slots: slots
        })

      with {:ok, :pushed} <- record_push(assignment, lease_id, push, payload, now) do
        case sender.(assignment.agent_id, assignment.sweep_group_id, payload) do
          :ok -> {:ok, :pushed}
          {:error, reason} -> {:ok, {:not_delivered, reason}}
        end
      end
    end
  end

  defp push_capability(_assignment, %{slots: []}, _contract, _key), do: {:ok, nil}

  defp push_capability(assignment, push, contract, key) do
    LeaseCapabilities.production_capability(
      assignment,
      push.slots,
      contract,
      key,
      push.issued_at
    )
  end

  defp lease_slots(assignment, slots, key) do
    slots
    |> Enum.reduce_while({:ok, []}, fn slot, {:ok, acc} ->
      case LeaseCapabilities.source_authorizations(assignment, slot, key) do
        {:ok, authorizations} ->
          {:cont, {:ok, [lease_slot(slot, authorizations) | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp lease_slot(slot, authorizations) do
    %SweepLeaseSlotV1{
      execution_id: uuid(slot.id),
      slot_start_unix_nano: nanos(slot.slot_start),
      collection_expires_unix_nano: nanos(slot.collection_expires),
      plan_header: ScheduledPlanHeaderV1.decode(slot.plan_header),
      plan_pages: Enum.map(slot.plan_pages, &ScheduledPlanPageV1.decode/1),
      source_authorizations: authorizations
    }
  end

  defp pending_since(%SweepLeaseDelivery{} = state, lease_id, now) do
    if state.lease_id == lease_id and is_nil(state.revoked_at) and
         state.acked_payload_sha256 != state.delivered_payload_sha256 do
      state.ack_pending_since || state.delivered_at
    else
      now
    end
  end

  defp pending_since(nil, _lease_id, now), do: now

  defp record_push(assignment, lease_id, push, payload, now) do
    SweepLeaseDelivery
    |> Ash.Changeset.for_create(
      :record_push,
      %{
        producer_assignment_id: assignment.id,
        sweep_group_id: assignment.sweep_group_id,
        agent_id: assignment.agent_id,
        lease_id: lease_id,
        lease_issued_at: push.issued_at,
        delivered_window_end: push.cursor,
        delivered_high_water: push.high_water,
        delivered_payload_sha256: sha256_hex(payload),
        delivered_at: now,
        ack_pending_since: push.ack_pending_since,
        revoked_at: nil
      },
      actor: actor()
    )
    |> Ash.create()
    |> case do
      {:ok, _row} -> mark_carried(push.slots, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_carried(slots, now) do
    case ExecutionSlots.mark_delivered(Enum.map(slots, & &1.id), now) do
      {:ok, _count} -> {:ok, :pushed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_ack(%SweepLeaseDelivery{revoked_at: %DateTime{}} = row, %{installed: true}, _now) do
    row
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor())
    |> Ash.Changeset.filter(delivered_payload_sha256: row.delivered_payload_sha256)
    |> Ash.destroy()
  end

  defp apply_ack(row, ack, now) do
    row
    |> Ash.Changeset.for_update(
      :record_ack,
      %{
        acked_payload_sha256: Map.get(ack, :payload_sha256),
        ack_installed: Map.get(ack, :installed) == true,
        ack_error: blank_to_nil(Map.get(ack, :error)),
        acked_through: from_nanos(Map.get(ack, :installed_through_unix_nano)),
        acked_slot_count: Map.get(ack, :installed_slot_count),
        acked_at: now
      },
      actor: actor()
    )
    |> Ash.Changeset.filter(delivered_payload_sha256: row.delivered_payload_sha256)
    |> Ash.update()
    |> case do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp orphan_rows do
    with {:ok, rows} <- Ash.read(SweepLeaseDelivery, actor: actor()) do
      classify_orphans(rows)
    end
  end

  defp classify_orphans([]), do: {:ok, []}

  defp classify_orphans(rows) do
    assignment_ids = Enum.map(rows, & &1.producer_assignment_id)
    group_ids = rows |> Enum.map(& &1.sweep_group_id) |> Enum.uniq()

    with {:ok, assignments} <- read_ids(SweepProducerAssignment, assignment_ids),
         {:ok, groups} <- read_ids(SweepGroup, group_ids) do
      states = Map.new(assignments, &{&1.id, &1.state})
      present = MapSet.new(groups, & &1.id)

      {:ok,
       Enum.filter(rows, fn row ->
         states[row.producer_assignment_id] != :active or row.sweep_group_id not in present
       end)}
    end
  end

  defp read_ids(resource, ids) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(actor: actor())
  end

  defp withdraw(row, now, sender) do
    revoked_at = row.revoked_at || now

    payload =
      SweepLeaseV1.encode(%SweepLeaseV1{
        lease_version: 1,
        sweep_group_id: uuid(row.sweep_group_id),
        lease_id: uuid(row.lease_id),
        window_start_unix_nano: nanos(revoked_at),
        window_end_unix_nano: nanos(revoked_at) + 1,
        revoked: true
      })

    with {:ok, _pending} <-
           row
           |> Ash.Changeset.for_update(
             :record_revocation,
             %{
               revoked_at: revoked_at,
               delivered_payload_sha256: sha256_hex(payload),
               delivered_at: now,
               ack_pending_since: revoked_at
             },
             actor: actor()
           )
           |> Ash.update(),
         :ok <- sender.(row.agent_id, row.sweep_group_id, payload) do
      true
    else
      _ -> false
    end
  end

  defp get(assignment_id) do
    SweepLeaseDelivery
    |> Ash.Query.filter(producer_assignment_id == ^assignment_id)
    |> Ash.read_one(actor: actor())
  end

  defp get_by_group_agent(group_id, agent_id) do
    SweepLeaseDelivery
    |> Ash.Query.filter(sweep_group_id == ^group_id and agent_id == ^agent_id)
    |> Ash.read_one(actor: actor())
  end

  defp sha256_hex(payload), do: Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

  defp from_nanos(nanos) when is_integer(nanos) and nanos > 0,
    do: nanos |> DateTime.from_unix!(:nanosecond) |> DateTime.truncate(:microsecond)

  defp from_nanos(_nanos), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp uuid(value), do: Ecto.UUID.dump!(value)

  defp nanos(%DateTime{} = time), do: DateTime.to_unix(time, :nanosecond)

  defp actor, do: SystemActor.system(:sweep_lease_delivery)
end
