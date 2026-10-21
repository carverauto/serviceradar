defmodule ServiceRadarWebNG.Plugins.GrantCeiling do
  @moduledoc """
  Compares the grant a plugin package requests with a grant already approved
  for that plugin, field by field.

  Both grants have the shape `ServiceRadar.Edge.AgentConfigGenerator.package_grant/1`
  returns. A request is within the ceiling when it widens nothing: every
  capability, allowed domain, allowed network and allowed port it asks for is
  already approved, and no resource request is higher.

  Coverage is literal. A request for `api.example.com` under an approved `*` or
  `*.example.com`, or for `192.0.2.0/25` under an approved `192.0.2.0/24`, is
  reported as widened: the comparison never infers that one entry contains
  another, so it can only err towards asking a human.

  The result is a list of string-keyed maps, stored as is (jsonb) for review:

    * list fields (`capabilities`, `allowed_domains`, `allowed_networks`,
      `allowed_ports`): `"field"`, `"requested"`, `"approved"` and `"added"`.
    * resource fields: `"field"`, `"requested"` and `"approved"`.
  """

  @resource_keys [:requested_memory_mb, :requested_cpu_ms, :max_open_connections]

  @doc "Every field in which `requested` exceeds `approved`; `[]` when it is within it."
  @spec widenings(map(), map()) :: [map()]
  def widenings(requested, approved) when is_map(requested) and is_map(approved) do
    requested_permissions = Map.get(requested, :permissions, %{})
    approved_permissions = Map.get(approved, :permissions, %{})

    [
      list_widening(
        "capabilities",
        strings(Map.get(requested, :capabilities)),
        strings(Map.get(approved, :capabilities))
      ),
      list_widening(
        "allowed_domains",
        domains(Map.get(requested_permissions, :allowed_domains)),
        domains(Map.get(approved_permissions, :allowed_domains))
      ),
      list_widening(
        "allowed_networks",
        strings(Map.get(requested_permissions, :allowed_networks)),
        strings(Map.get(approved_permissions, :allowed_networks))
      ),
      port_widening(
        ports(Map.get(requested_permissions, :allowed_ports)),
        ports(Map.get(approved_permissions, :allowed_ports))
      )
    ]
    |> Enum.concat(resource_widenings(Map.get(requested, :resources, %{}), Map.get(approved, :resources, %{})))
    |> Enum.reject(&is_nil/1)
  end

  defp list_widening(field, requested, approved) do
    case requested -- approved do
      [] -> nil
      added -> %{"field" => field, "requested" => requested, "approved" => approved, "added" => added}
    end
  end

  # An empty port list is not "no ports": the agent lets a plugin's raw TCP
  # connections reach any port when the list is empty, while its HTTP requests
  # reach none. Moving between empty and non-empty therefore widens one of the
  # two whichever way it goes, so only equal emptiness can be within the grant.
  defp port_widening([], []), do: nil

  defp port_widening([], approved) do
    %{"field" => "allowed_ports", "requested" => [], "approved" => approved, "added" => []}
  end

  defp port_widening(requested, []) do
    %{"field" => "allowed_ports", "requested" => requested, "approved" => [], "added" => requested}
  end

  defp port_widening(requested, approved), do: list_widening("allowed_ports", requested, approved)

  defp resource_widenings(requested, approved) do
    Enum.map(@resource_keys, fn key ->
      requested_value = Map.get(requested, key)
      approved_value = Map.get(approved, key)

      if resource_within?(requested_value, approved_value) do
        nil
      else
        %{"field" => Atom.to_string(key), "requested" => requested_value, "approved" => approved_value}
      end
    end)
  end

  # Absent and zero name no amount: the agent falls back to a runtime default
  # for them, which a request cannot be shown to stay under. They are within the
  # grant only when the approved grant has the same value; only two positive
  # amounts compare.
  defp resource_within?(same, same), do: true

  defp resource_within?(requested, approved)
       when is_integer(requested) and is_integer(approved) and requested > 0 and approved > 0, do: requested <= approved

  defp resource_within?(_requested, _approved), do: false

  defp strings(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp strings(_list), do: []

  # The agent matches hosts case-insensitively.
  defp domains(list), do: list |> strings() |> Enum.map(&String.downcase/1) |> Enum.uniq()

  defp ports(list) when is_list(list) do
    list
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ports(_list), do: []
end
