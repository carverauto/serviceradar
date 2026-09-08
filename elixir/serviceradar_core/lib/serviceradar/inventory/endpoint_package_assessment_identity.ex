defmodule ServiceRadar.Inventory.EndpointPackageAssessmentIdentity do
  @moduledoc """
  Derives the version-independent identity used by endpoint vulnerability assessments.

  The tuple is deliberately independent of installed versions, PURLs, CPEs, and
  advisory evidence. Each component has an explicit nil/value marker and a
  length prefix, so missing and blank values cannot collide.
  """

  @domain "serviceradar.endpoint-package-identity.v1"
  @prefix "pkgid:v1:"

  @fields [
    :source_scope,
    :package_type,
    :package_manager,
    :namespace,
    :release,
    :ecosystem,
    :binary_package,
    :source_package,
    :architecture
  ]

  @spec key(map()) :: String.t()
  def key(package) when is_map(package) do
    fields = normalized_fields(package)

    digest =
      :sha256
      |> :crypto.hash([@domain, <<0>>, Enum.map(@fields, &encode(Map.fetch!(fields, &1)))])
      |> Base.url_encode64(padding: false)

    @prefix <> digest
  end

  def key(_package), do: raise(ArgumentError, "package identity must be a map")

  @doc false
  @spec normalized_fields(map()) :: map()
  def normalized_fields(package) when is_map(package) do
    binary_package = normalized_value(value(package, :binary_package))

    %{
      source_scope: normalize_default(value(package, :source_scope), "host"),
      package_type: normalized_value(value(package, :package_type)),
      package_manager: normalized_value(value(package, :package_manager)),
      namespace: normalized_value(value(package, :namespace)),
      release: normalized_value(value(package, :release)),
      ecosystem: normalized_value(value(package, :ecosystem)),
      binary_package: binary_package,
      source_package: normalize_default(value(package, :source_package), binary_package),
      architecture: normalized_value(value(package, :architecture))
    }
  end

  defp normalize_default(nil, default), do: default
  defp normalize_default(value, _default), do: normalized_value(value)

  defp normalized_value(nil), do: nil

  defp normalized_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalized_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalized_value()

  defp normalized_value(value), do: value |> to_string() |> normalized_value()

  defp encode(nil), do: <<0>>
  defp encode(value) when is_binary(value), do: [<<1, byte_size(value)::unsigned-big-32>>, value]

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
