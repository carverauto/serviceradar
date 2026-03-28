defmodule ServiceRadar.Edge.ReleaseManifestValidator do
  @moduledoc """
  Validates signed agent release metadata before it is stored in the catalog.
  """

  @release_public_key_env "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY"
  @required_artifact_fields ~w(url sha256 os arch)

  @type field_error :: %{field: atom(), message: String.t()}

  @spec validate(String.t() | nil, map() | nil, String.t() | nil) ::
          :ok | {:error, [field_error()]}
  def validate(version, manifest, signature) do
    normalized_version = normalize_string(version)
    normalized_manifest = normalize_keys(manifest || %{})
    normalized_signature = normalize_string(signature)

    errors =
      []
      |> validate_manifest_version(normalized_manifest, normalized_version)
      |> validate_manifest_artifacts(normalized_manifest)

    if errors == [] do
      validate_manifest_signature(normalized_manifest, normalized_signature)
    else
      {:error, errors}
    end
  end

  @spec add_publish_errors(Ash.Changeset.t()) :: Ash.Changeset.t()
  def add_publish_errors(changeset) do
    version = Ash.Changeset.get_attribute(changeset, :version)
    manifest = Ash.Changeset.get_attribute(changeset, :manifest)
    signature = Ash.Changeset.get_attribute(changeset, :signature)

    case validate(version, manifest, signature) do
      :ok ->
        changeset

      {:error, errors} ->
        Enum.reduce(errors, changeset, fn %{field: field, message: message}, acc ->
          Ash.Changeset.add_error(acc, field: field, message: message)
        end)
    end
  end

  @spec canonical_json(map()) :: {:ok, binary()} | {:error, term()}
  def canonical_json(value) when is_map(value) do
    {:ok, value |> normalize_keys() |> write_canonical_json()}
  rescue
    error -> {:error, error}
  end

  def canonical_json(_value), do: {:error, :manifest_must_be_a_map}

  defp validate_manifest_version(errors, manifest, version) do
    manifest_version = normalize_string(manifest["version"])

    cond do
      manifest_version == "" ->
        [%{field: :manifest, message: "release manifest must include a version"} | errors]

      version != "" and manifest_version != version ->
        [
          %{
            field: :manifest,
            message:
              "release manifest version #{inspect(manifest_version)} does not match release version #{inspect(version)}"
          }
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_manifest_artifacts(errors, manifest) do
    artifacts = List.wrap(manifest["artifacts"])

    if artifacts == [] do
      [
        %{field: :manifest, message: "release manifest must include at least one artifact"}
        | errors
      ]
    else
      artifacts
      |> Enum.with_index(1)
      |> Enum.reduce(errors, fn {artifact, index}, acc ->
        validate_artifact(acc, artifact, index)
      end)
    end
  end

  defp validate_artifact(errors, artifact, index) when is_map(artifact) do
    artifact = normalize_keys(artifact)

    errors =
      Enum.reduce(@required_artifact_fields, errors, fn field, acc ->
        value = normalize_string(artifact[field])

        if value == "" do
          [%{field: :manifest, message: "release artifact #{index} must include #{field}"} | acc]
        else
          acc
        end
      end)

    case normalize_string(artifact["url"]) do
      "" ->
        errors

      url ->
        case URI.parse(url) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
            errors

          _ ->
            [
              %{field: :manifest, message: "release artifact #{index} url must use https"}
              | errors
            ]
        end
    end
  end

  defp validate_artifact(errors, _artifact, index) do
    [%{field: :manifest, message: "release artifact #{index} must be an object"} | errors]
  end

  defp validate_manifest_signature(manifest, signature) do
    with {:ok, public_key} <- release_public_key(),
         {:ok, manifest_json} <- canonical_json(manifest),
         {:ok, signature_bytes} <- decode_signature(signature),
         true <-
           :crypto.verify(:eddsa, :none, manifest_json, signature_bytes, [public_key, :ed25519]) do
      :ok
    else
      false ->
        {:error,
         [%{field: :signature, message: "release manifest signature verification failed"}]}

      {:error, :signature_missing} ->
        {:error, [%{field: :signature, message: "release signature is required"}]}

      {:error, :verification_key_missing} ->
        {:error,
         [
           %{
             field: :signature,
             message: "release signing public key is not configured"
           }
         ]}

      {:error, :verification_key_invalid} ->
        {:error,
         [
           %{
             field: :signature,
             message: "release signing public key is invalid"
           }
         ]}

      {:error, :signature_invalid} ->
        {:error,
         [
           %{
             field: :signature,
             message: "release signature encoding is invalid"
           }
         ]}

      {:error, reason} ->
        {:error,
         [
           %{
             field: :signature,
             message: "release signature validation failed: #{inspect(reason)}"
           }
         ]}
    end
  end

  defp release_public_key do
    key_value =
      System.get_env(@release_public_key_env) ||
        Application.get_env(:serviceradar_core, :agent_release_public_key)

    case decode_signature(key_value) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      {:ok, _key} -> {:error, :verification_key_invalid}
      {:error, :signature_missing} -> {:error, :verification_key_missing}
      {:error, _reason} -> {:error, :verification_key_invalid}
    end
  end

  defp decode_signature(value) do
    clean = normalize_string(value)

    if clean == "" do
      {:error, :signature_missing}
    else
      decode_signature_variants(clean)
    end
  end

  defp decode_signature_variants(value) do
    decoders = [
      &Base.decode16(&1, case: :mixed),
      &Base.decode64/1,
      &Base.decode64(&1, padding: false),
      &Base.url_decode64/1,
      &Base.url_decode64(&1, padding: false)
    ]

    Enum.find_value(decoders, {:error, :signature_invalid}, fn decoder ->
      case decoder.(value) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> nil
      end
    end)
  end

  defp write_canonical_json(value) when is_map(value) do
    inner =
      value
      |> Enum.map(fn {key, entry} -> {normalize_key(key), entry} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, entry} ->
        Jason.encode!(key) <> ":" <> write_canonical_json(entry)
      end)

    "{" <> inner <> "}"
  end

  defp write_canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &write_canonical_json/1) <> "]"
  end

  defp write_canonical_json(value), do: Jason.encode!(value)

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized_value =
        cond do
          is_map(value) -> normalize_keys(value)
          is_list(value) -> Enum.map(value, &normalize_nested_value/1)
          true -> value
        end

      {normalize_key(key), normalized_value}
    end)
  end

  defp normalize_keys(other), do: other

  defp normalize_nested_value(value) when is_map(value), do: normalize_keys(value)

  defp normalize_nested_value(value) when is_list(value),
    do: Enum.map(value, &normalize_nested_value/1)

  defp normalize_nested_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp normalize_string(nil), do: ""
  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value), do: value |> to_string() |> String.trim()
end
