defmodule ServiceRadar.CompositeChecks.DeviceCompositeCheckResultTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Result Fixture #{System.unique_integer([:positive])}",
          scope_query: "in:devices"
        },
        actor: actor()
      )
      |> Ash.create()

    %{check: check}
  end

  defp upsert(check, device_uid, verdict, status, at) do
    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{"agent_a" => %{"value" => "available", "stale" => false}},
        evaluated_at: at,
        changed_at: at
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create()
  end

  test "stores a verdict with its input snapshot", %{check: check} do
    now = DateTime.utc_now()
    assert {:ok, result} = upsert(check, "device-1", "isolated_verified", :healthy, now)

    assert result.verdict == "isolated_verified"
    assert result.status == :healthy
    assert result.inputs["agent_a"]["value"] == "available"
  end

  test "one row per device and check", %{check: check} do
    now = DateTime.utc_now()
    assert {:ok, _} = upsert(check, "device-1", "isolated_verified", :healthy, now)
    assert {:ok, _} = upsert(check, "device-1", "not_isolated", :down, DateTime.add(now, 60))

    assert {:ok, rows} = DeviceCompositeCheckResult.list_by_check(check.id, actor: actor())
    assert length(rows) == 1
    assert hd(rows).verdict == "not_isolated"
  end

  test "the same device can hold verdicts for different checks", %{check: check} do
    {:ok, other} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Second #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    now = DateTime.utc_now()
    assert {:ok, _} = upsert(check, "device-1", "isolated_verified", :healthy, now)
    assert {:ok, _} = upsert(other, "device-1", "not_isolated", :down, now)

    assert {:ok, rows} = DeviceCompositeCheckResult.list_by_device("device-1", actor: actor())
    assert length(rows) == 2
  end

  test "reassign_device moves a result to the surviving uid", %{check: check} do
    now = DateTime.utc_now()
    {:ok, result} = upsert(check, "device-loser", "isolated_verified", :healthy, now)

    assert {:ok, moved} =
             result
             |> Ash.Changeset.for_update(:reassign_device, %{device_uid: "device-winner"},
               actor: actor()
             )
             |> Ash.update()

    assert moved.device_uid == "device-winner"
  end

  test "deleting a check deletes its results", %{check: check} do
    now = DateTime.utc_now()
    {:ok, _} = upsert(check, "device-1", "isolated_verified", :healthy, now)

    admin = %{id: Ash.UUID.generate(), role: :admin}
    assert :ok = Ash.destroy(check, actor: admin)
    assert {:ok, []} = DeviceCompositeCheckResult.list_by_device("device-1", actor: actor())
  end

  test "status is constrained to the fixed enum", %{check: check} do
    assert {:error, _} =
             upsert(check, "device-1", "made_up", :catastrophic, DateTime.utc_now())
  end
end
