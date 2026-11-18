defmodule ServiceRadar.CompositeChecks.MergeReassignmentTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.DeclarativeChecks
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckEdgeObservation
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckInstance
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Reassignments
  alias ServiceRadar.Inventory.IdentityReconciler

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Merge Fixture #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    %{check: check}
  end

  defp upsert(check, device_uid, verdict, status) do
    now = DateTime.utc_now()

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{},
        evaluated_at: now,
        changed_at: now
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  test "moves results from the losing uid to the survivor", %{check: check} do
    upsert(check, "loser", "isolated_verified", :healthy)

    assert :ok = Reassignments.reassign_composite_results("loser", "winner", actor())

    assert {:ok, []} = DeviceCompositeCheckResult.list_by_device("loser", actor: actor())
    assert {:ok, [row]} = DeviceCompositeCheckResult.list_by_device("winner", actor: actor())
    assert row.verdict == "isolated_verified"
  end

  test "drops the losing row when the survivor already has one for that check", %{check: check} do
    upsert(check, "loser", "not_isolated", :down)
    upsert(check, "winner", "isolated_verified", :healthy)

    assert :ok = Reassignments.reassign_composite_results("loser", "winner", actor())

    assert {:ok, []} = DeviceCompositeCheckResult.list_by_device("loser", actor: actor())
    assert {:ok, [row]} = DeviceCompositeCheckResult.list_by_device("winner", actor: actor())
    assert row.verdict == "isolated_verified"
  end

  test "moves some rows and drops others in one merge", %{check: check} do
    {:ok, other} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Merge Second #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    # Collides on `check`, unique on `other`.
    upsert(check, "loser", "not_isolated", :down)
    upsert(other, "loser", "device_unreachable", :degraded)
    upsert(check, "winner", "isolated_verified", :healthy)

    assert :ok = Reassignments.reassign_composite_results("loser", "winner", actor())

    assert {:ok, []} = DeviceCompositeCheckResult.list_by_device("loser", actor: actor())
    {:ok, rows} = DeviceCompositeCheckResult.list_by_device("winner", actor: actor())

    verdicts = rows |> Enum.map(& &1.verdict) |> Enum.sort()
    assert verdicts == ["device_unreachable", "isolated_verified"]
  end

  test "is a no-op when the losing device has no results" do
    assert :ok = Reassignments.reassign_composite_results("nothing-here", "winner", actor())
    assert {:ok, []} = DeviceCompositeCheckResult.list_by_device("winner", actor: actor())
  end

  describe "through a real device merge" do
    @describetag :integration

    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    defp create_device(actor, uid, hostname) do
      <<a, b, c, _rest::binary>> = :crypto.hash(:sha256, uid)

      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: uid,
        hostname: hostname,
        ip: "10.#{a}.#{b}.#{max(c, 1)}"
      })
      |> Ash.create(actor: actor)
    end

    test "a verdict survives the merge and lands on the survivor", %{check: check} do
      from_uid = "sr:" <> Ecto.UUID.generate()
      to_uid = "sr:" <> Ecto.UUID.generate()

      assert {:ok, _} = create_device(actor(), from_uid, "composite-merge-from")
      assert {:ok, _} = create_device(actor(), to_uid, "composite-merge-to")

      upsert(check, from_uid, "isolated_verified", :healthy)

      assert :ok = IdentityReconciler.merge_devices(from_uid, to_uid, actor: actor())

      assert {:ok, []} = DeviceCompositeCheckResult.list_by_device(from_uid, actor: actor())
      assert {:ok, [row]} = DeviceCompositeCheckResult.list_by_device(to_uid, actor: actor())
      assert row.verdict == "isolated_verified"
    end

    test "a collision keeps exactly one row on the survivor", %{check: check} do
      from_uid = "sr:" <> Ecto.UUID.generate()
      to_uid = "sr:" <> Ecto.UUID.generate()

      assert {:ok, _} = create_device(actor(), from_uid, "composite-collide-from")
      assert {:ok, _} = create_device(actor(), to_uid, "composite-collide-to")

      upsert(check, from_uid, "not_isolated", :down)
      upsert(check, to_uid, "isolated_verified", :healthy)

      assert :ok = IdentityReconciler.merge_devices(from_uid, to_uid, actor: actor())

      assert {:ok, [row]} = DeviceCompositeCheckResult.list_by_device(to_uid, actor: actor())
      assert row.verdict == "isolated_verified"

      # Asserting the survivor alone would pass even with the merge wiring
      # removed, since its row was never touched. The losing row must be gone.
      assert {:ok, []} = DeviceCompositeCheckResult.list_by_device(from_uid, actor: actor())
    end

    test "declarative check instances and edge observations move onto the survivor and deduplicate collisions" do
      from_uid = "sr:" <> Ecto.UUID.generate()
      to_uid = "sr:" <> Ecto.UUID.generate()
      now = DateTime.utc_now()

      assert {:ok, _} = create_device(actor(), from_uid, "decl-merge-from")
      assert {:ok, _} = create_device(actor(), to_uid, "decl-merge-to")

      {:ok, dcheck} =
        DeclarativeChecks.create_check(
          %{
            "schema_version" => 1,
            "slug" => "decl-merge-#{System.unique_integer([:positive])}",
            "name" => "Declarative Merge Check",
            "state" => "draft",
            "target_binding" => %{"mode" => "srql_devices", "scope_query" => "in:devices"},
            "nodes" => [
              %{
                "id" => "q_1",
                "kind" => "srql_query",
                "config" => %{"query" => "in:devices", "limit" => 10}
              },
              %{
                "id" => "assert_1",
                "kind" => "threshold_assert",
                "config" => %{"field" => "row_count", "crit" => %{"op" => "==", "value" => 0}}
              },
              %{
                "id" => "out_1",
                "kind" => "alert_output",
                "config" => %{}
              }
            ],
            "edges" => [
              %{"id" => "e1", "source" => "q_1", "target" => "assert_1"},
              %{"id" => "e2", "source" => "assert_1", "target" => "out_1"}
            ]
          },
          actor: actor(),
          skip_srql_nif?: true
        )

      assert {:ok, _} =
               DeclarativeCheckInstance.upsert_instance(
                 %{
                   check_id: dcheck.id,
                   target_key: "device:#{from_uid}",
                   target_kind: :device,
                   device_uid: from_uid,
                   verdict: "healthy",
                   status: :healthy,
                   summary: "ok",
                   node_snapshots: %{},
                   evaluated_at: now,
                   changed_at: now
                 },
                 actor: actor()
               )

      assert {:ok, _} =
               DeclarativeCheckEdgeObservation.upsert_observation(
                 %{
                   check_id: dcheck.id,
                   node_id: "q_1",
                   target_key: "device:#{from_uid}",
                   device_uid: from_uid,
                   agent_id: "agent-example-1",
                   status: :healthy,
                   value: "1",
                   payload: %{"ok" => true},
                   duration_ms: 12,
                   observed_at: now
                 },
                 actor: actor()
               )

      assert :ok = IdentityReconciler.merge_devices(from_uid, to_uid, actor: actor())

      assert {:ok, []} = DeclarativeCheckInstance.list_by_device(from_uid, actor: actor())
      assert {:ok, [moved_inst]} = DeclarativeCheckInstance.list_by_device(to_uid, actor: actor())
      assert moved_inst.target_key == "device:#{to_uid}"

      assert {:ok, []} = DeclarativeCheckEdgeObservation.list_by_device(from_uid, actor: actor())

      assert {:ok, [moved_obs]} =
               DeclarativeCheckEdgeObservation.list_by_device(to_uid, actor: actor())

      assert moved_obs.target_key == "device:#{to_uid}"
    end
  end
end
