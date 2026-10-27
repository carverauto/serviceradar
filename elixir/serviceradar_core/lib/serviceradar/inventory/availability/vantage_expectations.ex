defmodule ServiceRadar.Inventory.Availability.VantageExpectations do
  @moduledoc """
  Materializes composite-check vantage expectations (design Tier 1c).

  A vantage input's `expected` value says whether its agent should reach the device
  (`available`, a liveness witness) or be blocked from it (`blocked`, a negative
  control). For every in-scope device of an enabled check, each such input becomes one
  `device_vantage_expectations` row. The composite evaluator never reads these rows; the
  merged availability resolver reads them.

  The full evaluation pass calls `materialize/3` per page and `prune/1` after it has
  swept out-of-scope verdicts. Both write on change only. Disabling a check removes its
  rows through a trigger on `composite_checks.state`; deleting it cascades.
  """

  import Ecto.Query

  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Inventory.Availability.VantageExpectation
  alias ServiceRadar.Repo

  @expectations %{"available" => :reachable, "blocked" => :blocked}

  @doc """
  Brings the expectation rows of `check` for `device_uids` in line with its vantage
  inputs: inserts or updates rows that differ and deletes rows no input asks for.
  Returns the number of rows written plus deleted.

  The check row is locked `FOR SHARE` first and nothing is written unless its persisted
  state is `enabled`, so a concurrent disable either waits for this write and then
  clears it, or is seen here.
  """
  @spec materialize(struct(), [struct()], [String.t()]) :: non_neg_integer()
  def materialize(_check, _inputs, []), do: 0

  def materialize(check, inputs, device_uids) do
    {:ok, count} =
      Repo.transaction(fn ->
        if persisted_state(check) == "enabled" do
          reconcile(check, inputs, device_uids)
        else
          0
        end
      end)

    count
  end

  defp persisted_state(check) do
    Repo.one(
      from(c in "composite_checks",
        prefix: "platform",
        where: c.id == type(^check.id, Ecto.UUID),
        lock: "FOR SHARE",
        select: c.state
      )
    )
  end

  defp reconcile(check, inputs, device_uids) do
    desired = desired(check, inputs, device_uids)
    existing = existing(check, device_uids)

    upserts =
      desired
      |> Enum.reject(fn {key, expectation} -> Map.get(existing, key) == expectation end)
      |> Enum.sort()

    deletes =
      existing
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(desired, &1))
      |> Enum.sort()

    upsert(upserts) + delete(check, deletes)
  end

  @doc """
  Deletes the rows of `check` for devices that no longer have a verdict for it, which is
  how a device that left the check's scope loses its expectations.
  """
  @spec prune(struct()) :: non_neg_integer()
  def prune(check) do
    check_id = check.id

    verdicts =
      from(r in DeviceCompositeCheckResult,
        where: r.check_id == parent_as(:expectation).check_id,
        where: r.device_uid == parent_as(:expectation).device_uid
      )

    {count, _} =
      from(e in VantageExpectation, as: :expectation)
      |> where([e], e.check_id == ^check_id)
      |> where([e], not exists(verdicts))
      |> Repo.delete_all()

    count
  end

  defp desired(check, inputs, device_uids) do
    per_agent =
      inputs
      |> Enum.filter(&(&1.kind == :vantage_point))
      |> Enum.flat_map(fn input ->
        agent_id = Map.get(input.config || %{}, "agent_id")

        case Map.fetch(@expectations, input.expected) do
          {:ok, expectation} when is_binary(agent_id) and agent_id != "" ->
            [{agent_id, expectation}]

          _ ->
            []
        end
      end)
      # Two inputs naming one agent with different expectations: the negative control
      # is the more specific statement.
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {agent_id, expectations} ->
        {agent_id, if(:blocked in expectations, do: :blocked, else: :reachable)}
      end)

    for uid <- device_uids, {agent_id, expectation} <- per_agent, into: %{} do
      {{uid, agent_id, check.id}, expectation}
    end
  end

  defp existing(check, device_uids) do
    check_id = check.id

    VantageExpectation
    |> where([e], e.check_id == ^check_id and e.device_uid in ^device_uids)
    |> select([e], {{e.device_uid, e.agent_id, e.check_id}, e.expectation})
    |> Repo.all()
    |> Map.new()
  end

  defp upsert([]), do: 0

  defp upsert(rows) do
    records =
      Enum.map(rows, fn {{uid, agent_id, check_id}, expectation} ->
        %{
          device_uid: uid,
          agent_id: agent_id,
          check_id: check_id,
          expectation: expectation,
          updated_at: statement_now()
        }
      end)

    {count, _} =
      Repo.insert_all(VantageExpectation, records,
        on_conflict:
          from(e in VantageExpectation,
            update: [
              set: [
                expectation: fragment("EXCLUDED.expectation"),
                updated_at: fragment("EXCLUDED.updated_at")
              ]
            ]
          ),
        conflict_target: [:device_uid, :agent_id, :check_id]
      )

    count
  end

  defp delete(_check, []), do: 0

  defp delete(check, keys) do
    check_id = check.id
    uids = Enum.map(keys, &elem(&1, 0))
    agent_ids = Enum.map(keys, &elem(&1, 1))

    {count, _} =
      VantageExpectation
      |> where([e], e.check_id == ^check_id)
      |> where(
        [e],
        fragment(
          "(?, ?) IN (SELECT * FROM unnest(?::text[], ?::text[]))",
          e.device_uid,
          e.agent_id,
          ^uids,
          ^agent_ids
        )
      )
      |> Repo.delete_all()

    count
  end

  defp statement_now do
    from(n in fragment("SELECT (now() AT TIME ZONE 'utc') AS ts"), select: n.ts)
  end
end
