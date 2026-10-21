defmodule ServiceRadarWebNG.Plugins.GrantCeilingTest do
  @moduledoc """
  The boundary cases of the requested-versus-approved grant comparison that
  first-party auto-approval relies on. Each is a request that looks no wider
  than the approved grant but reaches something the grant does not, so a
  regression here would approve a privilege expansion without review. The
  ordinary per-field widenings are covered end to end by the first-party sync
  tests in `ServiceRadarWebNG.Plugins.PackagesTest`.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.GrantCeiling

  @moduletag :db_free

  @approved %{
    capabilities: ["get_config", "submit_result"],
    permissions: %{
      allowed_domains: ["api.example.com"],
      allowed_networks: ["192.0.2.0/24"],
      allowed_ports: [443]
    },
    resources: %{requested_memory_mb: 64, requested_cpu_ms: 1000, max_open_connections: 4}
  }

  test "an identical or narrower request widens nothing" do
    assert GrantCeiling.widenings(@approved, @approved) == []

    narrower = %{
      capabilities: ["get_config"],
      permissions: %{allowed_domains: ["API.example.com"], allowed_networks: [], allowed_ports: [443]},
      resources: %{requested_memory_mb: 32, requested_cpu_ms: 500, max_open_connections: 2}
    }

    assert GrantCeiling.widenings(narrower, @approved) == []
  end

  # {case, request changes, approved-grant changes, field reported widened}
  for {name, request, approval, field} <- [
        {"dropping every port lets raw TCP reach any port", %{allowed_ports: []}, %{}, "allowed_ports"},
        {"declaring ports where none were approved opens HTTP ports", %{}, %{allowed_ports: []}, "allowed_ports"},
        {"a wildcard domain is not covered by a literal one", %{allowed_domains: ["*"]}, %{}, "allowed_domains"},
        {"zero open connections falls back to the runtime default", %{max_open_connections: 0}, %{},
         "max_open_connections"},
        {"omitting a resource falls back to the runtime default", %{max_open_connections: nil}, %{},
         "max_open_connections"}
      ] do
    test "#{name} is reported as widened" do
      requested = change_grant(@approved, unquote(Macro.escape(request)))
      approved = change_grant(@approved, unquote(Macro.escape(approval)))

      assert [%{"field" => unquote(field)}] = GrantCeiling.widenings(requested, approved)
    end
  end

  # Applies field changes to a grant, routing each key to its section.
  defp change_grant(grant, changes) do
    Enum.reduce(changes, grant, fn {key, value}, acc ->
      section = if Map.has_key?(acc.permissions, key), do: :permissions, else: :resources
      put_in(acc, [section, key], value)
    end)
  end
end
