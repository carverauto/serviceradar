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
      load_permissions: fn _current_user -> {:ok, MapSet.new()} end
    }

    assert {:error, :current_authority_denied} =
             CurrentUserAuthority.authorize(stale_scope, @permission, dependencies: dependencies)
  end

  test "returns the reloaded human and complete current permission set" do
    current_user = %{id: @user_id, status: :active, role: :operator}
    permissions = MapSet.new([@permission, "devices.remote_access.view"])

    dependencies = %{
      load_user: fn @user_id -> {:ok, current_user} end,
      load_permissions: fn ^current_user -> {:ok, permissions} end
    }

    assert {:ok, %{user: ^current_user, permissions: ^permissions}} =
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
      load_permissions: fn _current_user ->
        send(test_pid, :permissions_loaded)
        {:ok, MapSet.new([@permission])}
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
      load_permissions: fn _current_user -> {:ok, MapSet.new([@permission])} end
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

    for load_permissions <- [
          fn _ -> {:error, :database_unavailable} end,
          fn _ -> raise "database unavailable" end,
          fn _ -> exit(:database_unavailable) end,
          fn _ -> {:ok, :not_a_permission_set} end
        ] do
      assert {:error, :current_authority_denied} =
               CurrentUserAuthority.authorize(%{id: @user_id}, @permission,
                 dependencies: Map.put(base, :load_permissions, load_permissions)
               )
    end
  end

  test "an empty permission list reloads current authority without a permission gate" do
    current_user = %{id: @user_id, status: :active, role: :operator}

    assert {:ok, %{user: ^current_user, permissions: permissions}} =
             CurrentUserAuthority.authorize(%{id: @user_id}, [],
               dependencies: %{
                 load_user: fn @user_id -> {:ok, current_user} end,
                 load_permissions: fn ^current_user -> {:ok, MapSet.new(["analytics.view"])} end
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
                   load_permissions: fn _ ->
                     flunk("invalid requests must not load permissions")
                   end
                 }
               )
    end

    refute_authorized.("")
    refute_authorized.([@permission, nil])
  end
end
