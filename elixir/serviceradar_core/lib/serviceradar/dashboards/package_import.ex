defmodule ServiceRadar.Dashboards.PackageImport do
  @moduledoc """
  Builds dashboard package attributes from a validated JSON manifest.

  This module is intentionally pure so Git source sync, manual upload, and tests
  can share the same normalization path before calling Ash create/update actions.
  """

  alias ServiceRadar.Dashboards.Manifest

  @type import_opts :: [
          wasm_object_key: String.t(),
          content_hash: String.t(),
          signature: map(),
          source_type: atom() | String.t(),
          source_repo_url: String.t(),
          source_ref: String.t(),
          source_manifest_path: String.t(),
          source_commit: String.t(),
          source_bundle_digest: String.t(),
          source_metadata: map(),
          imported_at: DateTime.t(),
          verification_status: String.t(),
          verification_error: String.t(),
          pack_id: String.t(),
          pack_version: String.t(),
          managed: boolean(),
          template_fingerprint: String.t(),
          status: atom() | String.t()
        ]

  @spec attrs_from_json(binary(), import_opts()) :: {:ok, map()} | {:error, [String.t()]}
  def attrs_from_json(json, opts \\ []) when is_binary(json) do
    with {:ok, manifest} <- Manifest.from_json(json) do
      attrs_from_manifest(manifest, opts)
    end
  end

  @spec attrs_from_manifest(Manifest.t(), import_opts()) :: {:ok, map()}
  def attrs_from_manifest(%Manifest{} = manifest, opts \\ []) do
    renderer_sha = manifest.renderer["sha256"]
    content_hash = option(opts, :content_hash) || renderer_sha

    attrs =
      %{
        dashboard_id: manifest.id,
        name: manifest.name,
        version: manifest.version,
        description: manifest.description,
        vendor: manifest.vendor,
        manifest: manifest_to_map(manifest),
        renderer: manifest.renderer,
        data_frames: manifest.data_frames,
        capabilities: manifest.capabilities,
        settings_schema: manifest.settings_schema,
        wasm_object_key: option(opts, :wasm_object_key),
        content_hash: content_hash,
        signature: option(opts, :signature) || %{},
        source_type: normalize_source_type(option(opts, :source_type)),
        source_repo_url: option(opts, :source_repo_url),
        source_ref: option(opts, :source_ref),
        source_manifest_path: option(opts, :source_manifest_path),
        source_commit: option(opts, :source_commit),
        source_bundle_digest: option(opts, :source_bundle_digest),
        source_metadata: option(opts, :source_metadata) || manifest.source || %{},
        imported_at: option(opts, :imported_at) || DateTime.utc_now(),
        verification_status: option(opts, :verification_status) || "pending",
        verification_error: option(opts, :verification_error)
      }
      |> maybe_put_opt(:pack_id, option(opts, :pack_id))
      |> maybe_put_opt(:pack_version, option(opts, :pack_version))
      |> maybe_put_boolean(:managed, option(opts, :managed))
      |> maybe_put_opt(:template_fingerprint, option(opts, :template_fingerprint))
      |> maybe_put_opt(:status, normalize_status(option(opts, :status)))

    {:ok, attrs}
  end

  @spec verify_artifact_digest(binary(), Manifest.t() | map()) :: :ok | {:error, :digest_mismatch}
  def verify_artifact_digest(bytes, %Manifest{} = manifest) when is_binary(bytes) do
    verify_artifact_digest(bytes, manifest.renderer)
  end

  def verify_artifact_digest(bytes, %{} = renderer) when is_binary(bytes) do
    expected = renderer["sha256"] || renderer[:sha256]
    actual = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    if String.downcase(to_string(expected || "")) == actual do
      :ok
    else
      {:error, :digest_mismatch}
    end
  end

  defp manifest_to_map(%Manifest{} = manifest) do
    %{
      "schema_version" => manifest.schema_version,
      "id" => manifest.id,
      "name" => manifest.name,
      "version" => manifest.version,
      "description" => manifest.description,
      "vendor" => manifest.vendor,
      "renderer" => manifest.renderer,
      "data_frames" => manifest.data_frames,
      "capabilities" => manifest.capabilities,
      "settings_schema" => manifest.settings_schema,
      "source" => manifest.source
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_source_type(nil), do: :upload
  defp normalize_source_type(value) when value in [:upload, :git, :first_party], do: value

  defp normalize_source_type(value) when value in ["upload", "git", "first_party"],
    do: String.to_existing_atom(value)

  defp normalize_source_type(value) when value in [:builtin, "builtin"], do: :first_party

  defp normalize_source_type(value)
       when value in [:gitops_tree, "gitops_tree", :gitops, "gitops"], do: :git

  defp normalize_source_type(value) when value in [:release_catalog, "release_catalog"],
    do: :upload

  defp normalize_source_type(_value), do: :upload

  defp normalize_status(nil), do: nil
  defp normalize_status(value) when value in [:staged, :enabled, :disabled, :revoked], do: value

  defp normalize_status(value) when value in ["staged", "enabled", "disabled", "revoked"],
    do: String.to_existing_atom(value)

  defp normalize_status(_value), do: nil

  defp maybe_put_opt(attrs, _key, nil), do: attrs
  defp maybe_put_opt(attrs, key, val), do: Map.put(attrs, key, val)

  defp maybe_put_boolean(attrs, _key, nil), do: attrs
  defp maybe_put_boolean(attrs, key, val) when is_boolean(val), do: Map.put(attrs, key, val)
  defp maybe_put_boolean(attrs, _key, _val), do: attrs

  defp option(opts, key), do: Keyword.get(opts, key)
end
