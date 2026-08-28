defmodule ServiceRadar.Dashboards.Checks.SubjectGrantTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Dashboards.Checks.SubjectGrant

  @moduletag :unit
  @moduletag :db_free

  test "user grants match the named actor" do
    actor_id = "11111111-1111-1111-1111-111111111111"
    grant = %{subject_type: :user, subject_user_id: actor_id}

    assert SubjectGrant.matches_actor?(grant, actor_id)
    refute SubjectGrant.matches_actor?(grant, "22222222-2222-2222-2222-222222222222")
  end

  test "group grants match through memberships" do
    actor_id = "11111111-1111-1111-1111-111111111111"

    grant = %{
      subject_type: :group,
      subject_group: %{memberships: [%{user_id: actor_id}]}
    }

    assert SubjectGrant.matches_actor?(grant, actor_id)

    refute SubjectGrant.matches_actor?(
             %{subject_type: :group, subject_group: %{memberships: []}},
             actor_id
           )
  end
end
