defmodule ServiceRadar.CompositeChecks.ReadinessTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Readiness
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  defp actor, do: SystemActor.system(:composite_check_test)

  defmodule ScopeRunner do
    @moduledoc false

    def query_page(_query, _opts) do
      uids = Process.get(:scope_uids, ["device-1", "device-2"])
      {:ok, %{rows: Enum.map(uids, &%{"uid" => &1}), next_cursor: nil}}
    end
  end

  defp device!(uid) do
    <<a, b, c, _rest::binary>> = :crypto.hash(:sha256, uid)

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      hostname: "ready-#{a}-#{b}",
      ip: "10.#{a}.#{b}.#{max(c, 1)}"
    })
    |> Ash.create!(actor: actor())
  end

  defp availability(device_uid, agent_id) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device_uid,
        agent_id: agent_id,
        is_available: true,
        checked_at: DateTime.utc_now()
      },
      actor: actor()
    )
    |> Ash.create!()
  end

  defp build_check(expectations) do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Ready #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    for {{key, expected}, position} <- Enum.with_index(expectations) do
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
          config: %{"agent_id" => "agent-#{key}"}
        },
        actor: actor()
      )
      |> Ash.create!()
    end

    check
  end

  defp report(check) do
    {:ok, report} = Readiness.check(check, actor: actor(), runner: ScopeRunner)
    report
  end

  setup do
    Process.put(:scope_uids, ["device-1", "device-2"])
    device!("device-1")
    device!("device-2")
    :ok
  end

  describe "liveness witness" do
    test "all-blocked expectations block enabling" do
      check = build_check([{"a", "blocked"}, {"b", "blocked"}])

      blocking = report(check).blocking
      problem = Enum.find(blocking, &(&1.code == :no_liveness_witness))

      assert problem
      assert problem.message =~ "powered-off"
    end

    test "a single vantage point is exempt" do
      check = build_check([{"a", "blocked"}])

      refute Enum.any?(report(check).blocking, &(&1.code == :no_liveness_witness))
    end

    test "one expected-available vantage point satisfies it" do
      check = build_check([{"a", "available"}, {"b", "blocked"}])
      availability("device-1", "agent-a")
      availability("device-2", "agent-a")
      availability("device-1", "agent-b")
      availability("device-2", "agent-b")

      refute Enum.any?(report(check).blocking, &(&1.code == :no_liveness_witness))
    end
  end

  describe "coverage" do
    test "zero coverage blocks enabling and names the agent" do
      check = build_check([{"a", "available"}, {"b", "blocked"}])
      availability("device-1", "agent-a")
      availability("device-2", "agent-a")

      problem = Enum.find(report(check).blocking, &(&1.code == :no_coverage))

      assert problem
      assert problem.message =~ "agent-b"
      assert problem.message =~ "0 of 2"
    end

    test "partial coverage warns but does not block" do
      check = build_check([{"a", "available"}, {"b", "blocked"}])
      availability("device-1", "agent-a")
      availability("device-2", "agent-a")
      availability("device-1", "agent-b")

      report = report(check)

      refute Enum.any?(report.blocking, &(&1.code == :no_coverage))
      warning = Enum.find(report.warnings, &(&1.code == :partial_coverage))
      assert warning.message =~ "1 of 2"
    end

    test "full coverage with a witness is clean" do
      check = build_check([{"a", "available"}, {"b", "blocked"}])

      for uid <- ["device-1", "device-2"], agent <- ["agent-a", "agent-b"] do
        availability(uid, agent)
      end

      assert %{blocking: [], warnings: []} = report(check)
    end

    test "reports counts per vantage point" do
      check = build_check([{"a", "available"}, {"b", "blocked"}])
      availability("device-1", "agent-a")
      availability("device-2", "agent-a")
      availability("device-1", "agent-b")

      coverage = report(check).coverage

      assert %{covered: 2, total: 2} = Enum.find(coverage, &(&1.input_key == "a"))
      assert %{covered: 1, total: 2} = Enum.find(coverage, &(&1.input_key == "b"))
    end
  end

  describe "the enable action" do
    test "is rejected while a blocking problem exists" do
      check = build_check([{"a", "blocked"}, {"b", "blocked"}])

      assert {:error, error} =
               check
               |> Ash.Changeset.for_update(:enable, %{}, actor: actor())
               |> Ash.update()

      assert Exception.message(error) =~ "liveness witness"
    end

    test "a missing witness cannot be acknowledged away" do
      # Coverage gaps are a timing problem an operator may knowingly accept. A
      # missing witness is a correctness fault -- the check would certify
      # powered-off devices as compliant.
      check = build_check([{"a", "blocked"}, {"b", "blocked"}])

      assert {:error, error} =
               check
               |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true},
                 actor: actor()
               )
               |> Ash.update()

      assert Exception.message(error) =~ "liveness witness"
    end

    test "a coverage gap blocks enabling until acknowledged" do
      check = build_check([{"a", "available"}, {"b", "blocked"}])
      availability("device-1", "agent-a")
      availability("device-2", "agent-a")

      assert {:error, error} =
               check
               |> Ash.Changeset.for_update(:enable, %{}, actor: actor())
               |> Ash.update()

      assert Exception.message(error) =~ "agent-b"

      assert {:ok, enabled} =
               check
               |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true},
                 actor: actor()
               )
               |> Ash.update()

      assert enabled.state == :enabled
    end

    test "a ready check enables without acknowledgement" do
      check = build_check([{"a", "available"}, {"b", "blocked"}])

      for uid <- ["device-1", "device-2"], agent <- ["agent-a", "agent-b"] do
        availability(uid, agent)
      end

      assert {:ok, enabled} =
               check
               |> Ash.Changeset.for_update(:enable, %{}, actor: actor())
               |> Ash.update()

      assert enabled.state == :enabled
    end

    test "set_state cannot be used to bypass the enable gate" do
      check = build_check([{"a", "blocked"}, {"b", "blocked"}])

      assert {:error, _} =
               check
               |> Ash.Changeset.for_update(:set_state, %{state: :enabled}, actor: actor())
               |> Ash.update()
    end
  end
end
