defmodule ServiceRadarWebNG.Plugins.AddonAssignmentsTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins.AddonAssignments

  test "upsert updates an existing assignment even when form attrs include immutable keys" do
    addon_id = unique_addon_id("upsert")
    agent_uid = "agent-addon-upsert-#{System.unique_integer([:positive])}"
    scope = Scope.for_user(%{id: "admin-addon-upsert", email: "admin@example.test", role: :admin})
    old_package = addon_id |> create_addon_package!("1.0.0") |> approve_package!()

    assignment =
      create_assignment!(agent_uid, old_package.id,
        args: ["--old"],
        params: %{"capture" => false},
        enabled: false
      )

    new_package = addon_id |> create_addon_package!("1.0.1") |> approve_package!()

    assert {:ok, updated} =
             AddonAssignments.upsert(
               addon_id,
               %{
                 agent_uid: agent_uid,
                 addon_id: addon_id,
                 addon_package_id: new_package.id,
                 args: ["--new"],
                 params: %{"capture" => true}
               },
               scope: scope
             )

    assert updated.id == assignment.id
    assert updated.agent_uid == agent_uid
    assert updated.addon_id == addon_id
    assert updated.addon_package_id == new_package.id
    assert updated.args == ["--new"]
    assert updated.params == %{"capture" => true}
    assert updated.enabled == true
  end

  test "upsert threads actor options when no UI scope is present" do
    addon_id = unique_addon_id("system-upsert")
    agent_uid = "agent-addon-system-upsert-#{System.unique_integer([:positive])}"
    old_package = addon_id |> create_addon_package!("1.0.0") |> approve_package!()

    assignment =
      create_assignment!(agent_uid, old_package.id,
        args: ["--old"],
        params: %{"enabled" => false},
        enabled: true
      )

    new_package = addon_id |> create_addon_package!("1.0.1") |> approve_package!()

    assert {:ok, updated} =
             AddonAssignments.upsert(
               addon_id,
               %{
                 agent_uid: agent_uid,
                 addon_package_id: new_package.id,
                 args: ["--new"],
                 params: %{"enabled" => true}
               },
               actor: system_actor()
             )

    assert updated.id == assignment.id
    assert updated.addon_package_id == new_package.id
    assert updated.args == ["--new"]
    assert updated.params == %{"enabled" => true}
  end

  defp unique_addon_id(prefix), do: "addon-assignment-#{prefix}-#{System.unique_integer([:positive])}"

  defp create_addon_package!(addon_id, version) do
    AddonPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        addon_id: addon_id,
        name: "Add-on Assignment Test",
        version: version,
        description: "Test add-on",
        kind: :native,
        delivery: :pushed_artifact,
        supervision: :agent_sidecar,
        binary: "serviceradar-addon",
        install_path: "/usr/local/lib/serviceradar/bin",
        capabilities: ["addon.run"],
        config_schema: %{},
        artifacts: %{},
        requires: %{},
        source_type: :first_party,
        source_oci_ref: "registry.carverauto.dev/serviceradar/addon:test",
        source_oci_digest: "sha256:test",
        source_release_tag: "v1.0.0",
        source_metadata: %{},
        imported_at: DateTime.utc_now(),
        verification_status: "verified"
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp approve_package!(%AddonPackage{} = package) do
    package
    |> Ash.Changeset.for_update(
      :approve,
      %{approved_capabilities: package.capabilities, approved_by: "test"},
      actor: system_actor()
    )
    |> Ash.update!()
  end

  defp create_assignment!(agent_uid, package_id, opts) do
    AddonAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: agent_uid,
        addon_package_id: package_id,
        source: :manual,
        enabled: Keyword.get(opts, :enabled, true),
        args: Keyword.get(opts, :args, []),
        params: Keyword.get(opts, :params, %{})
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end
end
