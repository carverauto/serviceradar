defmodule ServiceRadar.Plugins.SingleEnabledAddonProfileDbTest do
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:single_enabled_addon_profile_db_test)
    %{actor: actor}
  end

  test "a second enabled anomaly profile is rejected on create and enable", %{actor: actor} do
    package = approved_package("anomaly", actor)

    {:ok, first} = create_profile(package, "Anomaly A", true, actor)

    assert {:error, %Invalid{} = error} =
             create_profile(package, "Anomaly B", true, actor)

    assert Exception.message(error) =~ "only one enabled add-on profile"
    assert Exception.message(error) =~ first.name

    {:ok, second} = create_profile(package, "Anomaly B", false, actor)

    assert {:error, %Invalid{} = error} = update_profile(second, %{enabled: true}, actor)
    assert Exception.message(error) =~ first.name

    {:ok, _first} = update_profile(first, %{enabled: false}, actor)
    assert {:ok, _second} = update_profile(second, %{enabled: true}, actor)
  end

  test "updates that do not enable a profile skip the uniqueness check", %{actor: actor} do
    package = approved_package("anomaly", actor)

    {:ok, first} = create_profile(package, "Anomaly A", true, actor)
    {:ok, _second} = create_profile(package, "Anomaly B", false, actor)

    assert {:ok, updated} = update_profile(first, %{description: "still editable"}, actor)
    assert updated.description == "still editable"

    assert {:ok, disabled} = update_profile(first, %{enabled: false}, actor)
    refute disabled.enabled
  end

  test "the partial unique index backstops the validation against races", %{actor: actor} do
    package = approved_package("anomaly", actor)

    {:ok, _first} = create_profile(package, "Anomaly A", true, actor)
    {:ok, second} = create_profile(package, "Anomaly B", false, actor)

    # The validation reads-then-writes, so a concurrent enable can slip past
    # it; writing past the validation simulates the losing side of that race
    # and must be stopped by addon_profiles_single_enabled_anomaly_index.
    assert_raise Postgrex.Error, ~r/addon_profiles_single_enabled_anomaly_index/, fn ->
      Repo.update_all(
        from(p in AddonProfile, where: p.id == ^second.id),
        [set: [enabled: true]],
        prefix: "platform"
      )
    end
  end

  test "atomic/bulk updates fall back and cannot bypass the enabled check", %{actor: actor} do
    package = approved_package("anomaly", actor)

    {:ok, _first} = create_profile(package, "Anomaly A", true, actor)
    {:ok, second} = create_profile(package, "Anomaly B", false, actor)

    # The validation returns {:not_atomic, ..}: the atomic strategy must not
    # silently pass, and the stream fallback must run validate/3.
    result =
      AddonProfile
      |> Ash.Query.filter(id == ^second.id)
      |> Ash.bulk_update(:update, %{enabled: true},
        actor: actor,
        strategy: [:atomic, :atomic_batches, :stream],
        return_errors?: true
      )

    assert result.status == :error

    assert Enum.any?(List.wrap(result.errors), fn error ->
             Exception.message(error) =~ "only one enabled add-on profile"
           end)
  end

  test "non-exclusive add-ons keep multiple enabled profiles", %{actor: actor} do
    package = approved_package("netprobe-profile-test", actor)

    assert {:ok, _first} = create_profile(package, "Netprobe A", true, actor)
    assert {:ok, _second} = create_profile(package, "Netprobe B", true, actor)
  end

  defp approved_package(addon_id, actor) do
    unique = System.unique_integer([:positive])

    {:ok, package} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          version: "0.0.#{unique}",
          name: "#{addon_id} package #{unique}",
          artifacts: %{"linux/amd64" => %{}},
          requires: %{},
          config_schema: %{"type" => "object"}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(
        :approve,
        %{
          approved_capabilities: [],
          approved_by: "system:single_enabled_addon_profile_db_test"
        },
        actor: actor
      )
      |> Ash.update()

    package
  end

  defp create_profile(package, name, enabled, actor) do
    AddonProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        addon_package_id: package.id,
        target_query: "in:agents",
        enabled: enabled
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp update_profile(profile, attrs, actor) do
    profile
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update()
  end
end
