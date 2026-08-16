defmodule ServiceRadarWebNG.Plugins.AddonProfilesTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins.AddonProfiles

  require Ash.Query

  test "delete removes the profile and its profile-owned assignments" do
    addon_id = "addon-profile-delete-#{System.unique_integer([:positive])}"
    agent_uid = "agent-profile-delete-#{System.unique_integer([:positive])}"
    scope = Scope.for_user(%{id: "admin-profile-delete", email: "admin@example.test", role: :admin})

    package =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          name: "Profile Delete Test",
          version: "1.0.0",
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
      |> Ash.Changeset.for_update(
        :approve,
        %{approved_capabilities: ["addon.run"], approved_by: "test"},
        actor: system_actor()
      )
      |> Ash.update!()

    profile =
      AddonProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Delete me",
          addon_package_id: package.id,
          target_query: "in:agents",
          params: %{},
          args: [],
          enabled: true
        },
        actor: system_actor()
      )
      |> Ash.create!()

    assignment =
      AddonAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          addon_package_id: package.id,
          source: :profile,
          source_key: "profile:#{profile.id}:#{agent_uid}",
          addon_profile_id: profile.id,
          enabled: true,
          params: %{},
          args: []
        },
        actor: system_actor()
      )
      |> Ash.create!()

    assert {:ok, deleted} = AddonProfiles.delete(profile.id, scope: scope)
    assert deleted.id == profile.id

    assert {:ok, nil} =
             AddonProfile
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(id == ^profile.id)
             |> Ash.read_one(actor: system_actor())

    assert {:ok, nil} =
             AddonAssignment
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(id == ^assignment.id)
             |> Ash.read_one(actor: system_actor())
  end

  test "create rejects device-targeted SRQL and accepts agent filters" do
    package = approved_package!("addon-profile-target-#{System.unique_integer([:positive])}")

    assert {:error, %Ash.Error.Invalid{} = error} =
             AddonProfile
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Devices are wrong",
                 addon_package_id: package.id,
                 target_query: "in:devices hostname:dusk*",
                 params: %{},
                 args: [],
                 enabled: true
               },
               actor: system_actor()
             )
             |> Ash.create()

    assert Exception.message(error) =~ "must target agents"

    assert {:ok, profile} =
             AddonProfile
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Linux canaries",
                 addon_package_id: package.id,
                 target_query: "hostname:dusk*",
                 params: %{},
                 args: [],
                 enabled: true
               },
               actor: system_actor()
             )
             |> Ash.create()

    assert profile.target_query == "in:agents hostname:dusk*"
  end

  defp approved_package!(addon_id) do
    AddonPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        addon_id: addon_id,
        name: "Profile Target Test",
        version: "1.0.0",
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
    |> Ash.Changeset.for_update(
      :approve,
      %{approved_capabilities: ["addon.run"], approved_by: "test"},
      actor: system_actor()
    )
    |> Ash.update!()
  end
end
