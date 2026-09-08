defmodule ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Ubuntu do
  @moduledoc """
  Revalidates the compact Ubuntu projection emitted by the bounded Go helper.

  Raw OSV and OpenVEX documents deliberately never cross this boundary. Every
  content-addressed identity and semantic assertion is recomputed before the
  loader receives schema-native maps.
  """

  alias ServiceRadar.Inventory.PackageUrl

  @normalization_version 2
  @cve ~r/^CVE-\d{4}-\d{4,}$/
  @sha256 ~r/^[0-9a-f]{64}$/
  @uuid_v8 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @canonical_author "Canonical Ltd."
  @validated_projection "ubuntu-v2"

  @product_domain "serviceradar.ubuntu.product.v2"
  @product_lookup_domain "serviceradar.ubuntu.product-lookup.v2"
  @product_set_domain "serviceradar.ubuntu.product-set.v2"
  @osv_assertion_domain "serviceradar.ubuntu.osv-assertion.v2"
  @vex_statement_domain "serviceradar.ubuntu.vex-statement.v2"
  @vex_assertion_domain "serviceradar.ubuntu.vex-assertion.v2"
  @advisory_projection_domain "serviceradar.ubuntu.advisory.v2"
  @coordinate_projection_domain "serviceradar.ubuntu.coordinate.v2"
  @coordinates_projection_domain "serviceradar.ubuntu.coordinates.v2"
  @assertion_ref_projection_domain "serviceradar.ubuntu.projection-assertion-ref.v2"
  @assertion_refs_projection_domain "serviceradar.ubuntu.projection-assertions.v2"
  @projection_domain "serviceradar.ubuntu.projection.v2"

  @max_purl_bytes 2_048
  @max_evidence_bytes 4_096
  @max_description_bytes 1_048_576
  @max_references 8_192
  @max_qualifiers 64
  @max_projection_map_bytes 8_192
  @max_product_set_members 65_536
  @max_product_set_canonical_bytes 16 * 1_024 * 1_024
  @max_product_depth 64

  @record_required ~w(protocol_version cve_id projection_digest advisory coordinates products product_sets assertions)
  @advisory_required ~w(source_object_id advisory_id cve_id title references provenance)
  @advisory_optional ~w(description severity cvss_vector published_at modified_at withdrawn_at)
  @provenance_required ~w(
    normalization_version osv_present vex_present osv_withdrawn
    vex_empty_statements_tombstone osv_affected_count vex_statement_count
    repaired_source_purl_count
  )
  @provenance_optional ~w(
    osv_archive_sha256 vex_archive_sha256 osv_document_sha256 vex_document_sha256
  )
  @product_required ~w(
    id digest lookup_key canonical_size_bytes normalization_version package_type namespace name
    version purl scope qualifiers metadata
  )
  @product_optional ~w(
    release release_channel distro architecture source_name source_version parent_product_id
  )
  @product_metadata_required ~w(missing_release)
  @product_metadata_optional ~w(source_purl_repaired raw_source_purl)
  @set_required ~w(id digest product_ids count canonical_size_bytes normalization_version)
  @assertion_required ~w(
    assertion_key cve_id source_kind authority source_timestamp disposition package_type
    namespace version_scheme product_scope validation provenance metadata
  )
  @assertion_optional ~w(
    statement_fingerprint product_set_ref product_set_digest release release_channel
    source_package package_purl introduced_version fixed_version affected_versions
    justification status_text action_text fingerprint_aliases
  )

  @not_affected_justifications ~w(
    component_not_present
    vulnerable_code_not_present
    vulnerable_code_not_in_execute_path
    vulnerable_code_cannot_be_controlled_by_adversary
    inline_mitigations_already_exist
  )

  @spec normalization_version() :: pos_integer()
  def normalization_version, do: @normalization_version

  @doc false
  @spec product_lookup_key(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def product_lookup_key(package_type, namespace, name, version)
      when is_binary(package_type) and is_binary(namespace) and is_binary(name) and
             is_binary(version) do
    @product_lookup_domain
    |> tuple_digest([package_type, namespace, name, version])
    |> uuid_from_digest()
  end

  @spec parse_record(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse_record(projected, opts \\ []) do
    with {:ok, record, _context, _counters} <- validate_record(projected, opts), do: {:ok, record}
  end

  @doc false
  @spec validate_record(map(), keyword()) ::
          {:ok, map(), %{products: map(), product_sets: map()}, map()} | {:error, term()}
  def validate_record(projected, opts \\ []) do
    result =
      with :ok <- exact_shape(projected, @record_required, []),
           :ok <- equal(projected["protocol_version"], @normalization_version, :protocol_version),
           {:ok, cve} <- cve(projected["cve_id"]),
           {:ok, provenance} <- validate_advisory(projected["advisory"], cve, opts),
           {:ok, coordinates} <- validate_coordinates(projected["coordinates"]),
           {:ok, products, product_index} <-
             validate_products(projected["products"], Keyword.get(opts, :known_products, %{})),
           {:ok, product_sets, set_index} <-
             validate_product_sets(
               projected["product_sets"],
               product_index,
               Keyword.get(opts, :known_product_sets, %{})
             ),
           {:ok, assertions, counters} <-
             validate_assertions(projected["assertions"], cve, provenance, set_index),
           :ok <- validate_cross_record(coordinates, assertions, provenance),
           :ok <- validate_projection_digest(projected),
           {:ok, _projection_digest_bytes} <- digest(projected["projection_digest"]) do
        provider = Keyword.get(opts, :provider, "ubuntu")
        feed_key = Keyword.get(opts, :feed_key, "ubuntu-osv-vex")

        record = %{
          advisory:
            loader_advisory(
              projected["advisory"],
              provenance,
              projected["projection_digest"],
              provider,
              feed_key
            ),
          coordinates: coordinates,
          products: products,
          product_sets: product_sets,
          assertions: assertions
        }

        validation_context = %{products: product_index, product_sets: set_index}

        {:ok, record, validation_context,
         Map.merge(counters, %{
           products: length(products),
           product_sets: length(product_sets),
           unscoped_products: Enum.count(products, & &1.metadata["missing_release"]),
           repaired_source_purls: provenance["repaired_source_purl_count"],
           osv_documents: bool_count(provenance["osv_present"]),
           vex_documents: bool_count(provenance["vex_present"]),
           withdrawn_documents: bool_count(provenance["osv_withdrawn"]),
           vex_tombstones: bool_count(provenance["vex_empty_statements_tombstone"]),
           osv_affected_entries: provenance["osv_affected_count"],
           vex_statements: provenance["vex_statement_count"]
         })}
      end

    case result do
      {:error, {:invalid_ubuntu_projection, _}} = error -> error
      {:error, reason} -> {:error, {:invalid_ubuntu_projection, reason}}
      other -> other
    end
  rescue
    error -> {:error, {:invalid_ubuntu_projection, Exception.message(error)}}
  end

  defp validate_advisory(advisory, cve, opts) do
    with :ok <- exact_shape(advisory, @advisory_required, @advisory_optional),
         :ok <- equal(advisory["source_object_id"], "UBUNTU-#{cve}", :source_object_id),
         :ok <- equal(advisory["advisory_id"], "UBUNTU-#{cve}", :advisory_id),
         :ok <- equal(advisory["cve_id"], cve, :advisory_cve_id),
         :ok <- present_text(advisory["title"], @max_evidence_bytes, :title),
         :ok <- optional_text(advisory["description"], @max_description_bytes, :description),
         :ok <- optional_text(advisory["severity"], 128, :severity),
         :ok <- optional_text(advisory["cvss_vector"], 1_024, :cvss_vector),
         :ok <- optional_timestamp(advisory["published_at"], :published_at),
         :ok <- optional_timestamp(advisory["modified_at"], :modified_at),
         :ok <- optional_timestamp(advisory["withdrawn_at"], :withdrawn_at),
         :ok <- validate_references(advisory["references"]),
         {:ok, provenance} <- validate_provenance(advisory["provenance"], opts),
         :ok <- validate_withdrawn_at(advisory["withdrawn_at"], provenance) do
      {:ok, provenance}
    end
  end

  defp validate_references(references) when is_list(references) do
    with :ok <- less_than_or_equal(length(references), @max_references, :reference_count),
         :ok <- each(references, &present_text(&1, @max_evidence_bytes, :reference)) do
      sorted_unique(references, :references)
    end
  end

  defp validate_references(_), do: {:error, :references}

  defp validate_provenance(provenance, opts) do
    source_digests = Keyword.get(opts, :source_digests, %{})

    with :ok <- exact_shape(provenance, @provenance_required, @provenance_optional),
         :ok <- bounded_map(provenance, @max_projection_map_bytes, :advisory_provenance),
         :ok <-
           equal(
             provenance["normalization_version"],
             @normalization_version,
             :normalization_version
           ),
         :ok <- boolean(provenance["osv_present"], :osv_present),
         :ok <- boolean(provenance["vex_present"], :vex_present),
         :ok <- at_least_one(provenance["osv_present"], provenance["vex_present"]),
         :ok <- boolean(provenance["osv_withdrawn"], :osv_withdrawn),
         :ok <- boolean(provenance["vex_empty_statements_tombstone"], :vex_tombstone),
         :ok <- nonnegative_integer(provenance["osv_affected_count"], :osv_affected_count),
         :ok <- nonnegative_integer(provenance["vex_statement_count"], :vex_statement_count),
         :ok <- nonnegative_integer(provenance["repaired_source_purl_count"], :repair_count),
         :ok <- validate_side_provenance(provenance, "osv", source_digests),
         :ok <- validate_side_provenance(provenance, "vex", source_digests),
         :ok <-
           equal(
             provenance["vex_empty_statements_tombstone"],
             provenance["vex_present"] and provenance["vex_statement_count"] == 0,
             :vex_tombstone
           ),
         :ok <-
           condition(
             not provenance["osv_withdrawn"] or provenance["osv_present"],
             :withdrawn_without_osv
           ),
         :ok <-
           condition(
             provenance["repaired_source_purl_count"] <= provenance["osv_affected_count"],
             :repair_count
           ) do
      {:ok, provenance}
    end
  end

  defp validate_side_provenance(provenance, side, source_digests) do
    present = provenance["#{side}_present"]
    archive = provenance["#{side}_archive_sha256"]
    document = provenance["#{side}_document_sha256"]

    expected =
      if present,
        do: Map.get(source_digests, String.to_atom(side)) || Map.get(source_digests, side)

    with :ok <- required_digest_if(present, archive, "#{side}_archive_sha256"),
         :ok <- required_digest_if(present, document, "#{side}_document_sha256") do
      equal_if_present(expected, archive, "#{side}_archive_sha256")
    end
  end

  defp validate_withdrawn_at(value, %{"osv_withdrawn" => true}) when is_binary(value), do: :ok
  defp validate_withdrawn_at(nil, %{"osv_withdrawn" => false}), do: :ok
  defp validate_withdrawn_at(_, _), do: {:error, :withdrawn_at}

  defp validate_coordinates(coordinates) when is_list(coordinates) do
    with :ok <- sorted_unique_by(coordinates, & &1["value"], :coordinates) do
      map_ok(coordinates, &validate_coordinate/1)
    end
  end

  defp validate_coordinates(_), do: {:error, :coordinates}

  defp validate_coordinate(coordinate) do
    with :ok <- exact_shape(coordinate, ~w(coordinate_type value metadata), []),
         :ok <- equal(coordinate["coordinate_type"], "purl", :coordinate_type),
         :ok <- equal(coordinate["metadata"], %{"namespace" => "ubuntu"}, :coordinate_metadata),
         {:ok, parsed} <- canonical_ubuntu_purl(coordinate["value"], require_version?: false),
         :ok <- condition(parsed.qualifiers["distro"] not in [nil, ""], :coordinate_distro),
         :ok <- condition(parsed.qualifiers["arch"] in ["source", "src"], :coordinate_arch) do
      {:ok,
       %{
         coordinate_type: "purl",
         value: coordinate["value"],
         cpe_part: nil,
         cpe_vendor: nil,
         cpe_product: nil,
         cpe_version: nil,
         version_start: nil,
         version_start_inclusive: nil,
         version_end: nil,
         version_end_inclusive: nil,
         metadata: coordinate["metadata"]
       }}
    end
  end

  defp validate_products(products, known) when is_list(products) and is_map(known) do
    with :ok <- sorted_unique_by(products, & &1["id"], :products),
         :ok <- validate_known_index(known, :known_products),
         {:ok, prepared} <- prepare_products(products),
         {:ok, resolved} <- resolve_products(prepared, known) do
      emitted_index = Map.new(resolved, &{&1.id, &1.content_sha256})

      with :ok <- reject_collisions(emitted_index, known, :product_collision) do
        {:ok, resolved, Map.merge(known, emitted_index)}
      end
    end
  end

  defp validate_products(_, _), do: {:error, :products}

  defp prepare_products(products) do
    products
    |> map_ok(fn product ->
      with :ok <- exact_shape(product, @product_required, @product_optional),
           :ok <- bounded_map(product["qualifiers"], @max_projection_map_bytes, :qualifiers),
           :ok <- condition(map_size(product["qualifiers"]) <= @max_qualifiers, :qualifier_count),
           :ok <- string_map(product["qualifiers"], :qualifiers),
           :ok <-
             exact_shape(
               product["metadata"],
               @product_metadata_required,
               @product_metadata_optional
             ),
           :ok <- bounded_map(product["metadata"], @max_projection_map_bytes, :product_metadata),
           :ok <- boolean(product["metadata"]["missing_release"], :missing_release),
           :ok <-
             optional_boolean(product["metadata"]["source_purl_repaired"], :source_purl_repaired),
           {:ok, id_bytes} <- uuid(product["id"]),
           {:ok, digest_bytes} <- digest(product["digest"]),
           {:ok, _lookup_bytes} <- uuid(product["lookup_key"]),
           :ok <-
             equal(product["normalization_version"], @normalization_version, :product_version),
           :ok <- positive_integer(product["canonical_size_bytes"], :product_canonical_size),
           {:ok, parsed} <- canonical_ubuntu_purl(product["purl"]),
           :ok <- validate_product_fields(product, parsed),
           :ok <- validate_repaired_product(product) do
        {:ok,
         %{
           raw: product,
           id: product["id"],
           id_bytes: id_bytes,
           claimed_digest: digest_bytes,
           parsed: parsed
         }}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Map.new(values, &{&1.id, &1})}
      error -> error
    end
  end

  defp validate_product_fields(product, parsed) do
    release = optional_value(product["release"])
    distro = optional_value(product["distro"])
    architecture = optional_value(product["architecture"])
    source_name = optional_value(product["source_name"])
    source_version = optional_value(product["source_version"])
    scope = product["scope"]
    parent = optional_value(product["parent_product_id"])

    with :ok <- equal(product["package_type"], "deb", :product_package_type),
         :ok <- equal(product["namespace"], "ubuntu", :product_namespace),
         :ok <- present_text(product["name"], @max_purl_bytes, :product_name),
         :ok <- present_text(product["version"], @max_purl_bytes, :product_version),
         :ok <- equal(parsed.type, product["package_type"], :purl_package_type),
         :ok <- equal(parsed.namespace, [product["namespace"]], :purl_namespace),
         :ok <- equal(parsed.name, product["name"], :purl_name),
         :ok <- equal(parsed.version, product["version"], :purl_version),
         :ok <- equal(parsed.qualifiers, product["qualifiers"], :purl_qualifiers),
         :ok <- equal(release, distro, :release_distro),
         :ok <- equal(distro, optional_value(parsed.qualifiers["distro"]), :purl_distro),
         :ok <- equal(architecture, optional_value(parsed.qualifiers["arch"]), :purl_architecture),
         :ok <-
           equal(product["metadata"]["missing_release"], is_nil(release), :missing_release),
         :ok <- optional_text(release, @max_evidence_bytes, :release),
         :ok <- optional_text(product["release_channel"], @max_evidence_bytes, :release_channel),
         :ok <- optional_text(architecture, @max_evidence_bytes, :architecture),
         :ok <- optional_text(source_name, @max_evidence_bytes, :source_name),
         :ok <- optional_text(source_version, @max_purl_bytes, :source_version),
         :ok <- condition(scope in ~w(source binary exact_product subcomponent), :product_scope),
         :ok <- validate_scope(scope, parent, architecture, product) do
      optional_uuid(parent, :parent_product_id)
    end
  end

  defp validate_scope("source", nil, architecture, product)
       when architecture in ["source", "src"] do
    with :ok <- equal(product["source_name"], product["name"], :source_name),
         :ok <- equal(product["source_version"], product["version"], :source_version) do
      condition(not is_nil(optional_value(product["release_channel"])), :release_channel)
    end
  end

  defp validate_scope("binary", nil, nil, product) do
    condition(not is_nil(optional_value(product["release_channel"])), :release_channel)
  end

  defp validate_scope("exact_product", nil, architecture, _product) when is_binary(architecture),
    do: :ok

  defp validate_scope("subcomponent", parent, architecture, _product)
       when is_binary(parent) and is_binary(architecture),
       do: :ok

  defp validate_scope(_, _, _, _), do: {:error, :product_scope}

  defp validate_repaired_product(product) do
    repaired? = Map.get(product["metadata"], "source_purl_repaired", false)
    raw = product["metadata"]["raw_source_purl"]

    cond do
      repaired? and is_binary(raw) and byte_size(raw) <= @max_purl_bytes and
        String.contains?(raw, "?arch=src?distro=") and length(String.split(raw, "?")) == 3 ->
        repaired = String.replace(raw, "?arch=src?distro=", "?arch=src&distro=", global: false)

        with {:ok, canonical} <- PackageUrl.canonicalize(repaired) do
          equal(canonical, product["purl"], :repaired_source_purl)
        end

      repaired? ->
        {:error, :raw_source_purl}

      is_nil(raw) ->
        :ok

      true ->
        {:error, :unexpected_raw_source_purl}
    end
  end

  defp resolve_products(prepared, known) do
    prepared
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn id, {:ok, memo} ->
      case resolve_product(id, prepared, known, memo, MapSet.new(), 0) do
        {:ok, _product, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} ->
        {:ok, prepared |> Map.keys() |> Enum.sort() |> Enum.map(&resolved[&1].mapped)}

      error ->
        error
    end
  end

  defp resolve_product(id, _prepared, _known, memo, _trail, _depth) when is_map_key(memo, id),
    do: {:ok, memo[id], memo}

  defp resolve_product(_id, _prepared, _known, _memo, _trail, depth)
       when depth > @max_product_depth,
       do: {:error, :product_parent_depth}

  defp resolve_product(id, prepared, known, memo, trail, depth) do
    with :ok <- condition(not MapSet.member?(trail, id), :product_parent_cycle),
         %{raw: raw} = value <- Map.get(prepared, id) || {:error, :missing_product},
         {:ok, parent_digest, memo} <-
           resolve_parent(
             raw["parent_product_id"],
             prepared,
             known,
             memo,
             MapSet.put(trail, id),
             depth
           ),
         {:ok, digest_bytes, canonical_size} <- product_digest(raw, parent_digest),
         :ok <- equal(raw["canonical_size_bytes"], canonical_size, :product_canonical_size),
         :ok <- equal(digest_bytes, value.claimed_digest, :product_digest),
         :ok <- equal(uuid_from_digest(digest_bytes), raw["id"], :product_id),
         :ok <-
           equal(
             product_lookup_key(
               raw["package_type"],
               raw["namespace"],
               raw["name"],
               raw["version"]
             ),
             raw["lookup_key"],
             :product_lookup_key
           ) do
      mapped = loader_product(raw)
      resolved = %{mapped: mapped, digest: digest_bytes}
      next = Map.put(memo, id, resolved)
      {:ok, resolved, next}
    else
      {:error, _} = error -> error
      _ -> {:error, :product_resolution}
    end
  end

  defp resolve_parent(nil, _prepared, _known, memo, _trail, _depth), do: {:ok, nil, memo}

  defp resolve_parent("", prepared, known, memo, trail, depth),
    do: resolve_parent(nil, prepared, known, memo, trail, depth)

  defp resolve_parent(parent_id, prepared, known, memo, trail, depth) do
    cond do
      Map.has_key?(prepared, parent_id) ->
        with {:ok, parent, next} <-
               resolve_product(parent_id, prepared, known, memo, trail, depth + 1) do
          {:ok, parent.digest, next}
        end

      Map.has_key?(known, parent_id) ->
        with {:ok, digest_bytes} <- digest(known[parent_id]), do: {:ok, digest_bytes, memo}

      true ->
        {:error, :missing_parent_product}
    end
  end

  defp product_digest(product, parent_digest) do
    with {:ok, qualifiers} <- encode_string_map(product["qualifiers"]) do
      canonical =
        tuple_binary(@product_domain, [
          u32(@normalization_version),
          product["package_type"],
          product["namespace"],
          product["name"],
          product["version"],
          optional_field(product["release"]),
          optional_field(product["release_channel"]),
          optional_field(product["distro"]),
          optional_field(product["architecture"]),
          optional_field(product["source_name"]),
          optional_field(product["source_version"]),
          product["scope"],
          parent_digest,
          qualifiers
        ])

      {:ok, :crypto.hash(:sha256, canonical), byte_size(canonical)}
    end
  end

  defp loader_product(product) do
    %{
      id: product["id"],
      content_sha256: product["digest"],
      lookup_key: product["lookup_key"],
      normalization_version: @normalization_version,
      package_type: product["package_type"],
      namespace: product["namespace"],
      package_name: product["name"],
      package_version: product["version"],
      release: optional_value(product["release"]),
      release_channel: optional_value(product["release_channel"]),
      architecture: optional_value(product["architecture"]),
      source_package: optional_value(product["source_name"]),
      source_version: optional_value(product["source_version"]),
      canonical_purl: product["purl"],
      product_scope: product["scope"],
      parent_product_id: optional_value(product["parent_product_id"]),
      qualifiers: product["qualifiers"],
      metadata: product["metadata"]
    }
  end

  defp validate_product_sets(sets, products, known)
       when is_list(sets) and is_map(products) and is_map(known) do
    with :ok <- sorted_unique_by(sets, & &1["id"], :product_sets),
         :ok <- validate_known_index(known, :known_product_sets),
         {:ok, mapped} <- map_ok(sets, &validate_product_set(&1, products)),
         emitted = Map.new(mapped, &{&1.id, &1.content_sha256}),
         :ok <- reject_collisions(emitted, known, :product_set_collision) do
      {:ok, mapped, Map.merge(known, emitted)}
    end
  end

  defp validate_product_sets(_, _, _), do: {:error, :product_sets}

  defp validate_product_set(set, products) do
    with :ok <- exact_shape(set, @set_required, []),
         {:ok, claimed_digest} <- digest(set["digest"]),
         {:ok, _id_bytes} <- uuid(set["id"]),
         :ok <- equal(set["normalization_version"], @normalization_version, :set_version),
         :ok <- positive_integer(set["count"], :product_count),
         :ok <- condition(set["count"] <= @max_product_set_members, :product_set_member_cap),
         :ok <- equal(set["count"], length_or_invalid(set["product_ids"]), :product_count),
         {:ok, product_id_bytes} <- validate_product_ids(set["product_ids"], products),
         canonical =
           tuple_binary(
             @product_set_domain,
             [u32(@normalization_version), u32(set["count"])] ++ product_id_bytes
           ),
         :ok <- condition(byte_size(canonical) <= @max_product_set_canonical_bytes, :set_size_cap),
         :ok <- equal(set["canonical_size_bytes"], byte_size(canonical), :canonical_size_bytes),
         actual_digest = :crypto.hash(:sha256, canonical),
         :ok <- equal(claimed_digest, actual_digest, :product_set_digest),
         :ok <- equal(set["id"], uuid_from_digest(actual_digest), :product_set_id) do
      {:ok,
       %{
         id: set["id"],
         content_sha256: set["digest"],
         normalization_version: @normalization_version,
         product_ids: set["product_ids"],
         product_count: set["count"],
         canonical_size_bytes: set["canonical_size_bytes"],
         metadata: %{}
       }}
    end
  end

  defp validate_product_ids(ids, products) when is_list(ids) do
    with :ok <- condition(ids != [], :empty_product_set),
         {:ok, decoded} <- map_ok(ids, &uuid/1),
         :ok <- equal(decoded, Enum.sort(decoded), :product_id_order),
         :ok <-
           condition(length(decoded) == MapSet.size(MapSet.new(decoded)), :duplicate_product_id),
         :ok <- each(ids, &condition(Map.has_key?(products, &1), :unknown_product_id)) do
      {:ok, decoded}
    end
  end

  defp validate_product_ids(_, _), do: {:error, :product_ids}

  defp validate_assertions(assertions, cve, provenance, sets) when is_list(assertions) do
    with :ok <- sorted_unique_by(assertions, & &1["assertion_key"], :assertions),
         {:ok, mapped_and_counts} <-
           map_ok(assertions, &validate_assertion(&1, cve, provenance, sets)) do
      mapped = Enum.map(mapped_and_counts, &elem(&1, 0))
      logical = Enum.reduce(mapped_and_counts, 0, &(elem(&1, 1) + &2))

      {:ok, mapped,
       %{
         assertions: length(mapped),
         logical_product_occurrences: logical
       }}
    end
  end

  defp validate_assertions(_, _, _, _), do: {:error, :assertions}

  defp validate_assertion(assertion, cve, provenance, sets) do
    with :ok <- exact_shape(assertion, @assertion_required, @assertion_optional),
         {:ok, _key_bytes} <- digest(assertion["assertion_key"]),
         :ok <- equal(assertion["cve_id"], cve, :assertion_cve),
         :ok <- equal(assertion["authority"], @canonical_author, :assertion_authority),
         :ok <- equal(assertion["package_type"], "deb", :assertion_package_type),
         :ok <- equal(assertion["namespace"], "ubuntu", :assertion_namespace),
         :ok <- equal(assertion["version_scheme"], "deb", :version_scheme),
         :ok <- timestamp(assertion["source_timestamp"], :source_timestamp),
         :ok <- optional_text(assertion["justification"], @max_evidence_bytes, :justification),
         :ok <- optional_text(assertion["status_text"], @max_evidence_bytes, :status_text),
         :ok <- optional_text(assertion["action_text"], @max_evidence_bytes, :action_text),
         :ok <- bounded_map(assertion["validation"], @max_projection_map_bytes, :validation),
         :ok <-
           bounded_map(assertion["provenance"], @max_projection_map_bytes, :assertion_provenance),
         :ok <- bounded_map(assertion["metadata"], @max_projection_map_bytes, :assertion_metadata),
         :ok <- equal(assertion["metadata"], %{}, :assertion_metadata),
         :ok <- empty_versions(assertion["affected_versions"]),
         {:ok, set_digest} <- validate_assertion_set(assertion, sets),
         {:ok, mapped, logical_count} <-
           validate_assertion_kind(assertion, cve, provenance, set_digest) do
      {:ok, {mapped, logical_count}}
    end
  end

  defp validate_assertion_set(assertion, sets) do
    ref = optional_value(assertion["product_set_ref"])
    digest_value = optional_value(assertion["product_set_digest"])

    case {ref, digest_value} do
      {nil, nil} ->
        {:ok, nil}

      {ref, digest_value} when is_binary(ref) and is_binary(digest_value) ->
        with {:ok, _} <- uuid(ref),
             {:ok, digest_bytes} <- digest(digest_value),
             :ok <- equal(Map.get(sets, ref), digest_value, :assertion_product_set) do
          {:ok, digest_bytes}
        end

      _ ->
        {:error, :assertion_product_set}
    end
  end

  defp validate_assertion_kind(
         %{"source_kind" => "ubuntu_osv"} = assertion,
         cve,
         provenance,
         set_digest
       ) do
    validation = assertion["validation"]
    assertion_provenance = assertion["provenance"]
    release = optional_value(assertion["release"])
    channel = optional_value(assertion["release_channel"])
    package_purl = optional_value(assertion["package_purl"])

    with :ok <- exact_shape(validation, ~w(ecosystem range_type event_cycle_count), []),
         :ok <-
           exact_shape(
             assertion_provenance,
             ~w(
             archive_sha256 source_document_sha256 explicit_source_versions
             binary_correlations source_purl_repaired
           ),
             ~w(raw_source_purl)
           ),
         :ok <- equal(assertion["authority"], @canonical_author, :osv_authority),
         :ok <- equal(assertion["disposition"], "affected", :osv_disposition),
         :ok <- equal(assertion["product_scope"], "source_to_binary", :osv_scope),
         :ok <- present_text(assertion["source_package"], @max_evidence_bytes, :source_package),
         :ok <-
           present_text(assertion["introduced_version"], @max_purl_bytes, :introduced_version),
         :ok <- optional_text(assertion["fixed_version"], @max_purl_bytes, :fixed_version),
         :ok <- condition(is_nil(release) or is_binary(release), :osv_release),
         :ok <- condition(is_binary(channel), :osv_release_channel),
         :ok <- equal(validation["ecosystem"], "Ubuntu:#{channel}", :osv_ecosystem),
         :ok <- equal(validation["range_type"], "ECOSYSTEM", :osv_range_type),
         :ok <- equal(validation["event_cycle_count"], 1, :osv_event_cycle_count),
         :ok <-
           validate_osv_package_purl(package_purl, assertion["source_package"], release),
         :ok <- validate_assertion_provenance(assertion_provenance, provenance, "osv"),
         :ok <-
           nonnegative_integer(assertion_provenance["explicit_source_versions"], :source_versions),
         :ok <-
           nonnegative_integer(assertion_provenance["binary_correlations"], :binary_correlations),
         :ok <- boolean(assertion_provenance["source_purl_repaired"], :source_purl_repaired),
         :ok <- validate_repaired_assertion(assertion_provenance, package_purl),
         logical =
           assertion_provenance["explicit_source_versions"] +
             assertion_provenance["binary_correlations"],
         :ok <-
           condition(
             (logical == 0 and is_nil(set_digest)) or (logical > 0 and not is_nil(set_digest)),
             :osv_set
           ),
         expected_key =
           tuple_digest(@osv_assertion_domain, [
             u32(@normalization_version),
             assertion["source_kind"],
             cve,
             assertion["product_scope"],
             assertion["authority"],
             assertion["source_timestamp"],
             assertion["disposition"],
             assertion["package_type"],
             assertion["namespace"],
             optional_field(release),
             optional_field(channel),
             assertion["version_scheme"],
             assertion["source_package"],
             optional_field(package_purl),
             assertion["introduced_version"],
             optional_field(assertion["fixed_version"]),
             set_digest
           ]),
         :ok <- equal(hex(expected_key), assertion["assertion_key"], :osv_assertion_key) do
      {:ok, loader_assertion(assertion), logical}
    end
  end

  defp validate_assertion_kind(
         %{"source_kind" => "ubuntu_openvex"} = assertion,
         cve,
         provenance,
         set_digest
       ) do
    assertion_provenance = assertion["provenance"]

    with :ok <- exact_shape(assertion["validation"], ~w(fingerprint_basis), []),
         :ok <-
           exact_shape(
             assertion_provenance,
             ~w(archive_sha256 source_document_sha256 logical_product_count unique_product_count),
             []
           ),
         :ok <- condition(not is_nil(set_digest), :vex_product_set),
         :ok <- equal(assertion["product_scope"], "exact_product_set", :vex_scope),
         :ok <-
           condition(
             assertion["disposition"] in ~w(affected not_affected fixed under_investigation),
             :vex_disposition
           ),
         :ok <-
           all_absent(
             assertion,
             ~w(release release_channel source_package package_purl introduced_version fixed_version)
           ),
         :ok <- validate_assertion_provenance(assertion_provenance, provenance, "vex"),
         :ok <-
           positive_integer(assertion_provenance["logical_product_count"], :logical_product_count),
         :ok <-
           positive_integer(assertion_provenance["unique_product_count"], :unique_product_count),
         :ok <-
           condition(
             assertion_provenance["unique_product_count"] <=
               assertion_provenance["logical_product_count"],
             :unique_product_count
           ),
         {:ok, fingerprint} <- validate_fingerprint(assertion, cve),
         expected_key =
           tuple_digest(@vex_assertion_domain, [
             u32(@normalization_version),
             assertion["source_kind"],
             cve,
             assertion["product_scope"],
             fingerprint,
             set_digest
           ]),
         :ok <- equal(hex(expected_key), assertion["assertion_key"], :vex_assertion_key) do
      {:ok, loader_assertion(assertion), assertion_provenance["logical_product_count"]}
    end
  end

  defp validate_assertion_kind(_, _, _, _), do: {:error, :source_kind}

  defp validate_osv_package_purl(nil, _source_package, nil), do: :ok

  defp validate_osv_package_purl(package_purl, source_package, release)
       when is_binary(package_purl) and is_binary(release) do
    with {:ok, parsed} <- canonical_ubuntu_purl(package_purl, require_version?: false),
         :ok <- equal(parsed.name, source_package, :osv_source_package),
         :ok <- equal(parsed.qualifiers["distro"], release, :osv_release) do
      condition(parsed.qualifiers["arch"] in ["source", "src"], :osv_source_arch)
    end
  end

  defp validate_osv_package_purl(_, _, _), do: {:error, :osv_package_purl}

  defp validate_assertion_provenance(assertion, advisory, side) do
    with {:ok, _} <- digest(assertion["archive_sha256"]),
         {:ok, _} <- digest(assertion["source_document_sha256"]),
         :ok <-
           equal(assertion["archive_sha256"], advisory["#{side}_archive_sha256"], :archive_digest) do
      equal(
        assertion["source_document_sha256"],
        advisory["#{side}_document_sha256"],
        :document_digest
      )
    end
  end

  defp validate_repaired_assertion(provenance, canonical_purl) do
    repaired? = provenance["source_purl_repaired"]
    raw = provenance["raw_source_purl"]

    cond do
      repaired? and is_binary(raw) and byte_size(raw) <= @max_purl_bytes and
        String.contains?(raw, "?arch=src?distro=") and length(String.split(raw, "?")) == 3 ->
        repaired = String.replace(raw, "?arch=src?distro=", "?arch=src&distro=", global: false)

        with {:ok, canonical} <- PackageUrl.canonicalize(repaired) do
          equal(canonical, canonical_purl, :raw_source_purl)
        end

      repaired? ->
        {:error, :raw_source_purl}

      is_nil(raw) ->
        :ok

      true ->
        {:error, :unexpected_raw_source_purl}
    end
  end

  defp validate_fingerprint(assertion, cve) do
    basis = assertion["validation"]["fingerprint_basis"]
    aliases = assertion["fingerprint_aliases"] || basis["vulnerability_aliases"] || []

    required = ~w(
      normalization_version document_context document_id document_author document_version
      document_timestamp document_last_updated vulnerability_name vulnerability_id
      vulnerability_description statement_version statement_timestamp
      statement_last_updated action_statement_timestamp effective_timestamp status justification
      status_notes action_statement impact_statement
    )

    with :ok <- exact_shape(basis, required, ~w(vulnerability_aliases)),
         :ok <- bounded_map(basis, @max_projection_map_bytes, :fingerprint_basis),
         :ok <- validate_alias_transport(assertion, basis, aliases),
         :ok <-
           equal(basis["normalization_version"], @normalization_version, :fingerprint_version),
         :ok <- equal(basis["document_context"], "https://openvex.dev/ns/v0.2.0", :vex_context),
         :ok <- present_text(basis["document_id"], @max_evidence_bytes, :vex_document_id),
         :ok <- equal(basis["document_author"], @canonical_author, :vex_author),
         :ok <- positive_integer(basis["document_version"], :vex_document_version),
         :ok <- timestamp(basis["document_timestamp"], :vex_document_timestamp),
         :ok <- optional_timestamp(basis["document_last_updated"], :vex_document_last_updated),
         :ok <- equal(basis["vulnerability_name"], cve, :vulnerability_name),
         :ok <- optional_text(basis["vulnerability_id"], @max_evidence_bytes, :vulnerability_id),
         :ok <- validate_aliases(aliases),
         :ok <-
           optional_text(
             basis["vulnerability_description"],
             @max_description_bytes,
             :vulnerability_description
           ),
         :ok <- optional_positive_integer(basis["statement_version"], :statement_version),
         :ok <- optional_timestamp(basis["statement_timestamp"], :statement_timestamp),
         :ok <- optional_timestamp(basis["statement_last_updated"], :statement_last_updated),
         :ok <-
           optional_timestamp(basis["action_statement_timestamp"], :action_statement_timestamp),
         :ok <- timestamp(basis["effective_timestamp"], :effective_timestamp),
         :ok <-
           equal(
             basis["effective_timestamp"],
             assertion["source_timestamp"],
             :effective_timestamp
           ),
         :ok <- equal(basis["status"], assertion["disposition"], :vex_status),
         :ok <-
           equal(
             optional_value(basis["justification"]),
             optional_value(assertion["justification"]),
             :vex_justification
           ),
         :ok <-
           equal(
             optional_value(basis["status_notes"]),
             optional_value(assertion["status_text"]),
             :vex_status_notes
           ),
         :ok <-
           equal(
             first_present(basis["action_statement"], basis["impact_statement"]),
             optional_value(assertion["action_text"]),
             :vex_action_text
           ),
         :ok <- validate_vex_evidence(basis),
         expected =
           tuple_digest(@vex_statement_domain, [
             u32(@normalization_version),
             basis["document_context"],
             basis["document_id"],
             basis["document_author"],
             u64(basis["document_version"]),
             basis["document_timestamp"],
             optional_field(basis["document_last_updated"]),
             basis["vulnerability_name"],
             optional_field(basis["vulnerability_id"]),
             encode_string_list(aliases),
             optional_field(basis["vulnerability_description"]),
             optional_u64(basis["statement_version"]),
             optional_field(basis["statement_timestamp"]),
             optional_field(basis["statement_last_updated"]),
             optional_field(basis["action_statement_timestamp"]),
             basis["effective_timestamp"],
             basis["status"],
             optional_field(basis["justification"]),
             optional_field(basis["status_notes"]),
             optional_field(basis["action_statement"]),
             optional_field(basis["impact_statement"])
           ]),
         {:ok, claimed} <- digest(assertion["statement_fingerprint"]),
         :ok <- equal(expected, claimed, :statement_fingerprint) do
      {:ok, expected}
    end
  end

  defp validate_alias_transport(assertion, basis, aliases) do
    case {assertion["fingerprint_aliases"], basis["vulnerability_aliases"]} do
      {top_level, nested} when is_list(top_level) and is_list(nested) ->
        equal(top_level, nested, :vulnerability_alias_transport)

      {nil, nested} when is_list(nested) ->
        :ok

      {top_level, nil} when is_list(top_level) ->
        :ok

      {nil, nil} when aliases == [] ->
        :ok

      _ ->
        {:error, :vulnerability_alias_transport}
    end
  end

  defp validate_aliases(aliases) when is_list(aliases) do
    with :ok <- each(aliases, &present_text(&1, @max_evidence_bytes, :vulnerability_alias)),
         :ok <- less_than_or_equal(length(aliases), @max_references, :vulnerability_aliases) do
      sorted_unique(aliases, :vulnerability_aliases)
    end
  end

  defp validate_aliases(_), do: {:error, :vulnerability_aliases}

  defp validate_vex_evidence(%{"status" => "affected", "action_statement" => action}),
    do: present_text(action, @max_evidence_bytes, :action_statement)

  defp validate_vex_evidence(%{"status" => "not_affected"} = basis) do
    justification = optional_value(basis["justification"])

    condition(
      justification in @not_affected_justifications or
        (is_nil(justification) and not is_nil(optional_value(basis["impact_statement"]))),
      :not_affected_evidence
    )
  end

  defp validate_vex_evidence(%{"status" => status})
       when status in ["fixed", "under_investigation"], do: :ok

  defp validate_vex_evidence(_), do: {:error, :vex_status}

  defp loader_assertion(assertion) do
    product_set_ref = optional_value(assertion["product_set_ref"])

    %{
      assertion_key: assertion["assertion_key"],
      cve_id: assertion["cve_id"],
      authority: assertion["authority"],
      source_kind: assertion["source_kind"],
      source_timestamp: assertion["source_timestamp"],
      assertion_shape: if(is_nil(product_set_ref), do: "scalar", else: "product_set"),
      product_set_ref: product_set_ref,
      statement_fingerprint: optional_value(assertion["statement_fingerprint"]),
      package_type: assertion["package_type"],
      namespace: assertion["namespace"],
      release: optional_value(assertion["release"]),
      release_channel: optional_value(assertion["release_channel"]),
      product_scope: assertion["product_scope"],
      source_package: optional_value(assertion["source_package"]),
      binary_package: nil,
      architecture: nil,
      version_scheme: assertion["version_scheme"],
      disposition: assertion["disposition"],
      introduced_version: optional_value(assertion["introduced_version"]),
      fixed_version: optional_value(assertion["fixed_version"]),
      affected_versions: [],
      package_purl: optional_value(assertion["package_purl"]),
      justification: optional_value(assertion["justification"]),
      status_text: optional_value(assertion["status_text"]),
      action_text: optional_value(assertion["action_text"]),
      validation: assertion["validation"],
      raw: assertion["provenance"],
      metadata: %{"validated_projection" => @validated_projection}
    }
  end

  defp validate_cross_record(coordinates, assertions, provenance) do
    osv_assertions = Enum.filter(assertions, &(&1.source_kind == "ubuntu_osv"))
    vex_assertions = Enum.filter(assertions, &(&1.source_kind == "ubuntu_openvex"))
    coordinate_values = MapSet.new(coordinates, & &1.value)

    assertion_values =
      osv_assertions
      |> Enum.map(& &1.package_purl)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    repaired = Enum.count(osv_assertions, & &1.raw["source_purl_repaired"])

    expected_osv = if provenance["osv_withdrawn"], do: 0, else: provenance["osv_affected_count"]

    expected_vex =
      if provenance["vex_empty_statements_tombstone"],
        do: 0,
        else: provenance["vex_statement_count"]

    with :ok <- equal(length(osv_assertions), expected_osv, :osv_assertion_count),
         :ok <- equal(length(vex_assertions), expected_vex, :vex_assertion_count),
         :ok <- equal(coordinate_values, assertion_values, :osv_coordinates),
         :ok <-
           equal(repaired, provenance["repaired_source_purl_count"], :repaired_source_purl_count) do
      condition(not provenance["osv_withdrawn"] or coordinates == [], :withdrawn_coordinates)
    end
  end

  defp validate_projection_digest(projected) do
    with {:ok, claimed} <- digest(projected["projection_digest"]),
         {:ok, advisory} <- advisory_projection(projected["advisory"]),
         {:ok, coordinates} <- coordinates_projection(projected["coordinates"]),
         {:ok, assertions} <- assertion_refs_projection(projected["assertions"]) do
      actual =
        tuple_digest(@projection_domain, [
          u32(@normalization_version),
          projected["cve_id"],
          advisory,
          coordinates,
          assertions
        ])

      equal(claimed, actual, :projection_digest)
    end
  end

  defp advisory_projection(advisory) do
    provenance = advisory["provenance"]

    {:ok,
     tuple_binary(@advisory_projection_domain, [
       u32(@normalization_version),
       advisory["source_object_id"],
       advisory["advisory_id"],
       advisory["cve_id"],
       advisory["title"],
       optional_field(advisory["description"]),
       optional_field(advisory["severity"]),
       optional_field(advisory["cvss_vector"]),
       optional_field(advisory["published_at"]),
       optional_field(advisory["modified_at"]),
       optional_field(advisory["withdrawn_at"]),
       encode_string_list(advisory["references"]),
       bool_field(provenance["osv_present"]),
       bool_field(provenance["vex_present"]),
       bool_field(provenance["osv_withdrawn"]),
       bool_field(provenance["vex_empty_statements_tombstone"]),
       u64_zero(provenance["osv_affected_count"]),
       u64_zero(provenance["vex_statement_count"]),
       u64_zero(provenance["repaired_source_purl_count"])
     ])}
  end

  defp coordinates_projection(coordinates) do
    with {:ok, entries} <-
           map_ok(coordinates, fn coordinate ->
             with {:ok, metadata} <- encode_string_map(coordinate["metadata"]) do
               {:ok,
                tuple_binary(@coordinate_projection_domain, [
                  u32(@normalization_version),
                  coordinate["coordinate_type"],
                  coordinate["value"],
                  metadata
                ])}
             end
           end) do
      entries = Enum.sort(entries)

      {:ok,
       tuple_binary(
         @coordinates_projection_domain,
         [u32(@normalization_version), u32(length(entries))] ++ entries
       )}
    end
  end

  defp assertion_refs_projection(assertions) do
    with {:ok, entries} <-
           map_ok(assertions, fn assertion ->
             with {:ok, key} <- digest(assertion["assertion_key"]),
                  {:ok, fingerprint} <- optional_digest_bytes(assertion["statement_fingerprint"]),
                  {:ok, set_ref} <- optional_uuid_bytes(assertion["product_set_ref"]),
                  {:ok, set_digest} <- optional_digest_bytes(assertion["product_set_digest"]) do
               {:ok,
                tuple_binary(@assertion_ref_projection_domain, [
                  u32(@normalization_version),
                  key,
                  fingerprint,
                  set_ref,
                  set_digest
                ])}
             end
           end) do
      entries = Enum.sort(entries)

      {:ok,
       tuple_binary(
         @assertion_refs_projection_domain,
         [u32(@normalization_version), u32(length(entries))] ++ entries
       )}
    end
  end

  defp loader_advisory(advisory, provenance, projection_digest, provider, feed_key) do
    metadata = %{
      "normalization_version" => @normalization_version,
      "projection_digest" => projection_digest,
      "osv_withdrawn" => provenance["osv_withdrawn"],
      "vex_empty_statements_tombstone" => provenance["vex_empty_statements_tombstone"]
    }

    metadata =
      if is_binary(advisory["withdrawn_at"]),
        do: Map.put(metadata, "withdrawn_at", advisory["withdrawn_at"]),
        else: metadata

    %{
      provider: provider,
      feed_key: feed_key,
      source_object_id: advisory["source_object_id"],
      advisory_id: advisory["advisory_id"],
      cve_id: advisory["cve_id"],
      title: advisory["title"],
      description: optional_value(advisory["description"]),
      severity: optional_value(advisory["severity"]),
      cvss_score: nil,
      cvss_vector: optional_value(advisory["cvss_vector"]),
      published_at: optional_value(advisory["published_at"]),
      modified_at: optional_value(advisory["modified_at"]),
      kev: false,
      exploit_available: false,
      references: advisory["references"],
      raw: %{"projection_provenance" => provenance},
      metadata: metadata
    }
  end

  defp canonical_ubuntu_purl(value, opts \\ [])

  defp canonical_ubuntu_purl(value, opts)
       when is_binary(value) and byte_size(value) <= @max_purl_bytes do
    require_version? = Keyword.get(opts, :require_version?, true)

    with {:ok, parsed} <- PackageUrl.parse(value),
         :ok <- equal(parsed.type, "deb", :purl_type),
         :ok <- equal(parsed.namespace, ["ubuntu"], :purl_namespace),
         :ok <-
           condition(
             not require_version? or (is_binary(parsed.version) and parsed.version != ""),
             :purl_version
           ),
         :ok <- equal(parsed.subpath, nil, :purl_subpath),
         :ok <- string_map(parsed.qualifiers, :purl_qualifiers),
         :ok <- condition(map_size(parsed.qualifiers) <= @max_qualifiers, :purl_qualifier_count),
         :ok <- equal(PackageUrl.canonical(parsed), value, :canonical_purl) do
      {:ok, parsed}
    else
      :error -> {:error, :invalid_purl}
      {:error, _} = error -> error
    end
  end

  defp canonical_ubuntu_purl(_, _opts), do: {:error, :invalid_purl}

  defp validate_known_index(index, label) do
    each(index, fn {id, digest_value} ->
      with {:ok, _} <- uuid(id),
           {:ok, _} <- digest(digest_value) do
        :ok
      else
        _ -> {:error, label}
      end
    end)
  end

  defp reject_collisions(left, right, label) do
    each(left, fn {id, digest_value} ->
      case Map.fetch(right, id) do
        :error -> :ok
        {:ok, ^digest_value} -> :ok
        {:ok, _} -> {:error, label}
      end
    end)
  end

  defp exact_shape(map, required, optional) when is_map(map) do
    keys = Map.keys(map)
    allowed = MapSet.new(required ++ optional)

    with :ok <-
           condition(
             Enum.all?(required, &Map.has_key?(map, &1)),
             {:missing_keys, required -- keys}
           ) do
      condition(
        Enum.all?(keys, &MapSet.member?(allowed, &1)),
        {:unknown_keys, keys -- MapSet.to_list(allowed)}
      )
    end
  end

  defp exact_shape(_, _, _), do: {:error, :expected_object}

  defp map_ok(values, function) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case function.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      error -> error
    end
  end

  defp each(values, function) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case function.(value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp sorted_unique_by(values, function, label) when is_list(values) do
    projected = Enum.map(values, function)

    with :ok <- condition(Enum.all?(projected, &is_binary/1), label),
         :ok <- equal(projected, Enum.sort(projected), label) do
      condition(length(projected) == MapSet.size(MapSet.new(projected)), label)
    end
  end

  defp sorted_unique_by(_, _, label), do: {:error, label}

  defp sorted_unique(values, label) do
    with :ok <- equal(values, Enum.sort(values), label) do
      condition(length(values) == MapSet.size(MapSet.new(values)), label)
    end
  end

  defp string_map(value, label) when is_map(value) do
    condition(
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and key != "" and String.downcase(key) == key and is_binary(item) and
          item != "" and not String.contains?(key, <<0>>) and not String.contains?(item, <<0>>)
      end),
      label
    )
  end

  defp string_map(_, label), do: {:error, label}

  defp bounded_map(value, cap, label) when is_map(value) do
    condition(byte_size(Jason.encode!(value)) <= cap, label)
  rescue
    _ -> {:error, label}
  end

  defp bounded_map(_, _, label), do: {:error, label}

  defp cve(value) when is_binary(value) do
    if Regex.match?(@cve, value), do: {:ok, value}, else: {:error, :cve_id}
  end

  defp cve(_), do: {:error, :cve_id}

  defp digest(value) when is_binary(value) do
    if Regex.match?(@sha256, value) do
      {:ok, Base.decode16!(value, case: :lower)}
    else
      {:error, :sha256}
    end
  end

  defp digest(_), do: {:error, :sha256}

  defp optional_digest_bytes(nil), do: {:ok, nil}
  defp optional_digest_bytes(""), do: {:ok, nil}
  defp optional_digest_bytes(value), do: digest(value)

  defp uuid(value) when is_binary(value) do
    if Regex.match?(@uuid_v8, value) do
      {:ok, value |> String.replace("-", "") |> Base.decode16!(case: :lower)}
    else
      {:error, :uuid}
    end
  end

  defp uuid(_), do: {:error, :uuid}

  defp optional_uuid_bytes(nil), do: {:ok, nil}
  defp optional_uuid_bytes(""), do: {:ok, nil}
  defp optional_uuid_bytes(value), do: uuid(value)

  defp optional_uuid(nil, _), do: :ok
  defp optional_uuid("", _), do: :ok

  defp optional_uuid(value, label) do
    case uuid(value) do
      {:ok, _} -> :ok
      _ -> {:error, label}
    end
  end

  defp present_text(value, cap, label) when is_binary(value) do
    condition(
      value != "" and byte_size(value) <= cap and not String.contains?(value, <<0>>),
      label
    )
  end

  defp present_text(_, _, label), do: {:error, label}

  defp optional_text(nil, _, _), do: :ok
  defp optional_text("", _, label), do: {:error, label}
  defp optional_text(value, cap, label), do: present_text(value, cap, label)

  defp timestamp(value, label) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> equal(DateTime.to_iso8601(datetime), value, label)
      _ -> {:error, label}
    end
  end

  defp timestamp(_, label), do: {:error, label}
  defp optional_timestamp(nil, _), do: :ok
  defp optional_timestamp(value, label), do: timestamp(value, label)

  defp positive_integer(value, _label) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_, label), do: {:error, label}

  defp optional_positive_integer(nil, _), do: :ok
  defp optional_positive_integer(value, label), do: positive_integer(value, label)

  defp nonnegative_integer(value, _label) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative_integer(_, label), do: {:error, label}

  defp boolean(value, _label) when is_boolean(value), do: :ok
  defp boolean(_, label), do: {:error, label}

  defp optional_boolean(nil, _), do: :ok
  defp optional_boolean(value, label), do: boolean(value, label)

  defp empty_versions(nil), do: :ok
  defp empty_versions([]), do: :ok
  defp empty_versions(_), do: {:error, :affected_versions}

  defp all_absent(map, keys) do
    condition(Enum.all?(keys, &(optional_value(map[&1]) == nil)), :unexpected_assertion_scope)
  end

  defp required_digest_if(true, value, _label) do
    case digest(value) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp required_digest_if(false, nil, _), do: :ok
  defp required_digest_if(false, _, label), do: {:error, label}

  defp equal_if_present(nil, _actual, _label), do: :ok
  defp equal_if_present(expected, actual, label), do: equal(expected, actual, label)

  defp equal(value, value, _label), do: :ok
  defp equal(_, _, label), do: {:error, label}

  defp condition(true, _label), do: :ok
  defp condition(false, label), do: {:error, label}

  defp at_least_one(true, _), do: :ok
  defp at_least_one(_, true), do: :ok
  defp at_least_one(_, _), do: {:error, :missing_source_document}

  defp less_than_or_equal(left, right, label), do: condition(left <= right, label)
  defp length_or_invalid(value) when is_list(value), do: length(value)
  defp length_or_invalid(_), do: :invalid
  defp bool_count(true), do: 1
  defp bool_count(false), do: 0
  defp optional_value(nil), do: nil
  defp optional_value(""), do: nil
  defp optional_value(value), do: value
  defp optional_field(value), do: optional_value(value)
  defp first_present(left, right), do: optional_value(left) || optional_value(right)

  defp encode_string_map(values) when is_map(values) do
    with :ok <- string_map(values, :canonical_map) do
      encoded =
        values
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {key, value} -> [canonical_field(key), canonical_field(value)] end)

      {:ok, IO.iodata_to_binary([u32(map_size(values)), encoded])}
    end
  end

  defp encode_string_list(values) do
    IO.iodata_to_binary([u32(length(values)), Enum.map(values, &canonical_field/1)])
  end

  defp tuple_digest(domain, fields), do: :crypto.hash(:sha256, tuple_binary(domain, fields))

  defp tuple_binary(domain, fields) do
    IO.iodata_to_binary([
      canonical_field(domain),
      u32(length(fields)),
      Enum.map(fields, &canonical_field/1)
    ])
  end

  defp canonical_field(nil), do: <<0xFFFFFFFF::32-big>>
  defp canonical_field(value) when is_binary(value), do: [u32(byte_size(value)), value]
  defp u32(value), do: <<value::32-big-unsigned>>
  defp u64(value), do: <<value::64-big-unsigned>>
  defp u64_zero(value), do: u64(value)
  defp optional_u64(nil), do: nil
  defp optional_u64(value), do: u64(value)
  defp bool_field(true), do: <<1>>
  defp bool_field(false), do: <<0>>

  defp uuid_from_digest(<<prefix::binary-size(16), _::binary>>) do
    <<head::binary-size(6), seventh, eighth, ninth, rest::binary-size(7)>> = prefix

    shaped =
      <<head::binary, Bitwise.bor(Bitwise.band(seventh, 0x0F), 0x80), eighth,
        Bitwise.bor(Bitwise.band(ninth, 0x3F), 0x80), rest::binary>>

    encoded = Base.encode16(shaped, case: :lower)

    Enum.join(
      [
        binary_part(encoded, 0, 8),
        binary_part(encoded, 8, 4),
        binary_part(encoded, 12, 4),
        binary_part(encoded, 16, 4),
        binary_part(encoded, 20, 12)
      ],
      "-"
    )
  end

  defp hex(value), do: Base.encode16(value, case: :lower)
end
