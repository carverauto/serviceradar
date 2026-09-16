defmodule ServiceRadarWebNGWeb.Api.AnsibleRepositorySpecTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.OpenAPI.AdminSpec

  @moduletag :db_free

  test "published document includes lifecycle, pagination, sync, and concurrency schemas" do
    spec = AdminSpec.document()
    paths = spec["paths"]
    item = paths["/api/admin/ansible-repositories/{id}"]

    assert item["get"]["responses"]["200"]["headers"]["ETag"]
    assert item["delete"]["responses"]["204"]
    assert Enum.any?(item["patch"]["parameters"], &(&1["name"] == "If-Match" and &1["required"]))
    assert paths["/api/admin/ansible-repositories/{id}/sync"]["post"]["responses"]["202"]

    schemas = spec["components"]["schemas"]
    assert schemas["AnsibleRepositoryPage"]["properties"]["next_cursor"]["nullable"]
    assert schemas["AnsibleRepositoryCreate"]["required"] == ["name", "git_url"]
    refute schemas["AnsibleRepositoryUpdate"]["additionalProperties"]
    refute Map.has_key?(schemas["AnsibleRepository"]["properties"], "parse_diagnostics")
    refute Map.has_key?(schemas["AnsibleRepository"]["properties"], "metadata")
  end
end
