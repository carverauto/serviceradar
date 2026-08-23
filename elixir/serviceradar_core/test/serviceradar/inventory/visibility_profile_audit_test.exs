defmodule ServiceRadar.Inventory.VisibilityProfileAuditTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: "user:visibility-auditor",
      email: "visibility-auditor@example.com",
      role: :admin,
      permissions:
        MapSet.new([
          "visibility_profiles:read",
          "visibility_profiles:write",
          "visibility_profiles:delete"
        ])
    }

    {:ok, actor: actor}
  end

  test "profile posture changes write AshPaperTrail audit rows", %{actor: actor} do
    unique = Ash.UUID.generate()
    name = "Audit #{unique}"

    {:ok, profile} =
      VisibilityProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: name,
          partition_id: "audit-partition",
          target_query: "in:devices type:0",
          capture_interfaces: ["eth0"],
          enabled: true
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, profile} =
      profile
      |> Ash.Changeset.for_update(:update, %{enabled: false, priority: 10}, actor: actor)
      |> Ash.update()

    assert :ok =
             profile
             |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
             |> Ash.destroy()

    rows =
      Repo.query!(
        """
        SELECT version_action_type,
               version_action_name,
               version_action_inputs,
               partition_id,
               changes,
               actor,
               actor_id,
               request_id
        FROM platform.visibility_profile_versions
        WHERE version_source_id = $1
        ORDER BY version_inserted_at ASC
        """,
        [Ecto.UUID.dump!(profile.id)]
      ).rows

    assert [
             [
               "create",
               "create",
               create_inputs,
               "audit-partition",
               create_changes,
               audit_actor,
               "user:visibility-auditor",
               _
             ],
             [
               "update",
               "update",
               update_inputs,
               "audit-partition",
               update_changes,
               _,
               "user:visibility-auditor",
               _
             ],
             [
               "destroy",
               "destroy",
               destroy_inputs,
               "audit-partition",
               _,
               _,
               "user:visibility-auditor",
               _
             ]
           ] = rows

    assert audit_actor == %{
             "id" => "user:visibility-auditor",
             "email" => "visibility-auditor@example.com",
             "role" => "admin"
           }

    assert get_in(create_inputs, ["actor", "id"]) == "user:visibility-auditor"
    assert get_in(update_inputs, ["actor", "email"]) == "visibility-auditor@example.com"
    assert get_in(destroy_inputs, ["actor", "role"]) == "admin"

    assert get_in(create_changes, ["name", "to"]) == name
    assert get_in(update_changes, ["enabled", "from"]) == true
    assert get_in(update_changes, ["enabled", "to"]) == false
    assert get_in(update_changes, ["priority", "from"]) == 0
    assert get_in(update_changes, ["priority", "to"]) == 10
  end
end
