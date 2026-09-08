defmodule ServiceRadar.Edge.AgentReleaseArtifactPolicy do
  @moduledoc """
  Deployment-policy checks for agent release artifacts.

  Artifacts without explicit capabilities remain compatible with the base agent
  release flow. Artifacts that declare optional remote-access/RDP capabilities
  are selectable only when the deployment has enabled that feature.
  """

  @rdp_capabilities MapSet.new(["remote_access.rdp", "remote_access.desktop"])

  @spec enabled?(map()) :: boolean()
  def enabled?(artifact) when is_map(artifact) do
    if rdp_artifact?(artifact) do
      remote_access_desktop_rdp_enabled?()
    else
      true
    end
  end

  def enabled?(_artifact), do: false

  @spec capabilities(map()) :: [String.t()]
  def capabilities(artifact) when is_map(artifact) do
    artifact
    |> map_get_any([:capabilities, "capabilities"], [])
    |> List.wrap()
    |> Enum.map(&normalize_capability/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def capabilities(_artifact), do: []

  @spec rdp_artifact?(map()) :: boolean()
  def rdp_artifact?(artifact) when is_map(artifact) do
    artifact
    |> capabilities()
    |> Enum.any?(&MapSet.member?(@rdp_capabilities, &1))
  end

  def rdp_artifact?(_artifact), do: false

  defp remote_access_desktop_rdp_enabled? do
    Application.get_env(:serviceradar_core, :remote_access_desktop_rdp_enabled, false) == true
  end

  defp normalize_capability(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_capability(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_capability(_value), do: nil

  defp map_get_any(map, keys, default) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end
end
