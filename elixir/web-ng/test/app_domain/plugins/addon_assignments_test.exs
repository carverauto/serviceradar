defmodule ServiceRadarWebNG.Plugins.AddonAssignmentsTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [gateway_fixture: 1, system_actor: 0]

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins.AddonAssignments

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  test "upsert updates an existing assignment even when form attrs include immutable keys" do
    addon_id = unique_addon_id("upsert")
    agent_uid = "agent-addon-upsert-#{System.unique_integer([:positive])}"
    scope = Scope.for_user(%{id: "admin-addon-upsert", email: "admin@example.test", role: :admin})
    connected_agent!(agent_uid)
    old_package = addon_id |> create_addon_package!("1.0.0") |> approve_package!()

    assignment =
      create_assignment!(agent_uid, old_package.id,
        args: ["--old"],
        params: %{"capture" => false},
        enabled: false
      )

    new_package =
      addon_id |> create_addon_package!("1.0.1", platform_artifact()) |> approve_package!()

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
    assert updated.args == ["--new"]
    assert updated.params == %{"capture" => true}
    assert updated.enabled == true
    assert_upgrade_rolling_out(updated, old_package, new_package)
  end

  test "upsert threads actor options when no UI scope is present" do
    addon_id = unique_addon_id("system-upsert")
    agent_uid = "agent-addon-system-upsert-#{System.unique_integer([:positive])}"
    connected_agent!(agent_uid)
    old_package = addon_id |> create_addon_package!("1.0.0") |> approve_package!()

    assignment =
      create_assignment!(agent_uid, old_package.id,
        args: ["--old"],
        params: %{"enabled" => false},
        enabled: true
      )

    new_package =
      addon_id |> create_addon_package!("1.0.1", platform_artifact()) |> approve_package!()

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
    assert updated.args == ["--new"]
    assert updated.params == %{"enabled" => true}
    assert_upgrade_rolling_out(updated, old_package, new_package)
  end

  test "upsert with an unknown package id leaves the assignment untouched" do
    addon_id = unique_addon_id("unknown-package")
    agent_uid = "agent-addon-unknown-package-#{System.unique_integer([:positive])}"
    scope = Scope.for_user(%{id: "admin-addon-unknown-package", email: "admin@example.test", role: :admin})
    connected_agent!(agent_uid)
    old_package = addon_id |> create_addon_package!("1.0.0") |> approve_package!()

    assignment =
      create_assignment!(agent_uid, old_package.id,
        args: ["--old"],
        params: %{"capture" => false},
        enabled: false
      )

    assert {:error, _} =
             AddonAssignments.upsert(
               addon_id,
               %{
                 agent_uid: agent_uid,
                 addon_id: addon_id,
                 addon_package_id: Ecto.UUID.generate(),
                 update_policy: :manual_pin,
                 args: ["--new"],
                 params: %{"capture" => true}
               },
               scope: scope
             )

    assert_assignment_untouched(assignment, old_package)
  end

  test "upsert with invalid settings leaves the assignment untouched and starts no rollout" do
    addon_id = unique_addon_id("invalid-settings")
    agent_uid = "agent-addon-invalid-settings-#{System.unique_integer([:positive])}"
    scope = Scope.for_user(%{id: "admin-addon-invalid-settings", email: "admin@example.test", role: :admin})
    connected_agent!(agent_uid)
    old_package = addon_id |> create_addon_package!("1.0.0") |> approve_package!()

    assignment =
      create_assignment!(agent_uid, old_package.id,
        args: ["--old"],
        params: %{"capture" => false},
        enabled: false
      )

    new_package =
      addon_id |> create_addon_package!("1.0.1", platform_artifact()) |> approve_package!()

    assert {:error, _} =
             AddonAssignments.upsert(
               addon_id,
               %{
                 agent_uid: agent_uid,
                 addon_id: addon_id,
                 addon_package_id: new_package.id,
                 update_policy: :manual_pin,
                 args: "not-a-list",
                 params: %{"capture" => true}
               },
               scope: scope
             )

    assert_assignment_untouched(assignment, old_package)
  end

  test "upsert with an unstartable candidate leaves the assignment untouched" do
    addon_id = unique_addon_id("unstartable")
    agent_uid = "agent-addon-unstartable-#{System.unique_integer([:positive])}"
    scope = Scope.for_user(%{id: "admin-addon-unstartable", email: "admin@example.test", role: :admin})
    connected_agent!(agent_uid)
    old_package = addon_id |> create_addon_package!("1.0.0") |> approve_package!()

    assignment =
      create_assignment!(agent_uid, old_package.id,
        args: ["--old"],
        params: %{"capture" => false},
        enabled: false
      )

    bare_package = addon_id |> create_addon_package!("1.0.1") |> approve_package!()

    assert {:error, _} =
             AddonAssignments.upsert(
               addon_id,
               %{
                 agent_uid: agent_uid,
                 addon_id: addon_id,
                 addon_package_id: bare_package.id,
                 update_policy: :manual_pin,
                 args: ["--new"],
                 params: %{"capture" => true}
               },
               scope: scope
             )

    assert_assignment_untouched(assignment, old_package)
  end

  test "upsert while a rollout is active leaves the in-flight upgrade alone" do
    addon_id = unique_addon_id("active-rollout")
    agent_uid = "agent-addon-active-rollout-#{System.unique_integer([:positive])}"
    scope = Scope.for_user(%{id: "admin-addon-active-rollout", email: "admin@example.test", role: :admin})
    connected_agent!(agent_uid)
    old_package = addon_id |> create_addon_package!("1.0.0") |> approve_package!()

    assignment =
      create_assignment!(agent_uid, old_package.id,
        args: ["--old"],
        params: %{"capture" => false},
        enabled: false
      )

    package_b = addon_id |> create_addon_package!("1.0.1", platform_artifact()) |> approve_package!()

    assert {:ok, upgraded} =
             AddonAssignments.upsert(
               addon_id,
               %{
                 agent_uid: agent_uid,
                 addon_id: addon_id,
                 addon_package_id: package_b.id,
                 args: ["--v1"],
                 params: %{"capture" => true}
               },
               scope: scope
             )

    package_c = addon_id |> create_addon_package!("1.0.2", platform_artifact()) |> approve_package!()

    assert {:error, _} =
             AddonAssignments.upsert(
               addon_id,
               %{
                 agent_uid: agent_uid,
                 addon_id: addon_id,
                 addon_package_id: package_c.id,
                 update_policy: :manual_pin,
                 args: ["--v2"],
                 params: %{"capture" => false}
               },
               scope: scope
             )

    [reloaded] =
             AddonAssignment
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(id == ^assignment.id)
             |> Ash.read!(actor: system_actor())

    assert reloaded.addon_package_id == old_package.id
    assert reloaded.update_policy == upgraded.update_policy
    assert reloaded.args == ["--v1"]
    assert reloaded.params == %{"capture" => true}

    assert [rollout] =
             AddonRollout
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(source_id == ^assignment.id)
             |> Ash.read!(actor: system_actor())

    assert rollout.candidate_package_id == package_b.id
    assert rollout.previous_package_id == old_package.id
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

  # A different package is delivered by a health-gated rollout, never swapped in
  # place: the stable package stays authoritative and the rollout carries the
  # candidate. The rollout snapshots the configuration it may roll back to.
  defp assert_upgrade_rolling_out(updated, old_package, new_package) do
    assert updated.addon_package_id == old_package.id

    assert [rollout] =
             AddonRollout
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(source_id == ^updated.id)
             |> Ash.read!(actor: system_actor())

    assert rollout.candidate_package_id == new_package.id
    assert rollout.previous_package_id == old_package.id
  end

  defp assert_assignment_untouched(assignment, old_package) do
    [reloaded] =
             AddonAssignment
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(id == ^assignment.id)
             |> Ash.read!(actor: system_actor())

    assert reloaded.addon_package_id == old_package.id
    assert reloaded.update_policy == assignment.update_policy
    assert reloaded.args == assignment.args
    assert reloaded.params == assignment.params
    assert reloaded.enabled == assignment.enabled

    assert [] =
             AddonRollout
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(source_id == ^assignment.id)
             |> Ash.read!(actor: system_actor())
  end

  # Rollouts only target an agent that is connected, recently seen, and has a
  # candidate artifact for its platform.
  defp connected_agent!(agent_uid) do
    gateway = gateway_fixture(%{})

    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "Upsert Agent #{agent_uid}",
        gateway_id: gateway.id,
        version: "1.0.0",
        type_id: 4,
        type: "Performance",
        capabilities: ["agent"],
        metadata: %{"os" => "linux", "arch" => "amd64"}
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp platform_artifact do
    %{
      "linux/amd64" => %{
        "object_key" => "native-addons/upsert-test/linux-amd64.tar.gz",
        "sha256" => String.duplicate("d", 64)
      }
    }
  end

  defp create_addon_package!(addon_id, version, artifacts \\ %{}) do
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
        artifacts: artifacts,
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
