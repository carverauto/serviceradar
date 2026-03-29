defmodule ServiceRadarWebNG.AdminApi.PathTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.AdminApi.Path

  test "encodes attacker-controlled path segments as a single segment" do
    assert Path.admin_path(["users", "123/../../../internal/secrets?token=hunter2"]) ==
             "/api/admin/users/123%2F..%2F..%2F..%2Finternal%2Fsecrets%3Ftoken%3Dhunter2"
  end
end
