defmodule ServiceRadar.Plugins.NativeAddonImporter do
  @moduledoc """
  Verify-then-mirror importer for native add-on packages (issue 3425,
  add-native-addon-build-signing §4).

  Consumes the `serviceradar-native-addon-index.json` entry + the add-on's
  `addon.yaml` manifest (already fetched and Cosign-verified by the web-ng OCI
  fetch layer, mirroring the WASM `FirstPartyImporter`), then, per architecture:

    1. checks the tarball sha256 against the index/metadata,
    2. verifies the raw ed25519 signature over the tarball bytes against the agent
       release public key — exactly the signature the agent verifies on fetch
       (`verifyAddonArtifactSignature`), so a tarball the control plane accepts is
       one the agent will accept,
    3. mirrors the tarball into ServiceRadar object storage via the injected
       `:mirror` function,

  and records the resolved per-arch `{object_key, sha256, signature,
  signature_digest}` on a staged
  `AddonPackage`. `AgentConfigGenerator.select_addon_artifact/3` reads that
  `artifacts` map back out (keyed `"os/arch"`) when compiling the agent assignment.

  The OCI fetch, Cosign verification, and object-storage upload are injected so the
  pure verification + persistence logic is testable without a registry or DB.
  """

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.ProducerScheduleCatalog
  alias ServiceRadar.Plugins.RetiredNativeAddons

  require Ash.Query

  @artifact_media_type "application/vnd.serviceradar.native-addon.artifact.v1+gzip"
  @artifact_signature_media_type "application/vnd.serviceradar.native-addon.artifact-signature.v1+hex"

  @valid_kinds %{"native" => :native}
  @valid_delivery %{
    "compiled-in" => :compiled_in,
    "pushed-artifact" => :pushed_artifact,
    "os-package" => :os_package
  }
  @valid_supervision %{
    "config-toggle" => :config_toggle,
    "agent-sidecar" => :agent_sidecar,
    "systemd-service" => :systemd_service,
    "systemd-timer" => :systemd_timer,
    "ephemeral-helper" => :ephemeral_helper
  }
  @immutable_package_content_fields [
    :name,
    :description,
    :kind,
    :delivery,
    :supervision,
    :binary,
    :install_path,
    :capabilities,
    :config_schema,
    :display_contracts,
    :signal_schemas,
    :producer_schedules,
    :artifacts,
    :requires,
    :resources
  ]

  @doc "The OCI layer media types the per-arch artifact + its signature are carried under."
  def artifact_media_type, do: @artifact_media_type
  def artifact_signature_media_type, do: @artifact_signature_media_type

  @typedoc """
  A per-arch artifact ready to verify + mirror: the raw tarball bytes, the hex
  ed25519 signature over those bytes, the signature layer digest, and the expected
  sha256 (hex). os/arch come from the index entry.
  """
  @type fetched_artifact :: %{
          required(:os) => String.t(),
          required(:arch) => String.t(),
          required(:tarball) => binary(),
          required(:signature) => String.t(),
          optional(:signature_digest) => String.t(),
          required(:sha256) => String.t()
        }

  @type import_disposition :: :created | :reused | :repaired

  @doc """
  Import one native add-on into a staged `AddonPackage`.

  `manifest` is the parsed `addon.yaml` map; `entry` is the index entry (for the
  source OCI ref/digest + release tag); `artifacts` is the list of per-arch
  `t:fetched_artifact/0` (already Cosign-verified at the bundle level by the caller).

  Options:
    * `:public_key` — the agent release ed25519 public key (raw 32 bytes). Required.
    * `:mirror` — `(os, arch, tarball_bytes -> {:ok, object_key} | {:error, term})`. Required.
    * `:actor` — the Ash actor creating the package (a `ServiceRadar.Actors.SystemActor`
      for background callers; never `authorize?: false`). Required.
    * `:config_schema` — the add-on config JSON Schema map (from the bundle). Default `%{}`.
    * `:display_contracts` — the add-on's validated display contracts, keyed by
      `"<contract_id>@<contract_version>"` (from the bundle). Default `%{}`.
    * `:display_contract_errors` — reasons any bundled contract was refused, recorded
      in `source_metadata`. Default `[]`.
    * `:release_tag` — the source release tag. Default `nil`.
    * `:now` — import timestamp. Default `DateTime.utc_now/0`.
    * `:replace_existing` — when true, an operator-initiated replace may restage
      the existing first-party `addon_id` + `version` onto a later signed
      bundle. Default false: same-version source drift is a conflict.
  """
  @spec import_entry(map(), map(), [fetched_artifact()], keyword()) ::
          {:ok, AddonPackage.t()} | {:error, term()}
  def import_entry(manifest, entry, artifacts, opts)
      when is_map(manifest) and is_map(entry) and is_list(artifacts) do
    with {:ok, package, _disposition} <-
           import_entry_with_disposition(manifest, entry, artifacts, opts) do
      {:ok, package}
    end
  end

  @doc "Import one native add-on and report whether persistence created, reused, or repaired the row."
  @spec import_entry_with_disposition(map(), map(), [fetched_artifact()], keyword()) ::
          {:ok, AddonPackage.t(), import_disposition()} | {:error, term()}
  def import_entry_with_disposition(manifest, entry, artifacts, opts)
      when is_map(manifest) and is_map(entry) and is_list(artifacts) do
    public_key = Keyword.fetch!(opts, :public_key)
    mirror = Keyword.fetch!(opts, :mirror)
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- ensure_entry_identity(manifest, entry),
         :ok <- ensure_not_retired_native_addon(manifest, entry),
         {:ok, mirrored} <- verify_and_mirror(artifacts, public_key, mirror),
         {:ok, attrs} <- package_attrs(manifest, entry, mirrored, opts) do
      upsert_package(attrs, actor, opts)
    end
  end

  defp upsert_package(%{addon_id: addon_id, version: version} = attrs, actor, opts) do
    case find_package(addon_id, version, actor) do
      {:ok, nil} ->
        case create_package(attrs, actor) do
          {:ok, %AddonPackage{} = package} ->
            {:ok, package, :created}

          {:error, create_error} ->
            reconcile_after_create_error(attrs, actor, create_error, opts)
        end

      {:ok, %AddonPackage{} = package} ->
        reconcile_package(package, attrs, actor, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp create_package(attrs, actor) do
    AddonPackage
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create()
  end

  defp reconcile_after_create_error(
         %{addon_id: addon_id, version: version} = attrs,
         actor,
         create_error,
         opts
       ) do
    case find_package(addon_id, version, actor) do
      {:ok, %AddonPackage{} = package} -> reconcile_package(package, attrs, actor, opts)
      {:ok, nil} -> {:error, create_error}
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_package(%AddonPackage{} = package, attrs, actor, opts) do
    cond do
      package.source_type != :first_party ->
        {:error, source_conflict(package, attrs, :source_type_owned)}

      verified_package_content_matches?(package, attrs) and
        source_provenance_complete?(package) and source_provenance_complete?(attrs) and
          source_bundle_digests_match?(package, attrs) ->
        {:ok, package, :reused}

      source_disagrees?(package, attrs) and not replace_existing?(opts) ->
        {:error, source_conflict(package, attrs, :oci_source_mismatch)}

      true ->
        with {:ok, updated} <-
               package
               |> Ash.Changeset.for_update(:reimport, Map.drop(attrs, [:addon_id, :version]),
                 actor: actor
               )
               |> Ash.update(),
             :ok <- ProducerScheduleCatalog.sync_package(updated, actor: actor) do
          {:ok, updated, :repaired}
        end
    end
  end

  # OCI manifest references are release provenance, not package content. A later
  # signed release can re-wrap the exact same bundle and artifact layers under a
  # new manifest digest. We retain the original provenance row in that case, but
  # only after every manifest-derived field and verified artifact contract agrees.
  defp verified_package_content_matches?(package, attrs) do
    package.verification_status == "verified" and is_nil(package.verification_error) and
      Map.take(Map.from_struct(package), @immutable_package_content_fields) ==
        Map.take(attrs, @immutable_package_content_fields)
  end

  defp source_provenance_complete?(source) do
    is_binary(normalize_source(source.source_oci_ref)) and
      is_binary(normalize_digest(source.source_oci_digest))
  end

  # The OCI manifest digest names an envelope, while the bundle digest names the
  # actual signed add-on payload. Both must be present and equal before a package
  # can survive a later OCI envelope change without a new package version.
  # Legacy rows without a recorded bundle digest deliberately fail this check: a
  # release must publish a new version rather than retroactively asserting which
  # bytes an already-approved package contained.
  defp source_bundle_digests_match?(package, attrs) do
    with digest when is_binary(digest) <- source_bundle_digest(package),
         ^digest <- source_bundle_digest(attrs) do
      true
    else
      _ -> false
    end
  end

  defp source_bundle_digest(%{source_metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("bundle_digest", Map.get(metadata, :bundle_digest))
    |> normalize_bundle_digest()
  end

  defp source_bundle_digest(_source), do: nil

  defp normalize_bundle_digest(value) when is_binary(value) do
    case value |> String.downcase() |> String.trim() do
      "sha256:" <> hash = digest when byte_size(hash) == 64 ->
        if String.match?(hash, ~r/\A[0-9a-f]{64}\z/), do: digest

      _ ->
        nil
    end
  end

  defp normalize_bundle_digest(_value), do: nil

  defp source_disagrees?(package, attrs) do
    populated_source_disagrees?(
      package.source_oci_ref,
      attrs.source_oci_ref,
      &normalize_source/1
    ) or
      populated_source_disagrees?(
        package.source_oci_digest,
        attrs.source_oci_digest,
        &normalize_digest/1
      )
  end

  defp populated_source_disagrees?(existing, discovered, normalize) do
    case normalize.(existing) do
      nil -> false
      normalized_existing -> normalized_existing != normalize.(discovered)
    end
  end

  defp replace_existing?(opts), do: Keyword.get(opts, :replace_existing, false) == true

  defp source_conflict(package, attrs, reason) do
    {:native_addon_version_source_conflict,
     %{
       reason: reason,
       addon_id: attrs.addon_id,
       version: attrs.version,
       existing_source_type: package.source_type,
       existing_oci_ref: package.source_oci_ref,
       existing_oci_digest: package.source_oci_digest,
       discovered_oci_ref: attrs.source_oci_ref,
       discovered_oci_digest: attrs.source_oci_digest,
       existing_bundle_digest: source_bundle_digest(package),
       discovered_bundle_digest: source_bundle_digest(attrs)
     }}
  end

  defp normalize_source(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_source(_value), do: nil

  defp normalize_digest(value) when is_binary(value) do
    value
    |> String.downcase()
    |> normalize_source()
  end

  defp normalize_digest(_value), do: nil

  defp find_package(addon_id, version, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == ^addon_id and version == ^version)
    |> Ash.read_one(actor: actor)
  end

  @doc """
  Verify each per-arch artifact (sha256 + ed25519 over the raw tarball) and mirror
  it, returning the `artifacts` map keyed `"os/arch" => %{object_key, sha256,
  signature, signature_digest}`. Fails closed on the first verification or mirror
  error.
  """
  @spec verify_and_mirror([fetched_artifact()], binary(), function()) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def verify_and_mirror(artifacts, public_key, mirror) do
    with :ok <- ensure_unique_artifact_platforms(artifacts) do
      Enum.reduce_while(artifacts, {:ok, %{}}, fn artifact, {:ok, acc} ->
        case verify_and_mirror_one(artifact, public_key, mirror) do
          {:ok, {key, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp ensure_unique_artifact_platforms(artifacts) do
    artifacts
    |> Enum.reduce_while({:ok, MapSet.new()}, fn artifact, {:ok, seen} ->
      case normalized_artifact_platform(artifact) do
        {:ok, os, arch} ->
          platform = "#{os}/#{arch}"

          if MapSet.member?(seen, platform) do
            {:halt, {:error, {:duplicate_artifact_platform, platform}}}
          else
            {:cont, {:ok, MapSet.put(seen, platform)}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp normalized_artifact_platform(%{os: os, arch: arch}) do
    with {:ok, os} <- normalize_platform_segment(os),
         {:ok, arch} <- normalize_platform_segment(arch) do
      {:ok, os, arch}
    end
  end

  defp normalized_artifact_platform(_artifact), do: {:error, :invalid_artifact}

  defp normalize_platform_segment(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if Regex.match?(~r/\A[a-z0-9][a-z0-9._-]*\z/, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_artifact}
    end
  end

  defp normalize_platform_segment(_value), do: {:error, :invalid_artifact}

  defp verify_and_mirror_one(artifact, public_key, mirror) when is_map(artifact) do
    with {:ok, os, arch} <- normalized_artifact_platform(artifact),
         :ok <- verify_sha256(artifact.tarball, artifact.sha256),
         :ok <- verify_artifact_signature(artifact.tarball, artifact.signature, public_key),
         :ok <- verify_signature_digest(artifact.signature, Map.get(artifact, :signature_digest)),
         {:ok, object_key} <- mirror.(os, arch, artifact.tarball) do
      persisted = %{
        "object_key" => object_key,
        "sha256" => String.downcase(artifact.sha256),
        "signature" => artifact.signature
      }

      persisted =
        case Map.get(artifact, :signature_digest) do
          value when is_binary(value) ->
            Map.put(persisted, "signature_digest", String.downcase(value))

          _ ->
            persisted
        end

      {:ok, {"#{os}/#{arch}", persisted}}
    end
  end

  defp verify_and_mirror_one(_artifact, _public_key, _mirror), do: {:error, :invalid_artifact}

  @doc "sha256(tarball) must equal the expected hex digest (case-insensitive)."
  @spec verify_sha256(binary(), String.t()) :: :ok | {:error, :sha256_mismatch}
  def verify_sha256(data, expected) when is_binary(data) and is_binary(expected) do
    actual = :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

    # A content digest, not a secret; a plain compare is fine (ed25519 over the same
    # bytes is the real integrity gate in verify_artifact_signature/3).
    if actual == String.downcase(String.trim(expected)) do
      :ok
    else
      {:error, :sha256_mismatch}
    end
  end

  @doc """
  Verify a raw ed25519 signature (hex or base64) over the tarball bytes against the
  agent release public key — the agent's exact check.
  """
  @spec verify_artifact_signature(binary(), String.t(), binary()) ::
          :ok | {:error, :invalid_signature | :malformed_signature}
  def verify_artifact_signature(data, signature, public_key)
      when is_binary(data) and is_binary(signature) and is_binary(public_key) do
    case decode_key_or_signature(signature) do
      {:ok, sig} when byte_size(sig) == 64 ->
        if :crypto.verify(:eddsa, :none, data, sig, [public_key, :ed25519]) do
          :ok
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :malformed_signature}
    end
  end

  defp verify_signature_digest(_signature, nil), do: :ok

  defp verify_signature_digest(signature, expected)
       when is_binary(signature) and is_binary(expected) do
    actual =
      "sha256:" <>
        (:sha256 |> :crypto.hash(String.trim(signature) <> "\n") |> Base.encode16(case: :lower))

    if actual == String.downcase(String.trim(expected)) do
      :ok
    else
      {:error, :signature_digest_mismatch}
    end
  end

  defp verify_signature_digest(_signature, _expected), do: {:error, :signature_digest_mismatch}

  @doc """
  Decode a key or signature accepting the same encodings the agent accepts: hex
  first, then standard/url base64 (padded or raw).
  """
  @spec decode_key_or_signature(String.t()) :: {:ok, binary()} | :error
  def decode_key_or_signature(value) when is_binary(value) do
    clean = String.trim(value)

    with :error <- decode_hex(clean),
         :error <- Base.decode64(clean),
         :error <- Base.decode64(clean, padding: false),
         :error <- Base.url_decode64(clean),
         :error <- Base.url_decode64(clean, padding: false) do
      :error
    else
      {:ok, _bytes} = ok -> ok
      bytes when is_binary(bytes) -> {:ok, bytes}
    end
  end

  defp decode_hex(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  @doc """
  Build the `AddonPackage` create attrs from the manifest, index entry, and the
  per-arch artifacts map. Pure; the kind/delivery/supervision strings are mapped to
  the resource's atoms (unknown values fail closed).
  """
  @spec package_attrs(map(), map(), %{String.t() => map()}, keyword()) ::
          {:ok, map()} | {:error, term()}
  def package_attrs(manifest, entry, artifacts, opts \\ []) do
    requires = Map.get(manifest, "requires", %{})
    exec = Map.get(manifest, "exec", %{})
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with {:ok, kind} <- map_enum(@valid_kinds, Map.get(manifest, "kind"), :kind),
         {:ok, delivery} <- map_enum(@valid_delivery, Map.get(manifest, "delivery"), :delivery),
         {:ok, supervision} <-
           map_enum(@valid_supervision, Map.get(manifest, "supervision"), :supervision) do
      {:ok,
       %{
         addon_id: string_value(manifest, "id") || string_value(entry, "addon_id"),
         version: string_value(manifest, "version") || string_value(entry, "version"),
         name: string_value(manifest, "name"),
         description: string_value(manifest, "description"),
         kind: kind,
         delivery: delivery,
         supervision: supervision,
         binary: string_value(exec, "binary"),
         install_path: string_value(exec, "install_path") || "/usr/local/lib/serviceradar/bin",
         capabilities: List.wrap(Map.get(manifest, "capabilities", [])),
         config_schema: Keyword.get(opts, :config_schema, %{}),
         display_contracts: Keyword.get(opts, :display_contracts) || %{},
         signal_schemas: List.wrap(Map.get(manifest, "signal_schemas", [])),
         producer_schedules: List.wrap(Map.get(manifest, "producer_schedules", [])),
         artifacts: artifacts,
         requires: requires,
         resources: Map.get(manifest, "resources", %{}),
         source_type: :first_party,
         source_oci_ref: string_value(entry, "oci_ref"),
         source_oci_digest: string_value(entry, "oci_digest"),
         source_metadata:
           source_metadata(entry, Keyword.get(opts, :display_contract_errors) || []),
         source_release_tag: Keyword.get(opts, :release_tag),
         imported_at: DateTime.truncate(now, :second),
         verification_status: "verified",
         verification_error: nil
       }}
    end
  end

  defp map_enum(table, value, field) do
    key = value |> to_string() |> String.trim()

    case Map.get(table, key) do
      nil -> {:error, {:invalid_enum, field, value}}
      mapped -> {:ok, mapped}
    end
  end

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  # Display contracts a bundle shipped and the current release refused. Recorded
  # on the package rather than dropped on the floor: the contract is not stored
  # (only known-good data reaches the renderer), so this is the only place an
  # operator can learn that a package tried to ship one and why it was refused.
  defp source_metadata(entry, display_contract_errors) do
    metadata =
      case string_value(entry, "bundle_digest") do
        nil -> %{}
        bundle_digest -> %{"bundle_digest" => bundle_digest}
      end

    case display_contract_errors do
      [] -> metadata
      errors -> Map.put(metadata, "display_contract_errors", errors)
    end
  end

  defp ensure_entry_identity(manifest, entry) do
    manifest_addon_id = string_value(manifest, "id")
    manifest_version = string_value(manifest, "version")
    entry_addon_id = string_value(entry, "addon_id")
    entry_version = string_value(entry, "version")

    if manifest_addon_id == entry_addon_id and manifest_version == entry_version and
         not is_nil(entry_addon_id) and not is_nil(entry_version) do
      :ok
    else
      {:error,
       {:native_addon_identity_mismatch,
        %{
          manifest_addon_id: manifest_addon_id,
          manifest_version: manifest_version,
          entry_addon_id: entry_addon_id,
          entry_version: entry_version
        }}}
    end
  end

  defp ensure_not_retired_native_addon(manifest, entry) do
    addon_id = string_value(manifest, "id") || string_value(entry, "addon_id")

    if RetiredNativeAddons.retired?(addon_id) do
      {:error, {:retired_native_addon, addon_id, RetiredNativeAddons.reason(addon_id)}}
    else
      :ok
    end
  end
end
