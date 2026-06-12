defmodule ServiceRadarWebNG.Plugins.AddonAssignmentsTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
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

  test "upsert and profiles reject blob-missing approved packages" do
    addon_id = unique_addon_id("blob-missing")
    agent_uid = "agent-addon-blob-missing-#{System.unique_integer([:positive])}"
    scope = Scope.for_user(%{id: "admin-addon-blob-missing", email: "admin@example.test", role: :admin})

    package =
      addon_id
      |> create_addon_package!("1.0.0")
      |> approve_package!()
      |> mark_blob_missing!()

    assert {:error, assignment_error} =
             AddonAssignments.upsert(
               addon_id,
               %{
                 agent_uid: agent_uid,
                 addon_package_id: package.id,
                 args: [],
                 params: %{}
               },
               scope: scope
             )

    assert inspect(assignment_error) =~ "add-on package artifact is missing from object storage"

    assert {:error, profile_error} =
             AddonProfile
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Blob Missing Profile",
                 addon_package_id: package.id,
                 target_query: "in:agents",
                 params: %{},
                 args: [],
                 enabled: true
               },
               actor: system_actor()
             )
             |> Ash.create()

    assert inspect(profile_error) =~ "add-on package artifact is missing from object storage"
  end

  test "existing blob-missing assignments and profiles can be disabled but not re-enabled" do
    addon_id = unique_addon_id("blob-missing-disable")
    agent_uid = "agent-addon-blob-missing-disable-#{System.unique_integer([:positive])}"

    package =
      addon_id
      |> create_addon_package!("1.0.0")
      |> approve_package!()

    assignment = create_assignment!(agent_uid, package.id, enabled: true, args: [], params: %{})
    profile = create_profile!(package.id, enabled: true)

    mark_blob_missing!(package)

    assert {:ok, disabled_assignment} =
             assignment
             |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: system_actor())
             |> Ash.update()

    refute disabled_assignment.enabled

    assert {:error, assignment_error} =
             disabled_assignment
             |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: system_actor())
             |> Ash.update()

    assert inspect(assignment_error) =~ "add-on package artifact is missing from object storage"

    assert {:ok, disabled_profile} =
             profile
             |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: system_actor())
             |> Ash.update()

    refute disabled_profile.enabled

    assert {:error, profile_error} =
             disabled_profile
             |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: system_actor())
             |> Ash.update()

    assert inspect(profile_error) =~ "add-on package artifact is missing from object storage"
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

  defp mark_blob_missing!(%AddonPackage{} = package) do
    package
    |> Ash.Changeset.for_update(
      :update,
      %{
        verification_status: "blob_missing",
        verification_error: "native add-on artifact object missing: native-addons/missing.tar.gz"
      },
      actor: system_actor()
    )
    |> Ash.update!()
  end

  defp create_profile!(package_id, opts) do
    AddonProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Blob Missing Disable Profile",
        addon_package_id: package_id,
        target_query: "in:agents",
        params: %{},
        args: [],
        enabled: Keyword.get(opts, :enabled, true)
      },
      actor: system_actor()
    )
    |> Ash.create!()
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
