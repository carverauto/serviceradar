defmodule ServiceRadar.Identity.MappedUserGroupsTest do
  @moduledoc """
  Groups mappings that never named a `user_group_id` still have to produce a
  ServiceRadar user group. Otherwise Settings -> User Groups stays empty while
  users already have group-based access from the identity provider.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.MappedUserGroups
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:mapped_user_groups_test)}
  end

  test "ensure_from_settings creates a group named after each groups mapping", %{actor: actor} do
    group_name = "network-ops-#{System.unique_integer([:positive])}"
    settings!(actor, [%{"source" => "groups", "value" => group_name, "role" => "operator"}])

    assert :ok = MappedUserGroups.ensure_from_settings(actor: actor)

    assert {:ok, %UserGroup{name: ^group_name}} =
             UserGroup
             |> Ash.Query.filter(name == ^group_name)
             |> Ash.read_one(actor: actor)
  end

  test "ids_for_resolution includes the group implied by a mapping value", %{actor: actor} do
    group_name = "share-#{System.unique_integer([:positive])}"

    ids =
      MappedUserGroups.ids_for_resolution(
        %{
          user_group_ids: [],
          matched: [%{"source" => "groups", "value" => group_name, "role" => "operator"}]
        },
        actor: actor
      )

    assert {:ok, %UserGroup{id: group_id, name: ^group_name}} =
             UserGroup
             |> Ash.Query.filter(name == ^group_name)
             |> Ash.read_one(actor: actor)

    assert ids == [group_id]
  end

  test "ids_for_resolution keeps an explicit user_group_id", %{actor: actor} do
    {:ok, group} =
      UserGroup.create_group(%{name: "explicit-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    ids =
      MappedUserGroups.ids_for_resolution(
        %{
          user_group_ids: [group.id],
          matched: [
            %{
              "source" => "groups",
              "value" => "ignored-name-#{System.unique_integer([:positive])}",
              "user_group_id" => group.id
            }
          ]
        },
        actor: actor
      )

    assert ids == [group.id]
  end

  test "ids_for_resolution treats a missing mapping source as groups", %{actor: actor} do
    missing_name = "legacy-#{System.unique_integer([:positive])}"
    blank_name = "blank-#{System.unique_integer([:positive])}"

    ids =
      MappedUserGroups.ids_for_resolution(
        %{
          user_group_ids: [],
          matched: [
            %{"value" => missing_name, "role" => "operator"},
            %{"source" => "", "value" => blank_name, "role" => "operator"}
          ]
        },
        actor: actor
      )

    assert {:ok, %UserGroup{id: missing_id, name: ^missing_name}} =
             UserGroup
             |> Ash.Query.filter(name == ^missing_name)
             |> Ash.read_one(actor: actor)

    assert {:ok, %UserGroup{id: blank_id, name: ^blank_name}} =
             UserGroup
             |> Ash.Query.filter(name == ^blank_name)
             |> Ash.read_one(actor: actor)

    assert Enum.sort(ids) == Enum.sort([missing_id, blank_id])
  end

  test "ids_for_resolution does not create a group for a non-groups mapping", %{actor: actor} do
    domain = "example-#{System.unique_integer([:positive])}.test"

    assert [] =
             MappedUserGroups.ids_for_resolution(
               %{
                 user_group_ids: [],
                 matched: [%{"source" => "email_domain", "value" => domain, "role" => "operator"}]
               },
               actor: actor
             )
  end

  defp settings!(actor, mappings) do
    attrs = %{default_role: :viewer, role_mappings: mappings}

    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, %AuthorizationSettings{} = existing} ->
        {:ok, settings} = AuthorizationSettings.update_settings(existing, attrs, actor: actor)
        settings

      _not_found ->
        {:ok, settings} = AuthorizationSettings.create_settings(attrs, actor: actor)
        settings
    end
  end
end
