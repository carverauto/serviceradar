defmodule ServiceRadar.Identity.CurrentUserAuthorityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.CurrentUserAuthority

  @permission "devices.remote_access.ssh.open"
  @user_id "4e652f03-c259-47a7-a4a6-d8ac018e2948"

  test "ignores cached scope permissions and denies after current authority contracts" do
    stale_scope = %{
      user: %{id: @user_id, status: :active, role: :admin},
      permissions: MapSet.new([@permission])
    }

    dependencies = %{
      load_user: fn @user_id ->
        {:ok, %{id: @user_id, status: :active, role: :viewer}}
      end,
      load_authority: fn _current_user ->
        {:ok, %{permissions: MapSet.new(), profile_versions: []}}
      end
    }

    assert {:error, :current_authority_denied} =
             CurrentUserAuthority.authorize(stale_scope, @permission, dependencies: dependencies)
  end

  test "returns the reloaded human and complete current permission set" do
    current_user = %{id: @user_id, status: :active, role: :operator}
    permissions = MapSet.new([@permission, "devices.remote_access.view"])

    dependencies = %{
      load_user: fn @user_id -> {:ok, current_user} end,
      load_authority: fn ^current_user ->
        {:ok, %{permissions: permissions, profile_versions: []}}
      end
    }

    assert {:ok, %{user: ^current_user, permissions: ^permissions, profile_versions: []}} =
             CurrentUserAuthority.authorize(
               %{user: %{id: @user_id}, permissions: MapSet.new()},
               [@permission, "devices.remote_access.view"],
               dependencies: dependencies
             )
  end

  test "denies inactive current users before loading their profile" do
    test_pid = self()

    dependencies = %{
      load_user: fn @user_id ->
        {:ok, %{id: @user_id, status: :inactive, role: :admin}}
      end,
      load_authority: fn _current_user ->
        send(test_pid, :permissions_loaded)
        {:ok, %{permissions: MapSet.new([@permission]), profile_versions: []}}
      end
    }

    assert {:error, :current_authority_denied} =
             CurrentUserAuthority.authorize(%{id: @user_id}, @permission,
               dependencies: dependencies
             )

    refute_received :permissions_loaded
  end

  test "denies a mismatched reload and system principals" do
    dependencies = %{
      load_user: fn @user_id ->
        {:ok, %{id: "8f5686a2-f48f-4fe9-8da9-04a9dbd3a373", status: :active, role: :admin}}
      end,
      load_authority: fn _current_user ->
        {:ok, %{permissions: MapSet.new([@permission]), profile_versions: []}}
      end
    }

    assert {:error, :current_authority_denied} =
             CurrentUserAuthority.authorize(%{id: @user_id}, @permission,
               dependencies: dependencies
             )

    assert {:error, :current_authority_denied} =
             CurrentUserAuthority.authorize(
               %{id: @user_id, role: :system},
               @permission,
               dependencies: dependencies
             )
  end

  test "fails closed when persistence or profile loading raises, exits, or returns invalid data" do
    base = %{load_user: fn @user_id -> {:ok, %{id: @user_id, status: :active, role: :admin}} end}

    for load_authority <- [
          fn _ -> {:error, :database_unavailable} end,
          fn _ -> raise "database unavailable" end,
          fn _ -> exit(:database_unavailable) end,
          fn _ -> {:ok, :not_a_permission_set} end
        ] do
      assert {:error, :current_authority_denied} =
               CurrentUserAuthority.authorize(%{id: @user_id}, @permission,
                 dependencies: Map.put(base, :load_authority, load_authority)
               )
    end
  end

  test "an empty permission list reloads current authority without a permission gate" do
    current_user = %{id: @user_id, status: :active, role: :operator}

    assert {:ok, %{user: ^current_user, permissions: permissions, profile_versions: []}} =
             CurrentUserAuthority.authorize(%{id: @user_id}, [],
               dependencies: %{
                 load_user: fn @user_id -> {:ok, current_user} end,
                 load_authority: fn ^current_user ->
                   {:ok, %{permissions: MapSet.new(["analytics.view"]), profile_versions: []}}
                 end
               }
             )

    assert MapSet.member?(permissions, "analytics.view")
  end

  test "rejects blank or mixed permission requests" do
    refute_authorized = fn required ->
      assert {:error, :current_authority_denied} =
               CurrentUserAuthority.authorize(%{id: @user_id}, required,
                 dependencies: %{
                   load_user: fn _ -> flunk("invalid requests must not read storage") end,
                   load_authority: fn _ ->
                     flunk("invalid requests must not load permissions")
                   end
                 }
               )
    end

    refute_authorized.("")
    refute_authorized.([@permission, nil])
  end

  test "returns deterministic group-derived authority versions and denies graph-load errors" do
    current_user = %{id: @user_id, status: :active, role: :viewer}
    updated_at = ~U[2026-09-04 00:00:00Z]

    assert {:ok,
            %{
              permissions: permissions,
              profile_versions: [%{id: "profile-group", updated_at: ^updated_at}]
            }} =
             CurrentUserAuthority.authorize(%{id: @user_id}, "alerts.acknowledge",
               dependencies: %{
                 load_user: fn @user_id -> {:ok, current_user} end,
                 load_authority: fn ^current_user ->
                   {:ok,
                    %{
                      permissions: MapSet.new(["alerts.acknowledge"]),
                      profile_versions: [%{id: "profile-group", updated_at: updated_at}]
                    }}
                 end
               }
             )

    assert MapSet.member?(permissions, "alerts.acknowledge")

    assert {:error, :current_authority_denied} =
             CurrentUserAuthority.authorize(%{id: @user_id}, "alerts.acknowledge",
               dependencies: %{
                 load_user: fn @user_id -> {:ok, current_user} end,
                 load_authority: fn ^current_user -> {:error, :group_graph_unavailable} end
               }
             )
  end
end
