defmodule ServiceRadar.CompositeChecks.CompositeCheckInputTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Input Fixture #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    %{check: check}
  end

  defp create_input(check, attrs) do
    CompositeCheckInput
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
    |> Ash.create()
  end

  test "creates a vantage point input", %{check: check} do
    assert {:ok, input} =
             create_input(check, %{
               key: "agent_a",
               label: "agent-a · dmz-01",
               position: 0,
               kind: :vantage_point,
               expected: "available",
               config: %{"agent_id" => "agent-a", "max_age_seconds" => 900}
             })

    assert input.kind == :vantage_point
    assert input.config["agent_id"] == "agent-a"
  end

  test "creates a device metadata input", %{check: check} do
    assert {:ok, input} =
             create_input(check, %{
               key: "nac",
               label: "NCO nac_applied",
               position: 2,
               kind: :device_metadata,
               config: %{
                 "path" => "nac_applied",
                 "value_type" => "boolean",
                 "max_age_seconds" => 86_400
               }
             })

    assert input.config["path"] == "nac_applied"
  end

  test "rejects a vantage point input with no agent_id", %{check: check} do
    assert {:error, error} =
             create_input(check, %{
               key: "agent_b",
               label: "agent-b",
               position: 1,
               kind: :vantage_point,
               config: %{"max_age_seconds" => 900}
             })

    assert Exception.message(error) =~ "agent_id"
  end

  test "rejects a metadata input with an unsupported value type", %{check: check} do
    assert {:error, error} =
             create_input(check, %{
               key: "weird",
               label: "Weird",
               position: 3,
               kind: :device_metadata,
               config: %{"path" => "x", "value_type" => "blob"}
             })

    assert Exception.message(error) =~ "value_type"
  end

  test "rejects a duplicate key within one check", %{check: check} do
    assert {:ok, _} =
             create_input(check, %{
               key: "agent_a",
               label: "A",
               position: 0,
               kind: :vantage_point,
               config: %{"agent_id" => "agent-a"}
             })

    assert {:error, error} =
             create_input(check, %{
               key: "agent_a",
               label: "A again",
               position: 1,
               kind: :vantage_point,
               config: %{"agent_id" => "agent-z"}
             })

    assert Exception.message(error) =~ "already been taken"
  end

  test "max_age_seconds is optional", %{check: check} do
    assert {:ok, input} =
             create_input(check, %{
               key: "legacy_fact",
               label: "Legacy fact",
               position: 4,
               kind: :device_metadata,
               config: %{"path" => "legacy_flag", "value_type" => "boolean"}
             })

    refute Map.has_key?(input.config, "max_age_seconds")
  end

  test "the same key is allowed on a different check", %{check: check} do
    {:ok, other} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Other Fixture #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    attrs = %{
      key: "agent_a",
      label: "A",
      position: 0,
      kind: :vantage_point,
      config: %{"agent_id" => "agent-a"}
    }

    assert {:ok, _} = create_input(check, attrs)
    assert {:ok, _} = create_input(other, attrs)
  end

  test "deleting a check deletes its inputs", %{check: check} do
    {:ok, _} =
      create_input(check, %{
        key: "agent_a",
        label: "A",
        position: 0,
        kind: :vantage_point,
        config: %{"agent_id" => "agent-a"}
      })

    admin = %{id: Ash.UUID.generate(), role: :admin}
    assert :ok = Ash.destroy(check, actor: admin)
    assert {:ok, []} = CompositeCheckInput.list_by_check(check.id, actor: actor())
  end
end
