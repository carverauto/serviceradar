defmodule ServiceRadar.Inventory.EndpointNvdFacts do
  @moduledoc """
  Builds conservative, database-free facts for NVD expression evaluation.

  OS authority comes from explicit `:os` / `"os"` or normalized
  `:os_evidence` / `"os_evidence"` maps, or from a conflict-free qualified
  distro PURL projected through `EndpointPackageIdentity`. Unqualified PURLs
  and package-manager-only identities are not sufficient OS evidence.

  Inventory completeness and optional `*_cpes` lists are accepted through the
  context passed to `build/3`. Application completeness may also be derived
  from `coverage_state == "complete"`; every other missing completeness signal
  defaults to false.
  """

  alias ServiceRadar.Inventory.AdvisoryFeeds.Cpe
  alias ServiceRadar.Inventory.EndpointPackageIdentity

  @spec build(map() | nil, [map()]) :: map()
  def build(current_package, current_packages) do
    build(current_package, current_packages, %{})
  end

  @spec build(map() | nil, [map()], map()) :: map()
  def build(current_package, current_packages, context)
      when is_list(current_packages) and is_map(context) do
    %{
      "current_application_cpes" => package_cpes(current_package),
      "application_cpes" =>
        Enum.flat_map(current_packages, &package_cpes/1) ++
          context_cpes(context, :application_cpes),
      "application_inventory_complete" => application_complete?(current_package, context),
      "os" => os_fact(current_package, context),
      "os_cpes" => context_cpes(context, :os_cpes),
      "hardware_cpes" => context_cpes(context, :hardware_cpes),
      "hardware_inventory_complete" => explicit_boolean(context, :hardware_inventory_complete),
      "runtime_cpes" => context_cpes(context, :runtime_cpes),
      "runtime_inventory_complete" => explicit_boolean(context, :runtime_inventory_complete)
    }
  end

  def build(current_package, _current_packages, context) when is_map(context),
    do: build(current_package, [], context)

  def build(current_package, current_packages, _context),
    do: build(current_package, current_packages, %{})

  defp package_cpes(package) when is_map(package) do
    package_version = value(package, :version)

    package
    |> value(:cpes, [])
    |> List.wrap()
    |> parse_cpes()
    |> Enum.filter(&(&1.part == "a"))
    |> Enum.map(&with_authoritative_package_version(&1, package_version))
  end

  defp package_cpes(_package), do: []

  defp with_authoritative_package_version(cpe, version)
       when is_binary(version) and version != "" and version != "*" do
    Map.put(cpe, :version, version)
  end

  defp with_authoritative_package_version(cpe, _version), do: cpe

  defp context_cpes(context, key) do
    context
    |> value(key, [])
    |> List.wrap()
    |> parse_cpes()
  end

  defp parse_cpes(cpes) do
    Enum.flat_map(cpes, fn
      cpe when is_binary(cpe) ->
        case Cpe.parse(cpe) do
          {:ok, components} -> [components]
          :error -> []
        end

      components when is_map(components) ->
        [components]

      _other ->
        []
    end)
  end

  defp application_complete?(current_package, context) do
    explicit =
      first_present([
        fetch_value(context, :application_inventory_complete),
        fetch_value(current_package, :application_inventory_complete)
      ])

    case explicit do
      value when is_boolean(value) ->
        value

      _missing_or_invalid ->
        first_present([
          fetch_value(context, :coverage_state),
          fetch_value(current_package, :coverage_state)
        ]) == "complete"
    end
  end

  defp explicit_boolean(context, key) do
    case fetch_value(context, key) do
      value when is_boolean(value) -> value
      _missing_or_invalid -> false
    end
  end

  defp os_fact(package, context) when is_map(package) do
    os_evidence =
      first_present([
        fetch_value(context, :os_evidence),
        fetch_value(context, :os),
        fetch_value(package, :os_evidence),
        fetch_value(package, :os)
      ])

    identity =
      case fetch_value(package, :package_identity) do
        projected when is_map(projected) -> projected
        _missing -> EndpointPackageIdentity.from_package(package, os_evidence)
      end

    identity = EndpointPackageIdentity.reconcile(identity, os_evidence)

    case value(identity, :conflicts) do
      [] -> explicit_os_fact(os_evidence) || qualified_identity_os_fact(identity)
      _conflicting -> nil
    end
  end

  defp os_fact(_package, _context), do: nil

  defp explicit_os_fact(os_evidence) when is_map(os_evidence) do
    with namespace when is_binary(namespace) <- os_namespace(os_evidence),
         [_ | _] = releases <- os_releases(os_evidence) do
      %{"namespace" => namespace, "release" => hd(releases), "releases" => releases}
    else
      _insufficient -> nil
    end
  end

  defp explicit_os_fact(_os_evidence), do: nil

  defp qualified_identity_os_fact(identity) do
    with authority when authority in [:qualified_purl, "qualified_purl"] <-
           value(identity, :authority),
         namespace when is_binary(namespace) <- normalize_token(value(identity, :namespace)),
         release when is_binary(release) <- normalize_token(value(identity, :release)) do
      %{"namespace" => namespace, "release" => release, "releases" => [release]}
    else
      _insufficient -> nil
    end
  end

  defp os_namespace(os) do
    os
    |> first_value([:namespace, :id, :provider])
    |> normalize_token()
  end

  defp os_releases(os) do
    [:release, :version_id, :version_codename]
    |> Enum.map(&fetch_value(os, &1))
    |> Enum.map(&normalize_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp first_value(map, keys) do
    keys
    |> Enum.map(&fetch_value(map, &1))
    |> first_present()
  end

  defp first_present(values), do: Enum.find(values, &(&1 not in [nil, ""]))

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_value(_map, _key), do: nil

  defp value(map, key, default \\ nil) do
    case fetch_value(map, key) do
      nil -> default
      found -> found
    end
  end

  defp normalize_token(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_token(_value), do: nil
end
