defmodule ServiceRadar.CompositeChecks.RefreshTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Refresh
  alias ServiceRadar.CompositeChecks.RefreshWorker
  alias ServiceRadar.CompositeChecks.RuleGenerator
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  defp actor, do: SystemActor.system(:composite_check_test)

  defp device!(uid) do
    <<a, b, c, _rest::binary>> = :crypto.hash(:sha256, uid)

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      hostname: "refresh-#{a}-#{b}",
      ip: "10.#{a}.#{b}.#{max(c, 1)}"
    })
    |> Ash.create!(actor: actor())
  end

  defp availability(device_uid, agent_id, is_available, at) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{device_uid: device_uid, agent_id: agent_id, is_available: is_available, checked_at: at},
      actor: actor()
    )
    |> Ash.create!()
  end

  defp seed_result(check, device_uid, verdict, status, at) do
    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{},
        evaluated_at: at,
        changed_at: at
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Refresh #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    inputs =
      for {key, expected, position} <- [{"a", "available", 0}, {"b", "blocked", 1}] do
        CompositeCheckInput
        |> Ash.Changeset.for_create(
          :create,
          %{
            check_id: check.id,
            key: key,
            label: key,
            position: position,
            kind: :vantage_point,
            expected: expected,
            config: %{"agent_id" => "agent-#{key}", "max_age_seconds" => 900}
          },
          actor: actor()
        )
        |> Ash.create!()
      end

    for attrs <- RuleGenerator.generate(inputs) do
      CompositeCheckRule
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
      |> Ash.create!()
    end

    {:ok, enabled} =
      check
      |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: actor())
      |> Ash.update()

    now = DateTime.utc_now()
    device!("device-1")
    seed_result(enabled, "device-1", "device_unreachable", :degraded, now)

    %{check: enabled, now: now}
  end

  defp result(check, uid) do
    DeviceCompositeCheckResult.get_by_device_check(uid, check.id, actor: actor())
  end

  test "refreshes the verdict for a device with an existing result", %{check: check, now: now} do
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, 1} = RefreshWorker.perform(%Oban.Job{args: %{"device_uid" => "device-1"}})

    {:ok, result} = result(check, "device-1")
    assert result.verdict == "isolated_verified"
    assert result.status == :healthy
  end

  test "advances changed_at only when the verdict actually changes", %{check: check, now: now} do
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, 1} = RefreshWorker.perform(%Oban.Job{args: %{"device_uid" => "device-1"}})
    {:ok, first} = result(check, "device-1")

    assert {:ok, 1} = RefreshWorker.perform(%Oban.Job{args: %{"device_uid" => "device-1"}})
    {:ok, second} = result(check, "device-1")

    assert second.changed_at == first.changed_at
  end

  describe "identity fence" do
    setup do
      handler_id = "refresh-fence-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:serviceradar, :identity_fence, :stale],
            [:serviceradar, :identity_fence, :abandoned]
          ],
          fn event, _measurements, metadata, _ ->
            if metadata.pipeline == :composite_check_refresh,
              do: send(test_pid, {:fence, List.last(event), metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "a job pinned before a merge refreshes the survivor", %{check: check, now: now} do
      source = device!("sr:" <> Ecto.UUID.generate())
      survivor = device!("sr:" <> Ecto.UUID.generate())
      seed_result(check, source.uid, "device_unreachable", :degraded, now)
      availability(survivor.uid, "agent-a", true, now)
      availability(survivor.uid, "agent-b", false, now)
      pinned = source.identity_revision

      assert :ok =
               ServiceRadar.Inventory.IdentityReconciler.merge_devices(source.uid, survivor.uid,
                 actor: actor(),
                 reason: "manual_merge"
               )

      args = %{"device_uid" => source.uid, "identity_revision" => pinned}
      assert {:ok, 1} = RefreshWorker.perform(%Oban.Job{args: args})

      {:ok, refreshed} = result(check, survivor.uid)
      assert refreshed.verdict == "isolated_verified"
      assert_receive {:fence, :stale, %{device_id: stale_uid}}
      assert stale_uid == source.uid
    end

    test "a job pinned to a device that no longer exists is abandoned with telemetry" do
      uid = "sr:" <> Ecto.UUID.generate()
      args = %{"device_uid" => uid, "identity_revision" => 1}

      assert {:ok, 0} = RefreshWorker.perform(%Oban.Job{args: args})
      assert_receive {:fence, :abandoned, %{device_id: ^uid}}
    end
  end

  test "does nothing for a device with no result rows" do
    assert {:ok, 0} = RefreshWorker.perform(%Oban.Job{args: %{"device_uid" => "device-unknown"}})
  end

  test "skips checks that are no longer enabled", %{check: check, now: now} do
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    {:ok, _} =
      check
      |> Ash.Changeset.for_update(:set_state, %{state: :disabled}, actor: actor())
      |> Ash.update()

    assert {:ok, 0} = RefreshWorker.perform(%Oban.Job{args: %{"device_uid" => "device-1"}})

    {:ok, unchanged} = result(check, "device-1")
    assert unchanged.verdict == "device_unreachable"
  end

  test "enqueue never raises when Oban is unavailable" do
    assert :ok = Refresh.enqueue("device-1")
    assert :ok = Refresh.enqueue_many(["device-1", "device-2"])
  end

  test "enqueue tolerates junk without raising" do
    assert :ok = Refresh.enqueue(nil)
    assert :ok = Refresh.enqueue("")
    assert :ok = Refresh.enqueue_many([nil, "", "device-1"])
    assert :ok = Refresh.enqueue_many(:not_a_list)
  end
end
