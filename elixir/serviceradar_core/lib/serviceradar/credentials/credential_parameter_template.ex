defmodule ServiceRadar.Credentials.CredentialParameterTemplate do
  @moduledoc """
  Validates and renders public plugin parameters declared by package manifests.

  Directives can reference a broker grant, a secret reference, a public
  username, selected rule fields, or bounded rule metadata. They cannot read
  encrypted credential values or invoke package code.
  """

  alias ServiceRadar.Credentials.RuleAccessors

  @source_key "$source"
  @sources ~w(grant secret_ref public_username rule metadata metadata_first)
  @rule_fields ~w(id auth_method tls_policy ssh_host_key_policy ca_bundle_pem server_cert_fingerprint)
  @value_types ~w(string integer boolean)
  @normalizers ~w(hostname)
  @max_depth 8
  @max_collection_entries 128
  @max_string_bytes 16_384
  @key_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/

  @spec validate(term(), String.t()) :: {:ok, term()} | {:error, [String.t()]}
  def validate(value, path \\ "params") do
    case validate_value(value, path, 0) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, errors} -> {:error, Enum.reverse(errors)}
    end
  end

  @spec render(map(), map()) :: {:ok, map()} | {:error, term()}
  def render(template, context) when is_map(template) and is_map(context) do
    case render_value(template, context) do
      {:ok, %{} = rendered} -> {:ok, rendered}
      {:ok, _other} -> {:error, :credential_parameter_template_must_render_map}
      {:error, _reason} = error -> error
    end
  end

  def render(_template, _context), do: {:error, :invalid_credential_parameter_template}

  @doc false
  def references_source?(template, source) when is_binary(source) do
    case template do
      %{@source_key => ^source} -> true
      %{} -> Enum.any?(template, fn {_key, value} -> references_source?(value, source) end)
      values when is_list(values) -> Enum.any?(values, &references_source?(&1, source))
      _ -> false
    end
  end

  defp validate_value(_value, path, depth) when depth > @max_depth,
    do: {:error, ["#{path} exceeds the maximum nesting depth"]}

  defp validate_value(%{@source_key => _source} = directive, path, _depth),
    do: validate_directive(directive, path)

  defp validate_value(value, path, depth) when is_map(value) do
    if map_size(value) > @max_collection_entries do
      {:error, ["#{path} has too many entries"]}
    else
      value
      |> Enum.reduce({:ok, %{}, []}, fn {key, child}, {status, acc, errors} ->
        key = to_string(key)

        key_errors =
          if Regex.match?(@key_regex, key), do: [], else: ["#{path}.#{key} has an invalid key"]

        case validate_value(child, "#{path}.#{key}", depth + 1) do
          {:ok, normalized} -> {status, Map.put(acc, key, normalized), key_errors ++ errors}
          {:error, child_errors} -> {:error, acc, child_errors ++ key_errors ++ errors}
        end
      end)
      |> case do
        {_status, normalized, []} -> {:ok, normalized}
        {_status, _normalized, errors} -> {:error, errors}
      end
    end
  end

  defp validate_value(values, path, depth) when is_list(values) do
    if length(values) > @max_collection_entries do
      {:error, ["#{path} has too many entries"]}
    else
      values
      |> Enum.with_index(1)
      |> Enum.reduce({:ok, [], []}, fn {value, index}, {status, acc, errors} ->
        case validate_value(value, "#{path}[#{index}]", depth + 1) do
          {:ok, normalized} -> {status, [normalized | acc], errors}
          {:error, child_errors} -> {:error, acc, child_errors ++ errors}
        end
      end)
      |> case do
        {_status, normalized, []} -> {:ok, Enum.reverse(normalized)}
        {_status, _normalized, errors} -> {:error, errors}
      end
    end
  end

  defp validate_value(value, _path, _depth)
       when is_boolean(value) or is_integer(value) or is_float(value) or is_nil(value),
       do: {:ok, value}

  defp validate_value(value, path, _depth) when is_binary(value) do
    if byte_size(value) <= @max_string_bytes,
      do: {:ok, value},
      else: {:error, ["#{path} exceeds #{@max_string_bytes} bytes"]}
  end

  defp validate_value(_value, path, _depth),
    do: {:error, ["#{path} contains an unsupported value"]}

  defp validate_directive(directive, path) do
    directive = Map.new(directive, fn {key, value} -> {to_string(key), value} end)
    source = directive[@source_key]

    with :ok <- require_member(source, @sources, "#{path}.#{@source_key}"),
         :ok <- validate_directive_keys(directive, source, path),
         :ok <- validate_directive_shape(directive, source, path) do
      {:ok, directive}
    else
      {:error, error} -> {:error, [error]}
      {:errors, errors} -> {:error, errors}
    end
  end

  defp validate_directive_keys(directive, source, path) do
    allowed =
      case source do
        source when source in ["grant", "secret_ref", "public_username"] ->
          ~w($source omit_if_blank)

        "rule" ->
          ~w($source field equals omit_if_blank)

        "metadata" ->
          ~w($source key type default normalize omit_if_blank)

        "metadata_first" ->
          ~w($source keys type default normalize omit_if_blank)

        _ ->
          []
      end

    case Map.keys(directive) -- allowed do
      [] -> :ok
      keys -> {:errors, Enum.map(keys, &"#{path}.#{&1} is not allowed")}
    end
  end

  defp validate_directive_shape(directive, source, path)
       when source in ["grant", "secret_ref", "public_username"] do
    optional_boolean(directive, "omit_if_blank", path)
  end

  defp validate_directive_shape(directive, "rule", path) do
    with :ok <- require_member(directive["field"], @rule_fields, "#{path}.field"),
         :ok <- optional_string(directive, "equals", path) do
      optional_boolean(directive, "omit_if_blank", path)
    end
  end

  defp validate_directive_shape(directive, "metadata", path) do
    with :ok <- require_identifier(directive["key"], "#{path}.key") do
      validate_metadata_directive_options(directive, path)
    end
  end

  defp validate_directive_shape(directive, "metadata_first", path) do
    keys = directive["keys"]

    with true <- is_list(keys) and keys != [] and length(keys) <= 16,
         true <- Enum.all?(keys, &valid_identifier?/1),
         :ok <- validate_metadata_directive_options(directive, path) do
      :ok
    else
      false -> {:error, "#{path}.keys must contain one to sixteen identifiers"}
      {:error, _reason} = error -> error
    end
  end

  defp validate_metadata_directive_options(directive, path) do
    type = Map.get(directive, "type", "string")

    with :ok <- require_member(type, @value_types, "#{path}.type"),
         :ok <- optional_member(directive, "normalize", @normalizers, path),
         :ok <- optional_boolean(directive, "omit_if_blank", path) do
      validate_default(directive, type, path)
    end
  end

  defp validate_default(directive, type, path) do
    case Map.fetch(directive, "default") do
      :error -> :ok
      {:ok, value} when type == "string" and is_binary(value) -> :ok
      {:ok, value} when type == "integer" and is_integer(value) -> :ok
      {:ok, value} when type == "boolean" and is_boolean(value) -> :ok
      {:ok, _value} -> {:error, "#{path}.default does not match #{type}"}
    end
  end

  defp render_value(%{@source_key => source} = directive, context),
    do: render_directive(source, directive, context)

  defp render_value(map, context) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case render_value(value, context) do
        {:ok, :omit} -> {:cont, {:ok, acc}}
        {:ok, rendered} -> {:cont, {:ok, Map.put(acc, to_string(key), rendered)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp render_value(values, context) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case render_value(value, context) do
        {:ok, :omit} -> {:cont, {:ok, acc}}
        {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  defp render_value(value, _context), do: {:ok, value}

  defp render_directive("grant", directive, context),
    do: required_context_value(context, :grant, directive)

  defp render_directive("secret_ref", directive, context),
    do: required_context_value(context, :secret_ref, directive)

  defp render_directive("public_username", directive, context),
    do: optional_rendered_value(Map.get(context, :public_username), directive)

  defp render_directive("rule", directive, context) do
    value =
      RuleAccessors.value_string(
        Map.get(context, :rule, %{}),
        rule_field_keys(directive["field"])
      )

    value =
      case Map.fetch(directive, "equals") do
        {:ok, expected} -> value == expected
        :error -> value
      end

    optional_rendered_value(value, directive)
  end

  defp render_directive("metadata", directive, context) do
    value = Map.get(rule_metadata(context), directive["key"], Map.get(directive, "default"))
    render_metadata_value(value, directive)
  end

  defp render_directive("metadata_first", directive, context) do
    metadata = rule_metadata(context)

    value =
      Enum.find_value(directive["keys"], Map.get(directive, "default"), fn key ->
        case Map.get(metadata, key) do
          value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
          nil -> nil
          value -> value
        end
      end)

    render_metadata_value(value, directive)
  end

  defp render_directive(_source, _directive, _context),
    do: {:error, :unsupported_credential_parameter_source}

  defp required_context_value(context, key, directive) do
    case Map.fetch(context, key) do
      {:ok, value} -> optional_rendered_value(value, directive)
      :error -> {:error, {:missing_credential_parameter_context, key}}
    end
  end

  defp render_metadata_value(value, directive) do
    with {:ok, typed} <- cast_value(value, Map.get(directive, "type", "string")),
         {:ok, normalized} <- normalize_value(typed, directive["normalize"]) do
      optional_rendered_value(normalized, directive)
    end
  end

  defp cast_value(nil, _type), do: {:ok, nil}
  defp cast_value(value, "string") when is_binary(value), do: {:ok, value}
  defp cast_value(value, "string"), do: {:ok, to_string(value)}
  defp cast_value(value, "integer") when is_integer(value), do: {:ok, value}

  defp cast_value(value, "integer") when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_credential_parameter_integer}
    end
  end

  defp cast_value(value, "boolean") when is_boolean(value), do: {:ok, value}
  defp cast_value(value, "boolean") when value in ["true", "on", "1", 1], do: {:ok, true}
  defp cast_value(value, "boolean") when value in ["false", "off", "0", 0], do: {:ok, false}
  defp cast_value(_value, type), do: {:error, {:invalid_credential_parameter_type, type}}

  defp normalize_value(value, nil), do: {:ok, value}

  defp normalize_value(value, "hostname") when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:ok, value}
    end
  end

  defp normalize_value(_value, normalizer),
    do: {:error, {:invalid_credential_parameter_normalizer, normalizer}}

  defp optional_rendered_value(value, directive) do
    if directive["omit_if_blank"] == true and blank?(value),
      do: {:ok, :omit},
      else: {:ok, value}
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp rule_metadata(context), do: RuleAccessors.metadata(Map.get(context, :rule, %{}))

  defp rule_field_keys("id"), do: [:id, "id"]
  defp rule_field_keys("auth_method"), do: [:auth_method, "auth_method"]
  defp rule_field_keys("tls_policy"), do: [:tls_policy, "tls_policy"]
  defp rule_field_keys("ssh_host_key_policy"), do: [:ssh_host_key_policy, "ssh_host_key_policy"]
  defp rule_field_keys("ca_bundle_pem"), do: [:ca_bundle_pem, "ca_bundle_pem"]

  defp rule_field_keys("server_cert_fingerprint"),
    do: [:server_cert_fingerprint, "server_cert_fingerprint"]

  defp require_member(value, allowed, path) do
    if value in allowed, do: :ok, else: {:error, "#{path} contains an unsupported value"}
  end

  defp optional_member(map, key, allowed, path) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} -> require_member(value, allowed, "#{path}.#{key}")
    end
  end

  defp optional_string(map, key, path) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) and byte_size(value) <= @max_string_bytes -> :ok
      {:ok, _value} -> {:error, "#{path}.#{key} must be a bounded string"}
    end
  end

  defp optional_boolean(map, key, path) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, "#{path}.#{key} must be a boolean"}
    end
  end

  defp require_identifier(value, path) do
    if valid_identifier?(value), do: :ok, else: {:error, "#{path} must be an identifier"}
  end

  defp valid_identifier?(value), do: is_binary(value) and Regex.match?(@key_regex, value)
end
