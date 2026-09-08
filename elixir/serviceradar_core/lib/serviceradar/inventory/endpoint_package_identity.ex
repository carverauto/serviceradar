defmodule ServiceRadar.Inventory.EndpointPackageIdentity do
  @moduledoc false

  alias ServiceRadar.Inventory.PackageUrl

  @spec from_package(map(), map() | nil) :: map()
  def from_package(package, os) when is_map(package) do
    case package_url(package) do
      {:ok, components, authority} -> from_components(components, package, os, authority)
      :error -> reconcile(manager_only(package), os)
    end
  end

  def from_package(_package, _os), do: manager_only(%{})

  @spec reconcile(map(), map() | nil) :: map()
  def reconcile(identity, os) when is_map(identity) do
    existing_conflicts =
      identity
      |> value(:conflicts)
      |> List.wrap()

    reconciled_conflicts =
      identity
      |> identity_conflicts(os)
      |> Kernel.++(existing_conflicts)
      |> Enum.uniq()
      |> Enum.sort_by(&conflict_sort_key/1)

    identity
    |> Map.delete("conflicts")
    |> Map.put(:conflicts, reconciled_conflicts)
  end

  def reconcile(identity, _os), do: identity

  defp package_url(package) do
    Enum.find_value([value(package, :purl), value(package, :purl_canonical)], :error, fn
      purl when is_binary(purl) ->
        case PackageUrl.parse(purl) do
          {:ok, components} -> {:ok, components, purl_authority(components)}
          :error -> nil
        end

      _ ->
        nil
    end)
  end

  defp from_components(components, package, os, authority) do
    namespace = List.first(components.namespace)
    release = Map.get(components.qualifiers, "distro")
    source_qualifier = nonblank_qualifier(components.qualifiers, "source")
    source_version_qualifier = nonblank_qualifier(components.qualifiers, "sourceversion")
    binary_package = components.name || value(package, :name)

    source_version =
      cond do
        source_version_qualifier -> source_version_qualifier
        source_qualifier && not same_token?(source_qualifier, binary_package) -> nil
        true -> components.version
      end

    reconcile(
      %{
        package_type: components.type,
        namespace: namespace,
        release: release,
        binary_package: binary_package,
        installed_version: components.version || value(package, :version),
        source_package: source_qualifier || binary_package,
        source_version: source_version,
        source_package_explicit: not is_nil(source_qualifier),
        architecture: Map.get(components.qualifiers, "arch") || value(package, :architecture),
        version_scheme: version_scheme(components.type),
        authority: authority,
        conflicts: []
      },
      os
    )
  end

  defp manager_only(package) do
    %{
      package_type: manager_type(value(package, :package_manager) || value(package, :manager)),
      namespace: nil,
      release: nil,
      binary_package: value(package, :name),
      installed_version: value(package, :version),
      source_package: value(package, :name),
      source_version: value(package, :version),
      source_package_explicit: false,
      architecture: value(package, :architecture),
      version_scheme:
        manager_version_scheme(value(package, :package_manager) || value(package, :manager)),
      authority: :manager_only,
      conflicts: []
    }
  end

  defp purl_authority(%{type: "deb", namespace: [namespace | _], qualifiers: qualifiers})
       when namespace in ["ubuntu", "debian"] do
    if Map.has_key?(qualifiers, "distro"), do: :qualified_purl, else: :purl
  end

  defp purl_authority(_components), do: :purl

  defp nonblank_qualifier(qualifiers, key) do
    case Map.get(qualifiers, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      _missing ->
        nil
    end
  end

  defp same_token?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(String.trim(left)) == String.downcase(String.trim(right))

  defp same_token?(_left, _right), do: false

  defp identity_conflicts(identity, os) do
    namespace_conflicts =
      os
      |> evidence_values([:namespace, :id, :provider])
      |> Enum.flat_map(&conflict(value(identity, :namespace), &1, :namespace))

    release_conflicts =
      os
      |> evidence_values([:release, :version_id, :version_codename])
      |> Enum.flat_map(&conflict(value(identity, :release), &1, :release))

    namespace_conflicts ++ release_conflicts
  end

  defp conflict(nil, _os_value, _field), do: []
  defp conflict(_package_value, nil, _field), do: []

  defp conflict(package_value, os_value, :release) do
    package_value = normalize_token(package_value)
    os_value = normalize_token(os_value)
    vocabulary = release_vocabulary(package_value)

    if package_value == os_value or vocabulary == :unsupported or
         vocabulary != release_vocabulary(os_value) do
      []
    else
      [%{field: :release, package: package_value, os: os_value}]
    end
  end

  defp conflict(package_value, os_value, field) do
    if normalize_token(package_value) == os_value do
      []
    else
      [%{field: field, package: normalize_token(package_value), os: os_value}]
    end
  end

  defp evidence_values(os, keys) when is_map(os) do
    keys
    |> Enum.flat_map(fn key -> [Map.get(os, key), Map.get(os, Atom.to_string(key))] end)
    |> Enum.map(&normalize_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp evidence_values(_os, _keys), do: []

  defp conflict_sort_key(conflict) do
    field = Map.get(conflict, :field) || Map.get(conflict, "field")
    os = Map.get(conflict, :os) || Map.get(conflict, "os")
    {field_rank(field), os, inspect(conflict)}
  end

  defp field_rank(:namespace), do: 0
  defp field_rank("namespace"), do: 0
  defp field_rank(:release), do: 1
  defp field_rank("release"), do: 1
  defp field_rank(_field), do: 2

  defp version_scheme("deb"), do: "deb"
  defp version_scheme(_type), do: nil

  defp manager_type("dpkg"), do: "deb"
  defp manager_type(manager), do: normalize_token(manager)

  defp manager_version_scheme("dpkg"), do: "deb"
  defp manager_version_scheme(_manager), do: nil

  defp release_vocabulary(value) when is_binary(value) do
    cond do
      Regex.match?(~r/\A\d+(?:\.\d+)*\z/, value) -> :numeric
      Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, value) -> :codename
      true -> :unsupported
    end
  end

  defp release_vocabulary(_value), do: :unsupported

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil

  defp normalize_token(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value == "", do: nil, else: value
  end

  defp normalize_token(_value), do: nil
end
