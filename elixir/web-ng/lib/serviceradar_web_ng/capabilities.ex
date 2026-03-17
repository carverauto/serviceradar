defmodule ServiceRadarWebNG.Capabilities do
  @moduledoc """
  Deployment-supplied runtime capabilities for tenant-facing product surfaces.

  Capabilities are intentionally generic and preserve current OSS behavior when
  no capability set is supplied by the deployment environment.
  """

  @config_key :runtime_capabilities

  @known_capabilities [
    :collectors_enabled,
    :leaf_nodes_enabled,
    :device_limit_enforcement_enabled
  ]

  @type capability ::
          :collectors_enabled | :leaf_nodes_enabled | :device_limit_enforcement_enabled

  @type config :: %{
          configured?: boolean(),
          enabled: MapSet.t(capability())
        }

  @spec enabled?(capability() | String.t()) :: boolean()
  def enabled?(capability) when is_binary(capability) do
    case normalize_capability(capability) do
      nil -> false
      normalized -> enabled?(normalized)
    end
  end

  def enabled?(capability) when capability in @known_capabilities do
    case config() do
      %{configured?: false} -> true
      %{enabled: enabled} -> MapSet.member?(enabled, capability)
    end
  end

  @spec collectors_enabled?() :: boolean()
  def collectors_enabled?, do: enabled?(:collectors_enabled)

  @spec config() :: config()
  def config do
    :serviceradar_web_ng
    |> Application.get_env(@config_key, [])
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    enabled =
      config
      |> Map.get(:enabled, Map.get(config, "enabled", []))
      |> normalize_capability_list()

    configured? =
      config
      |> Map.get(:configured?, Map.get(config, "configured?", false))
      |> Kernel.==(true)

    %{configured?: configured?, enabled: enabled}
  end

  defp normalize_config(config) when is_list(config) do
    enabled_source =
      if Keyword.keyword?(config) do
        Keyword.get(config, :enabled, [])
      else
        config
      end

    enabled = normalize_capability_list(enabled_source)

    configured? =
      if Keyword.keyword?(config) do
        case Keyword.fetch(config, :configured?) do
          {:ok, value} -> value == true
          :error -> config != []
        end
      else
        config != []
      end

    %{configured?: configured?, enabled: enabled}
  end

  defp normalize_config(_), do: %{configured?: false, enabled: MapSet.new()}

  defp normalize_capability_list(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(&normalize_capability/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp normalize_capability_list(_), do: MapSet.new()

  defp normalize_capability(capability) when capability in @known_capabilities, do: capability

  defp normalize_capability(capability) when is_binary(capability) do
    capability
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  else
    atom when atom in @known_capabilities -> atom
    _ -> nil
  end

  defp normalize_capability(_), do: nil
end
