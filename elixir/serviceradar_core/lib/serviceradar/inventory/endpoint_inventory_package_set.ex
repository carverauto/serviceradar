defmodule ServiceRadar.Inventory.EndpointInventoryPackageSet do
  @moduledoc false

  alias ServiceRadar.Inventory.EndpointInventoryPayload, as: Payload
  alias ServiceRadar.Inventory.PackageUrl

  @hash_algorithm_version 1
  @upload_reason_changed "changed"
  @upload_reason_unchanged "unchanged"
  @package_event_added "added"
  @package_event_removed "removed"
  @package_event_version_changed "version_changed"
  @coverage_states ~w(complete partial not_scanned failed disabled unchanged unknown no_supported_package_source)
  @diagnostic_complete_states ~w(scanned complete success)
  @diagnostic_failure_states ~w(error failed timeout)
  @diagnostic_unavailable_states ~w(unavailable skipped not_supported unsupported)
  @package_manager_purl_types %{
    "apk" => "apk",
    "dpkg" => "deb",
    "rpm" => "rpm"
  }
  @package_manager_namespaces %{
    "apk" => "alpine",
    "deb" => "debian",
    "dpkg" => "debian",
    "rpm" => "rpm"
  }
  @known_cpe_products %{
    "curl" => [{"haxx", "curl"}],
    "libcurl" => [{"haxx", "curl"}],
    "libcurl4" => [{"haxx", "curl"}],
    "libssl" => [{"openssl", "openssl"}],
    "libssl1.1" => [{"openssl", "openssl"}],
    "libssl3" => [{"openssl", "openssl"}],
    "nginx" => [{"nginx", "nginx"}],
    "openssl" => [{"openssl", "openssl"}],
    "openssh" => [{"openbsd", "openssh"}],
    "openssh-client" => [{"openbsd", "openssh"}],
    "openssh-server" => [{"openbsd", "openssh"}],
    "postgresql" => [{"postgresql", "postgresql"}],
    "postgresql-client" => [{"postgresql", "postgresql"}]
  }

  def normalize_packages(payload) do
    payload_packages =
      payload
      |> Payload.list_value(:packages)
      |> Enum.map(&normalize_package/1)

    packages =
      if payload_packages == [] do
        payload
        |> Payload.map_value(:sbom)
        |> Payload.list_value(:components)
        |> Enum.map(&normalize_component/1)
      else
        payload_packages
      end

    packages
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn package ->
      package.purl_canonical ||
        {package.package_manager, package.name, package.version, package.architecture}
    end)
  end

  @doc """
  Normalizes the package list carried in a delta wire payload (the `added`,
  `removed`, and `changed` arrays). Each entry has the same shape as a full-set
  package, so they reuse `normalize_package/1`.
  """
  def normalize_delta_packages(entries) when is_list(entries) do
    entries
    |> Enum.map(&normalize_package/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_delta_packages(_entries), do: []

  @doc """
  Applies a normalized delta (added/removed/changed lists of normalized
  packages) to the current package set and returns the reconstructed target set.

  Packages are aligned by `identity_key/1` (manager+name+arch+ecosystem), which
  is version independent, so a `changed` entry replaces the prior coordinate and
  an `added` entry whose coordinate already exists also replaces it (idempotent).
  The caller MUST verify the reconstructed set's `server_package_set_hash/1`
  matches the delta's declared target hash before trusting it; this function does
  not validate hashes itself.
  """
  def apply_delta(current_packages, %{added: added, removed: removed, changed: changed}) do
    indexed = Map.new(current_packages, &{identity_key(&1), &1})

    removed_keys = MapSet.new(removed, &identity_key/1)

    indexed
    |> Map.reject(fn {key, _package} -> MapSet.member?(removed_keys, key) end)
    |> apply_delta_upserts(changed)
    |> apply_delta_upserts(added)
    |> Map.values()
    |> Enum.uniq_by(fn package ->
      package.purl_canonical ||
        {package.package_manager, package.name, package.version, package.architecture}
    end)
  end

  defp apply_delta_upserts(indexed, packages) do
    Enum.reduce(packages, indexed, fn package, acc ->
      Map.put(acc, identity_key(package), package)
    end)
  end

  def normalize_diagnostics(diagnostics) do
    diagnostics
    |> Enum.map(fn
      diagnostic when is_map(diagnostic) ->
        name = diagnostic_string(diagnostic, [:name, :id, :plugin_id, :plugin, :source_id])

        Payload.compact_map(%{
          "name" => name,
          "type" => diagnostic_string(diagnostic, [:type, :kind, :category, :plugin_type]),
          "state" => normalize_diagnostic_state(diagnostic_string(diagnostic, [:state, :status])),
          "package_count" =>
            diagnostic_integer(diagnostic, [:package_count, :packageCount, :packages, :count]),
          "finding_count" =>
            diagnostic_integer(diagnostic, [
              :finding_count,
              :findingCount,
              :findings_count,
              :findings
            ]),
          "reason" => diagnostic_string(diagnostic, [:reason, :reason_code, :code]),
          "error" => diagnostic_string(diagnostic, [:error, :error_message, :message]),
          "path" => diagnostic_string(diagnostic, [:path, :root, :scan_root, :target_path]),
          "detected" => diagnostic_boolean(diagnostic, [:detected, :supported, :applicable]),
          "duration_ms" =>
            diagnostic_integer(diagnostic, [:duration_ms, :durationMillis, :elapsed_ms]),
          "truncated" => diagnostic_boolean(diagnostic, [:truncated, :partial]),
          "metadata" => metadata_or_nil(diagnostic)
        })

      _diagnostic ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def enabled_diagnostics(payload, diagnostics) do
    explicit = Payload.string_list_value(payload, :enabled_plugins)

    if explicit == [] do
      Enum.flat_map(diagnostics, fn diagnostic ->
        case Map.get(diagnostic, "name") do
          name when is_binary(name) and name != "" -> [name]
          _ -> []
        end
      end)
    else
      explicit
    end
  end

  defp metadata_or_nil(source) do
    case Payload.map_value(source, :metadata) do
      metadata when map_size(metadata) == 0 -> nil
      metadata -> metadata
    end
  end

  defp diagnostic_string(diagnostic, keys) do
    Enum.find_value(keys, &Payload.string_value(diagnostic, &1))
  end

  defp diagnostic_integer(diagnostic, keys) do
    Enum.find_value(keys, &Payload.integer_value(diagnostic, &1, nil))
  end

  defp diagnostic_boolean(diagnostic, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Payload.boolean_value(diagnostic, key) do
        nil -> {:cont, nil}
        value -> {:halt, value}
      end
    end)
  end

  defp normalize_diagnostic_state(nil), do: nil
  defp normalize_diagnostic_state("ok"), do: "success"
  defp normalize_diagnostic_state("succeeded"), do: "success"
  defp normalize_diagnostic_state("failure"), do: "failed"
  defp normalize_diagnostic_state(value), do: value

  def manager_counts(packages) do
    packages
    |> Enum.group_by(& &1.package_manager)
    |> Map.new(fn {manager, rows} -> {manager, length(rows)} end)
  end

  def server_package_set_hash([]), do: nil

  def server_package_set_hash(packages) do
    lines =
      packages
      |> Enum.flat_map(&package_hash_line/1)
      |> Enum.sort()

    payload = Enum.join(lines, "\n")

    :sha256
    |> :crypto.hash([<<@hash_algorithm_version>>, payload])
    |> Base.encode16(case: :lower)
  end

  def scan_state(payload) do
    case Payload.string_value(payload, :state) || Payload.string_value(payload, :status) do
      value when value in ["scanned", "scan_failed", "not_scanned", "unchanged", "partial"] ->
        value

      value when value in ["complete", "success"] ->
        "scanned"

      "failed" ->
        "scan_failed"

      _ ->
        "scanned"
    end
  end

  def coverage_state(payload, packages, diagnostics) do
    case Payload.string_value(payload, :coverage_state) do
      value when value in @coverage_states -> value
      _ -> infer_coverage_state(packages, diagnostics)
    end
  end

  defp infer_coverage_state(_packages, []), do: "unknown"

  defp infer_coverage_state(packages, diagnostics) do
    failed? = Enum.any?(diagnostics, &diagnostic_failed?/1)
    complete? = Enum.any?(diagnostics, &diagnostic_complete?/1)
    unavailable? = Enum.all?(diagnostics, &diagnostic_unavailable?/1)

    cond do
      failed? and packages == [] -> "failed"
      failed? -> "partial"
      complete? -> "complete"
      unavailable? -> "no_supported_package_source"
      true -> "unknown"
    end
  end

  defp diagnostic_complete?(diagnostic) do
    Map.get(diagnostic, "state") in @diagnostic_complete_states and
      Map.get(diagnostic, "detected") != false and
      not Map.get(diagnostic, "truncated", false)
  end

  defp diagnostic_failed?(diagnostic) do
    Map.get(diagnostic, "state") in @diagnostic_failure_states or
      present?(Map.get(diagnostic, "error")) or
      Map.get(diagnostic, "truncated", false)
  end

  defp diagnostic_unavailable?(diagnostic) do
    Map.get(diagnostic, "state") in @diagnostic_unavailable_states or
      Map.get(diagnostic, "detected") == false
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  def successful_scan_time(payload, fallback) do
    case scan_state(payload) do
      "scanned" ->
        Payload.datetime_value(payload, :last_successful_scan_at) ||
          Payload.datetime_value(payload, :last_scan_at) ||
          fallback

      "unchanged" ->
        Payload.datetime_value(payload, :last_successful_scan_at) ||
          Payload.datetime_value(payload, :last_scan_at) ||
          fallback

      "partial" ->
        nil

      _ ->
        Payload.datetime_value(payload, :last_successful_scan_at)
    end
  end

  def inferred_upload_reason(payload) do
    if map_size(Payload.map_value(payload, :sbom)) > 0 or
         Payload.list_value(payload, :packages) != [] do
      @upload_reason_changed
    else
      @upload_reason_unchanged
    end
  end

  def coordinate_key(package) do
    case Payload.trimmed(package.purl_canonical) do
      "" ->
        fallback_coordinate_key(package)

      purl_canonical ->
        "purl:#{purl_canonical}"
    end
  end

  def endpoint_package_row(package, now) do
    cpes = normalize_cpes(Map.get(package, :cpes, []))

    %{
      coordinate_key: coordinate_key(package),
      purl_canonical: package.purl_canonical,
      primary_cpe: List.first(cpes),
      cpes: cpes,
      package_manager: package.package_manager,
      name: package.name,
      version: package.version,
      architecture: package.architecture,
      ecosystem: package.ecosystem,
      source_scope: "host",
      metadata: endpoint_package_metadata(package, cpes),
      inserted_at: now,
      updated_at: now
    }
  end

  def diff_events(previous_packages, packages) do
    previous_by_key = Map.new(previous_packages, &{identity_key(&1), &1})
    current_by_key = Map.new(packages, &{identity_key(&1), &1})

    added =
      current_by_key
      |> Map.drop(Map.keys(previous_by_key))
      |> Map.values()
      |> Enum.map(&%{event_type: @package_event_added, package: &1})

    removed =
      previous_by_key
      |> Map.drop(Map.keys(current_by_key))
      |> Map.values()
      |> Enum.map(&%{event_type: @package_event_removed, previous_package: &1})

    version_changed =
      previous_by_key
      |> Map.take(Map.keys(current_by_key))
      |> Enum.flat_map(fn {key, previous_package} ->
        package = Map.fetch!(current_by_key, key)

        if version_changed?(previous_package, package) do
          [
            %{
              event_type: @package_event_version_changed,
              previous_package: previous_package,
              package: package
            }
          ]
        else
          []
        end
      end)

    added ++ removed ++ version_changed
  end

  def coordinate_hash(package) do
    package
    |> coordinate_fragment()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def event_coordinate_hash(event) do
    parts =
      [
        event.event_type,
        coordinate_fragment(Map.get(event, :previous_package)),
        coordinate_fragment(Map.get(event, :package))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(<<0>>)

    :sha256
    |> :crypto.hash(parts)
    |> Base.encode16(case: :lower)
  end

  def normalized_coordinate_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  def normalized_coordinate_value(nil), do: ""

  def normalized_coordinate_value(value),
    do: value |> to_string() |> normalized_coordinate_value()

  def normalize_cpes(cpes) do
    cpes
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_package(package) when is_map(package) do
    name = Payload.string_value(package, :name)

    package_manager =
      Payload.string_value(package, :package_manager) || Payload.string_value(package, :manager)

    if name && package_manager do
      purl_canonical = canonical_purl(package, package_manager)

      %{
        name: name,
        version: Payload.string_value(package, :version),
        architecture: Payload.string_value(package, :architecture),
        package_manager: package_manager,
        ecosystem: Payload.string_value(package, :ecosystem),
        purl: Payload.string_value(package, :purl),
        purl_canonical: purl_canonical,
        cpes:
          package
          |> Payload.string_list_value(:cpes)
          |> candidate_cpes(name, Payload.string_value(package, :version)),
        supplier: Payload.string_value(package, :supplier),
        license: Payload.string_value(package, :license),
        source: Payload.string_value(package, :source),
        evidence: Payload.map_value(package, :evidence),
        metadata: Payload.metadata(package)
      }
    end
  end

  defp normalize_package(_package), do: nil

  defp normalize_component(component) when is_map(component) do
    name = Payload.string_value(component, :name)
    properties = properties(component)
    package_manager = Map.get(properties, "serviceradar:package_manager")

    if name && package_manager do
      purl_canonical = canonical_purl(component, package_manager, properties)
      version = Payload.string_value(component, :version)

      %{
        name: name,
        version: version,
        architecture: Map.get(properties, "serviceradar:architecture"),
        package_manager: package_manager,
        ecosystem: Map.get(properties, "serviceradar:ecosystem"),
        purl: Payload.string_value(component, :purl),
        purl_canonical: purl_canonical,
        cpes:
          component
          |> component_cpes()
          |> candidate_cpes(name, version),
        supplier: supplier(component),
        license: license(component),
        source: Map.get(properties, "serviceradar:source"),
        evidence:
          Payload.compact_map(%{"component_type" => Payload.string_value(component, :type)}),
        metadata: %{"properties" => properties}
      }
    end
  end

  defp normalize_component(_component), do: nil

  defp canonical_purl(package, package_manager, properties \\ %{}) do
    attrs = %{
      package_manager: package_manager,
      ecosystem:
        Payload.string_value(package, :ecosystem) || Map.get(properties, "serviceradar:ecosystem"),
      name: Payload.string_value(package, :name),
      version: Payload.string_value(package, :version),
      architecture:
        Payload.string_value(package, :architecture) ||
          Map.get(properties, "serviceradar:architecture")
    }

    case parse_purl(Payload.string_value(package, :purl), attrs) do
      nil -> fallback_purl(attrs)
      canonical -> canonical
    end
  end

  defp parse_purl(purl, attrs) do
    case PackageUrl.parse(purl) do
      {:ok, components} ->
        type = purl_type(components.type, attrs.package_manager)
        namespace = normalize_namespace(components.namespace, type, attrs)

        qualifiers =
          components.qualifiers
          |> Map.put_new("arch", attrs.architecture)
          |> Payload.compact_map()

        build_purl(
          type,
          namespace,
          components.name,
          components.version || attrs.version,
          qualifiers,
          components.subpath
        )

      _ ->
        nil
    end
  end

  defp fallback_purl(attrs) do
    type = purl_type(attrs.ecosystem, attrs.package_manager)
    namespace = normalize_namespace([], type, attrs)
    qualifiers = Payload.compact_map(%{"arch" => attrs.architecture})

    build_purl(type, namespace, attrs.name, attrs.version, qualifiers)
  end

  defp purl_type(type, package_manager) do
    normalized = normalize_token(type) || normalize_token(package_manager)
    Map.get(@package_manager_purl_types, normalized, normalized || "generic")
  end

  defp normalize_namespace([], type, attrs) do
    namespace =
      Map.get(@package_manager_namespaces, type) ||
        Map.get(@package_manager_namespaces, normalize_token(attrs.package_manager)) ||
        normalize_token(attrs.ecosystem)

    if namespace, do: [namespace], else: []
  end

  defp normalize_namespace(segments, _type, _attrs) do
    Enum.map(segments, &String.downcase/1)
  end

  defp build_purl(type, namespace, name, version, qualifiers, subpath \\ nil)

  defp build_purl(_type, _namespace, nil, _version, _qualifiers, _subpath), do: nil

  defp build_purl(type, namespace, name, version, qualifiers, subpath) do
    PackageUrl.canonical(%{
      type: type,
      namespace: namespace,
      name: name,
      version: version,
      qualifiers: qualifiers,
      subpath: subpath
    })
  end

  defp normalize_token(nil), do: nil

  defp normalize_token(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.downcase()

    if value == "", do: nil, else: value
  end

  defp endpoint_package_metadata(package, cpes) do
    %{
      "source" => "endpoint_inventory",
      "match_input" =>
        Payload.compact_map(%{
          "scope" => "host",
          "canonical_purl" => Payload.trimmed_or_nil(package.purl_canonical),
          "candidate_cpes" => cpes,
          "fallback_tuple" =>
            Payload.compact_map(%{
              "package_manager" => Payload.trimmed_or_nil(package.package_manager),
              "name" => Payload.trimmed_or_nil(package.name),
              "version" => Payload.trimmed_or_nil(package.version),
              "architecture" => Payload.trimmed_or_nil(package.architecture)
            })
        })
    }
  end

  defp fallback_coordinate_key(package) do
    encoded =
      [
        Payload.trimmed(package.package_manager),
        Payload.trimmed(package.name),
        Payload.trimmed(package.version),
        Payload.trimmed(package.architecture)
      ]
      |> Enum.join("\u0000")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "fallback:#{encoded}"
  end

  defp identity_key(package) do
    Enum.join(
      [
        normalized_coordinate_value(package.package_manager),
        normalized_coordinate_value(package.name),
        normalized_coordinate_value(package.architecture),
        normalized_coordinate_value(package.ecosystem)
      ],
      <<0>>
    )
  end

  defp version_changed?(previous_package, package) do
    normalized_coordinate_value(previous_package.version) !=
      normalized_coordinate_value(package.version) or
      normalized_coordinate_value(previous_package.purl_canonical) !=
        normalized_coordinate_value(package.purl_canonical)
  end

  defp coordinate_fragment(nil), do: nil

  defp coordinate_fragment(package) do
    Enum.map_join(
      [
        package.package_manager,
        package.name,
        package.version,
        package.architecture,
        package.ecosystem,
        package.purl_canonical
      ],
      <<0>>,
      &normalized_coordinate_value/1
    )
  end

  defp package_hash_line(package) do
    name = Payload.trimmed(package.name)
    package_manager = Payload.trimmed(package.package_manager)

    if name == "" or package_manager == "" do
      []
    else
      [
        IO.iodata_to_binary([
          "{\"package_manager\":",
          Payload.json_string(package_manager),
          ",\"name\":",
          Payload.json_string(name),
          ",\"version\":",
          Payload.json_string(Payload.trimmed(package.version)),
          ",\"architecture\":",
          Payload.json_string(Payload.trimmed(package.architecture)),
          ",\"purl_canonical\":",
          Payload.json_string(Payload.trimmed(package.purl_canonical)),
          "}"
        ])
      ]
    end
  end

  defp properties(map) do
    map
    |> Payload.list_value(:properties)
    |> Map.new(fn
      %{"name" => name, "value" => value} -> {name, value}
      %{name: name, value: value} -> {name, value}
      _ -> {nil, nil}
    end)
    |> Map.delete(nil)
  end

  defp component_cpes(component) do
    cpes = Payload.string_list_value(component, :cpes)

    case Payload.string_value(component, :cpe) do
      nil -> cpes
      cpe -> Enum.uniq([cpe | cpes])
    end
  end

  defp candidate_cpes(cpes, name, version) do
    supplied = normalize_cpes(cpes)

    derived =
      name
      |> known_cpe_products()
      |> Enum.map(fn {vendor, product} ->
        build_cpe23(vendor, product, version)
      end)

    normalize_cpes(supplied ++ derived)
  end

  defp known_cpe_products(name) do
    normalized = normalize_token(name)

    Map.get(@known_cpe_products, normalized, [])
  end

  defp build_cpe23(vendor, product, version) do
    "cpe:2.3:a:#{cpe23_part(vendor)}:#{cpe23_part(product)}:#{cpe23_part(version || "*")}:*:*:*:*:*:*:*"
  end

  defp cpe23_part(nil), do: "*"

  defp cpe23_part(value) do
    case value |> to_string() |> String.trim() do
      "" ->
        "*"

      part ->
        part
        |> String.downcase()
        |> String.replace("\\", "\\\\")
        |> String.replace(":", "\\:")
        |> String.replace("*", "\\*")
        |> String.replace("?", "\\?")
    end
  end

  defp supplier(component) do
    case Payload.map_value(component, :supplier) do
      supplier when map_size(supplier) > 0 -> Payload.string_value(supplier, :name)
      _ -> Payload.string_value(component, :supplier)
    end
  end

  defp license(component) do
    component
    |> Payload.list_value(:licenses)
    |> Enum.find_value(fn
      %{"license" => %{"id" => id}} -> id
      %{"license" => %{"name" => name}} -> name
      %{license: %{id: id}} -> id
      %{license: %{name: name}} -> name
      _ -> nil
    end)
  end
end
