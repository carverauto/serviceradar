defmodule ServiceRadarWebNG.AgentCapabilities do
  @moduledoc """
  Normalizes capability advertisements for compact operator-facing views.

  Agents advertise both usable capabilities and negative availability markers.
  Keeping those groups separate prevents status markers such as
  `host-network-visibility.dpi.unavailable` from looking like enabled features.
  """

  @unavailable_suffix ".unavailable"

  @type summary :: %{
          available: [String.t()],
          unavailable: [String.t()],
          total: non_neg_integer()
        }

  @spec summarize(term()) :: summary()
  def summarize(capabilities) do
    capabilities = normalize(capabilities)
    {unavailable, available} = Enum.split_with(capabilities, &unavailable?/1)

    %{
      available: available,
      unavailable: unavailable,
      total: length(capabilities)
    }
  end

  @spec unavailable?(term()) :: boolean()
  def unavailable?(capability) when is_binary(capability) do
    capability
    |> String.downcase()
    |> String.ends_with?(@unavailable_suffix)
  end

  def unavailable?(_capability), do: false

  defp normalize(capabilities) do
    capabilities
    |> List.wrap()
    |> Enum.map(&normalize_capability/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_capability(nil), do: nil

  defp normalize_capability(capability) when is_atom(capability),
    do: capability |> Atom.to_string() |> normalize_capability()

  defp normalize_capability(capability) when is_binary(capability) do
    case String.trim(capability) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_capability(_capability), do: nil
end
