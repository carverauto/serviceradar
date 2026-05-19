defmodule ServiceRadar.Edge.ReleaseManifestValidator do
  @moduledoc """
  Validates signed agent release metadata before it is stored in the catalog.
  """

  alias ServiceRadar.Edge.ReleaseFetchPolicy

  @release_public_key_env "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY"
  @required_artifact_fields ~w(url sha256 os arch)
  @artifact_object_metadata_fields ~w(
    compatible_agent_versions
    checksums
    license_review
    deployment_requirements
  )
  @artifact_object_list_metadata_fields ~w(signatures sbom)
  @rdp_capabilities MapSet.new(["remote_access.rdp", "remote_access.desktop"])
  @rdp_deployment_required_strings ~w(helper install_path helper_capabilities_arg)
  @rdp_helper_ready_reason_max_bytes 256

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

    errors =
      case normalize_string(artifact["url"]) do
        "" ->
          errors

        url ->
          case ReleaseFetchPolicy.validate(url) do
            :ok ->
              errors

            _ ->
              [
                %{
                  field: :manifest,
                  message: "release artifact #{index} url must use a trusted public https host"
                }
                | errors
              ]
          end
      end

    errors
    |> validate_artifact_capabilities(artifact, index)
    |> validate_artifact_string_metadata(artifact, index, "helper_protocol_version")
    |> validate_artifact_object_metadata(artifact, index)
    |> validate_artifact_object_list_metadata(artifact, index)
    |> validate_rdp_artifact_metadata(artifact, index)
  end

  defp validate_artifact(errors, _artifact, index) do
    [%{field: :manifest, message: "release artifact #{index} must be an object"} | errors]
  end

  defp validate_artifact_capabilities(errors, artifact, index) do
    case Map.fetch(artifact, "capabilities") do
      :error ->
        errors

      {:ok, capabilities}
      when is_list(capabilities) ->
        if Enum.all?(capabilities, &non_empty_string?/1) do
          errors
        else
          [
            %{
              field: :manifest,
              message: "release artifact #{index} capabilities must contain non-empty strings"
            }
            | errors
          ]
        end

      {:ok, _capabilities} ->
        [
          %{field: :manifest, message: "release artifact #{index} capabilities must be a list"}
          | errors
        ]
    end
  end

  defp validate_artifact_string_metadata(errors, artifact, index, field) do
    case Map.fetch(artifact, field) do
      :error ->
        errors

      {:ok, value} ->
        if is_binary(value) and normalize_string(value) != "" do
          errors
        else
          [
            %{
              field: :manifest,
              message: "release artifact #{index} #{field} must be a non-empty string"
            }
            | errors
          ]
        end
    end
  end

  defp validate_artifact_object_metadata(errors, artifact, index) do
    Enum.reduce(@artifact_object_metadata_fields, errors, fn field, acc ->
      case Map.fetch(artifact, field) do
        :error ->
          acc

        {:ok, value} when is_map(value) ->
          acc

        {:ok, _value} ->
          [
            %{field: :manifest, message: "release artifact #{index} #{field} must be an object"}
            | acc
          ]
      end
    end)
  end

  defp validate_artifact_object_list_metadata(errors, artifact, index) do
    Enum.reduce(@artifact_object_list_metadata_fields, errors, fn field, acc ->
      case Map.fetch(artifact, field) do
        :error ->
          acc

        {:ok, values} when is_list(values) ->
          if Enum.all?(values, &is_map/1) do
            acc
          else
            [
              %{
                field: :manifest,
                message: "release artifact #{index} #{field} must contain objects"
              }
              | acc
            ]
          end

        {:ok, _values} ->
          [
            %{field: :manifest, message: "release artifact #{index} #{field} must be a list"}
            | acc
          ]
      end
    end)
  end

  defp validate_rdp_artifact_metadata(errors, artifact, index) do
    if rdp_artifact?(artifact) do
      errors
      |> require_rdp_string(artifact, index, "helper_protocol_version")
      |> validate_rdp_version_range(artifact, index)
      |> validate_rdp_deployment_requirements(artifact, index)
    else
      errors
    end
  end

  defp require_rdp_string(errors, artifact, index, field) do
    if non_empty_string?(Map.get(artifact, field)) do
      errors
    else
      [
        %{
          field: :manifest,
          message: "release artifact #{index} RDP capability requires #{field}"
        }
        | errors
      ]
    end
  end

  defp validate_rdp_version_range(errors, artifact, index) do
    case Map.get(artifact, "compatible_agent_versions") do
      %{"min" => min, "max" => max} when is_binary(min) and is_binary(max) ->
        if normalize_string(min) != "" and normalize_string(max) != "" do
          errors
        else
          rdp_version_range_error(errors, index)
        end

      _ ->
        rdp_version_range_error(errors, index)
    end
  end

  defp rdp_version_range_error(errors, index) do
    [
      %{
        field: :manifest,
        message:
          "release artifact #{index} RDP capability requires compatible_agent_versions.min and max"
      }
      | errors
    ]
  end

  defp validate_rdp_deployment_requirements(errors, artifact, index) do
    case Map.get(artifact, "deployment_requirements") do
      %{} = requirements ->
        errors
        |> validate_rdp_deployment_required_strings(requirements, index)
        |> validate_rdp_helper_connector_ready(requirements, index)
        |> validate_rdp_readiness_probe(requirements, index)
        |> validate_rdp_experimental_readiness(requirements, index)
        |> validate_rdp_connector_ready_reason(requirements, index)

      _ ->
        [
          %{
            field: :manifest,
            message: "release artifact #{index} RDP capability requires deployment_requirements"
          }
          | errors
        ]
    end
  end

  defp validate_rdp_deployment_required_strings(errors, requirements, index) do
    Enum.reduce(@rdp_deployment_required_strings, errors, fn field, acc ->
      if non_empty_string?(Map.get(requirements, field)) do
        acc
      else
        [
          %{
            field: :manifest,
            message: "release artifact #{index} RDP deployment_requirements requires #{field}"
          }
          | acc
        ]
      end
    end)
  end

  defp validate_rdp_helper_connector_ready(errors, requirements, index) do
    case Map.get(requirements, "helper_connector_ready") do
      value when is_boolean(value) ->
        errors

      _ ->
        [
          %{
            field: :manifest,
            message:
              "release artifact #{index} RDP deployment_requirements.helper_connector_ready must be boolean"
          }
          | errors
        ]
    end
  end

  defp validate_rdp_readiness_probe(errors, requirements, index) do
    if Map.get(requirements, "requires_helper_readiness_probe") do
      errors
    else
      [
        %{
          field: :manifest,
          message:
            "release artifact #{index} RDP deployment_requirements.requires_helper_readiness_probe must be true"
        }
        | errors
      ]
    end
  end

  defp validate_rdp_experimental_readiness(errors, requirements, index) do
    if Map.get(requirements, "helper_connector_ready") == false and
         normalize_string(Map.get(requirements, "release_phase")) != "experimental" do
      [
        %{
          field: :manifest,
          message:
            "release artifact #{index} RDP deployment_requirements.release_phase must be experimental while helper_connector_ready is false"
        }
        | errors
      ]
    else
      errors
    end
  end

  defp validate_rdp_connector_ready_reason(errors, requirements, index) do
    ready? = Map.get(requirements, "helper_connector_ready")
    reason = normalize_string(Map.get(requirements, "helper_connector_ready_reason"))
    reason? = reason != ""

    cond do
      ready? == false and not reason? ->
        [
          %{
            field: :manifest,
            message:
              "release artifact #{index} RDP deployment_requirements.helper_connector_ready_reason is required while helper_connector_ready is false"
          }
          | errors
        ]

      ready? == false and invalid_rdp_ready_reason?(reason) ->
        [
          %{
            field: :manifest,
            message:
              "release artifact #{index} RDP deployment_requirements.helper_connector_ready_reason must be printable and at most #{@rdp_helper_ready_reason_max_bytes} bytes"
          }
          | errors
        ]

      ready? == true and reason? ->
        [
          %{
            field: :manifest,
            message:
              "release artifact #{index} RDP deployment_requirements.helper_connector_ready_reason must be absent while helper_connector_ready is true"
          }
          | errors
        ]

      true ->
        errors
    end
  end

  defp invalid_rdp_ready_reason?(reason) do
    byte_size(reason) > @rdp_helper_ready_reason_max_bytes or
      String.match?(reason, ~r/[\x00-\x1F\x7F]/)
  end

  defp rdp_artifact?(artifact) do
    artifact
    |> Map.get("capabilities", [])
    |> case do
      capabilities when is_list(capabilities) -> capabilities
      _ -> []
    end
    |> Enum.map(&normalize_string/1)
    |> Enum.any?(&MapSet.member?(@rdp_capabilities, &1))
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

  defp non_empty_string?(value) when is_binary(value), do: normalize_string(value) != ""
  defp non_empty_string?(_value), do: false

  defp normalize_string(nil), do: ""
  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value), do: value |> to_string() |> String.trim()
end
