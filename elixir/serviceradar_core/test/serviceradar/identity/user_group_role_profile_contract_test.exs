defmodule ServiceRadar.Identity.UserGroupRoleProfileContractTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.UserGroup

  @moduletag :db_free

  test "user groups expose one optional role profile" do
    assert Info.attribute(UserGroup, :role_profile_id).allow_nil?
    assert Info.relationship(UserGroup, :role_profile).destination == RoleProfile
  end

  test "migration uses a restrictive role-profile foreign key" do
    pattern =
      Path.expand("../../../priv/repo/migrations/*_add_role_profile_to_user_groups.exs", __DIR__)

    assert [path] = Path.wildcard(pattern)
    sql = File.read!(path)
    assert sql =~ "references(:role_profiles"
    assert sql =~ "on_delete: :restrict"
    assert sql =~ "create index(:user_groups, [:role_profile_id]"
  end
end
