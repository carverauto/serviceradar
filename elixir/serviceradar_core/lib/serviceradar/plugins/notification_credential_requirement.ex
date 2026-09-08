defmodule ServiceRadar.Plugins.NotificationCredentialRequirement do
  @moduledoc """
  Validates and serializes one notifier credential-injection requirement.

  The notification manifest is the admission boundary for this contract. Each
  canonical mode has a closed, typed field set matching the Go host's actual
  injection implementation. `to_inject/1` is the only supported conversion to
  the host wire map, which keeps arbitrary or non-string values out of a
  `CredentialBrokerGrant`.
  """

  @modes ~w(
    http_header
    bearer_token
    basic_auth
    query
    form_urlencoded
    oauth2_password_bearer
    oauth2_client_credentials
  )

  @common_keys ~w(injection_mode required config_key ttl_seconds allow)
  @target_keys ~w(method host port path)
  @token_target_keys ~w(token_method token_host token_port token_path)
  @allow_keys ~w(hosts schemes methods paths ports)
  @http_methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS)
  @http_token ~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/
  @identifier ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/
  @host ~r/^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/
  @max_string_bytes 1_024

  @type normalized :: %{required(String.t()) => term()}
  @type target :: %{
          kind: :request | :token,
          scheme: String.t(),
          method: String.t(),
          host: String.t(),
          port: pos_integer(),
          path: String.t()
        }

  @spec modes() :: [String.t()]
  def modes, do: @modes

  @spec normalize(map(), String.t()) :: {:ok, normalized()} | {:error, [String.t()]}
  def normalize(value, path) when is_map(value) and is_binary(path) do
    requirement = stringify_keys(value)
    mode = normalized_string(requirement["injection_mode"])

    errors =
      []
      |> prepend_unknown_key_errors(requirement, mode, path)
      |> prepend_injection_mode_errors(mode, path)
      |> prepend_common_errors(requirement, path)
      |> prepend_mode_errors(requirement, mode, path)

    case Enum.reverse(errors) do
      [] -> {:ok, normalize_valid(requirement, mode)}
      errors -> {:error, errors}
    end
  end

  def normalize(_value, path), do: {:error, ["#{path} must be a map"]}

  @doc "Builds the exact string-to-string map consumed by the Go host."
  @spec to_inject(map(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, [String.t()]}
  def to_inject(requirement, path \\ "credential requirement") do
    with {:ok, normalized} <- normalize(requirement, path) do
      mode = normalized["injection_mode"]

      keys =
        case mode do
          "http_header" ->
            ~w(name scheme)

          "bearer_token" ->
            ~w(name scheme)

          "basic_auth" ->
            []

          "query" ->
            ["name"]

          "form_urlencoded" ->
            ~w(method host path) ++ mapping_keys(normalized)

          mode when mode in ~w(oauth2_password_bearer oauth2_client_credentials) ->
            ~w(method host path token_method token_host token_port token_path) ++
              mapping_keys(normalized)
        end

      inject =
        Enum.reduce(keys, %{"type" => mode}, fn key, acc ->
          case normalized[key] do
            nil -> acc
            value when is_integer(value) -> Map.put(acc, key, Integer.to_string(value))
            value when is_binary(value) -> Map.put(acc, key, value)
          end
        end)

      if safe_inject?(inject),
        do: {:ok, inject},
        else: {:error, ["#{path} cannot be serialized to a safe host inject map"]}
    end
  end

  @doc "Returns exact request and token endpoints declared by an injection mode."
  @spec targets(map(), String.t()) :: {:ok, [target()]} | {:error, [String.t()]}
  def targets(requirement, path \\ "credential requirement") do
    with {:ok, normalized} <- normalize(requirement, path) do
      request_target =
        if normalized["injection_mode"] in (~w(form_urlencoded) ++ oauth2_modes()) do
          [target_from(normalized, :request, "")]
        else
          []
        end

      token_target =
        if normalized["injection_mode"] in oauth2_modes() do
          [target_from(normalized, :token, "token_")]
        else
          []
        end

      {:ok, request_target ++ token_target}
    end
  end

  defp prepend_unknown_key_errors(errors, requirement, mode, path) do
    allowed = allowed_keys(mode)

    requirement
    |> Map.keys()
    |> Enum.reject(&allowed_key?(&1, allowed, mode))
    |> Enum.sort()
    |> Enum.reduce(errors, fn key, acc -> ["#{path}.#{key} is not allowed" | acc] end)
  end

  defp prepend_injection_mode_errors(errors, nil, path),
    do: ["#{path}.injection_mode is required" | errors]

  defp prepend_injection_mode_errors(errors, mode, _path) when mode in @modes, do: errors

  defp prepend_injection_mode_errors(errors, _mode, path) do
    ["#{path}.injection_mode must be one of: #{Enum.join(@modes, ", ")}" | errors]
  end

  defp prepend_common_errors(errors, requirement, path) do
    errors
    |> optional_boolean_errors(requirement, "required", path)
    |> optional_identifier_errors(requirement, "config_key", path)
    |> optional_positive_integer_errors(requirement, "ttl_seconds", path)
    |> allow_errors(requirement["allow"], path)
  end

  defp prepend_mode_errors(errors, requirement, "http_header", path) do
    errors
    |> required_header_name_errors(requirement, "name", path)
    |> optional_http_token_errors(requirement, "scheme", path)
  end

  defp prepend_mode_errors(errors, requirement, "bearer_token", path) do
    errors
    |> optional_header_name_errors(requirement, "name", path)
    |> optional_http_token_errors(requirement, "scheme", path)
  end

  defp prepend_mode_errors(errors, _requirement, "basic_auth", _path), do: errors

  defp prepend_mode_errors(errors, requirement, "query", path) do
    required_identifier_errors(errors, requirement, "name", path)
  end

  defp prepend_mode_errors(errors, requirement, "form_urlencoded", path) do
    errors
    |> exact_target_errors(requirement, path, "")
    |> mapping_errors(requirement, path, :form)
  end

  defp prepend_mode_errors(errors, requirement, mode, path)
       when mode in ~w(oauth2_password_bearer oauth2_client_credentials) do
    errors
    |> exact_target_errors(requirement, path, "")
    |> exact_target_errors(requirement, path, "token_")
    |> token_method_errors(requirement, path)
    |> mapping_errors(requirement, path, oauth2_grant(mode))
  end

  defp prepend_mode_errors(errors, _requirement, _mode, _path), do: errors

  defp exact_target_errors(errors, requirement, path, prefix) do
    errors
    |> required_method_errors(requirement, prefix <> "method", path)
    |> required_host_errors(requirement, prefix <> "host", path)
    |> required_port_errors(requirement, prefix <> "port", path)
    |> required_path_errors(requirement, prefix <> "path", path)
  end

  defp token_method_errors(errors, requirement, path) do
    case Map.fetch(requirement, "token_method") do
      :error ->
        errors

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        if String.upcase(value) == "POST",
          do: errors,
          else: ["#{path}.token_method must equal POST" | errors]

      {:ok, _other} ->
        errors
    end
  end

  defp mapping_errors(errors, requirement, path, mode) do
    field_entries = mapping_entries(requirement, "field_")
    fixed_entries = mapping_entries(requirement, "fixed_")

    errors =
      if field_entries == [] do
        ["#{path} must declare at least one field_ mapping" | errors]
      else
        errors
      end

    errors =
      Enum.reduce(field_entries ++ fixed_entries, errors, fn {key, value}, acc ->
        suffix = mapping_suffix(key)

        acc
        |> mapping_key_errors(suffix, key, path)
        |> mapping_value_errors(value, key, path, String.starts_with?(key, "field_"))
      end)

    errors = duplicate_mapping_target_errors(errors, field_entries, fixed_entries, path)

    case mode do
      {:oauth, grant_type, required_fields} ->
        required_fields
        |> Enum.reduce(errors, &required_mapping_target_errors(&2, field_entries, &1, path))
        |> fixed_grant_type_errors(requirement, grant_type, path)

      _ ->
        errors
    end
  end

  defp required_mapping_target_errors(errors, entries, target, path) do
    if Enum.any?(entries, fn {_key, value} -> normalized_string(value) == target end) do
      errors
    else
      ["#{path} must declare a field mapping to #{target}" | errors]
    end
  end

  defp fixed_grant_type_errors(errors, requirement, grant_type, path) do
    if requirement["fixed_grant_type"] == grant_type do
      errors
    else
      ["#{path}.fixed_grant_type must equal #{grant_type}" | errors]
    end
  end

  defp duplicate_mapping_target_errors(errors, field_entries, fixed_entries, path) do
    targets =
      Enum.map(field_entries, fn {_key, value} -> normalized_string(value) end) ++
        Enum.map(fixed_entries, fn {key, _value} -> mapping_suffix(key) end)

    duplicates =
      targets
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_target, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    Enum.reduce(duplicates, errors, fn target, acc ->
      ["#{path} maps more than one value to form field #{target}" | acc]
    end)
  end

  defp allow_errors(errors, nil, _path), do: errors

  defp allow_errors(errors, allow, path) when is_map(allow) do
    allow = stringify_keys(allow)

    errors =
      allow
      |> Map.keys()
      |> Enum.reject(&(&1 in @allow_keys))
      |> Enum.sort()
      |> Enum.reduce(errors, fn key, acc -> ["#{path}.allow.#{key} is not allowed" | acc] end)

    errors
    |> string_list_errors(allow, "hosts", path <> ".allow", &valid_host?/1)
    |> string_list_errors(allow, "schemes", path <> ".allow", &(&1 in ~w(http https)))
    |> string_list_errors(allow, "methods", path <> ".allow", &valid_method?/1)
    |> string_list_errors(allow, "paths", path <> ".allow", &valid_path?/1)
    |> port_list_errors(allow, "ports", path <> ".allow")
  end

  defp allow_errors(errors, _allow, path), do: ["#{path}.allow must be a map" | errors]

  defp string_list_errors(errors, map, key, path, validator) do
    case Map.fetch(map, key) do
      :error ->
        errors

      {:ok, values} when is_list(values) ->
        Enum.reduce(values, errors, fn
          value, acc when is_binary(value) ->
            if safe_string?(value) and validator.(String.trim(value)),
              do: acc,
              else: ["#{path}.#{key} contains an invalid string" | acc]

          _value, acc ->
            ["#{path}.#{key} must contain only strings" | acc]
        end)

      {:ok, _value} ->
        ["#{path}.#{key} must be a list" | errors]
    end
  end

  defp port_list_errors(errors, map, key, path) do
    case Map.fetch(map, key) do
      :error ->
        errors

      {:ok, values} when is_list(values) ->
        Enum.reduce(values, errors, fn value, acc ->
          if valid_port?(value),
            do: acc,
            else: ["#{path}.#{key} must contain only integer ports from 1 to 65535" | acc]
        end)

      {:ok, _value} ->
        ["#{path}.#{key} must be a list" | errors]
    end
  end

  defp required_header_name_errors(errors, map, key, path),
    do: required_string_errors(errors, map, key, path, &valid_header_name?/1)

  defp optional_header_name_errors(errors, map, key, path),
    do: optional_string_errors(errors, map, key, path, &valid_header_name?/1)

  defp optional_http_token_errors(errors, map, key, path),
    do: optional_string_errors(errors, map, key, path, &valid_http_token?/1)

  defp required_identifier_errors(errors, map, key, path),
    do: required_string_errors(errors, map, key, path, &valid_identifier?/1)

  defp optional_identifier_errors(errors, map, key, path),
    do: optional_string_errors(errors, map, key, path, &valid_identifier?/1)

  defp required_method_errors(errors, map, key, path),
    do: required_string_errors(errors, map, key, path, &valid_method?/1)

  defp required_host_errors(errors, map, key, path),
    do: required_string_errors(errors, map, key, path, &valid_host?/1)

  defp required_path_errors(errors, map, key, path),
    do: required_string_errors(errors, map, key, path, &valid_path?/1)

  defp required_string_errors(errors, map, key, path, validator) do
    case Map.fetch(map, key) do
      :error ->
        ["#{path}.#{key} is required" | errors]

      {:ok, value} when is_binary(value) ->
        if safe_string?(value) and validator.(String.trim(value)),
          do: errors,
          else: ["#{path}.#{key} is invalid" | errors]

      {:ok, _value} ->
        ["#{path}.#{key} must be a string" | errors]
    end
  end

  defp optional_string_errors(errors, map, key, path, validator) do
    case Map.fetch(map, key) do
      :error ->
        errors

      {:ok, value} when is_binary(value) ->
        if safe_string?(value) and validator.(String.trim(value)),
          do: errors,
          else: ["#{path}.#{key} is invalid" | errors]

      {:ok, _value} ->
        ["#{path}.#{key} must be a string" | errors]
    end
  end

  defp optional_boolean_errors(errors, map, key, path) do
    case Map.fetch(map, key) do
      :error -> errors
      {:ok, value} when is_boolean(value) -> errors
      {:ok, _value} -> ["#{path}.#{key} must be a boolean" | errors]
    end
  end

  defp optional_positive_integer_errors(errors, map, key, path) do
    case Map.fetch(map, key) do
      :error -> errors
      {:ok, value} when is_integer(value) and value > 0 -> errors
      {:ok, _value} -> ["#{path}.#{key} must be a positive integer" | errors]
    end
  end

  defp required_port_errors(errors, map, key, path) do
    case Map.fetch(map, key) do
      :error -> ["#{path}.#{key} is required" | errors]
      {:ok, value} when is_integer(value) and value >= 1 and value <= 65_535 -> errors
      {:ok, _value} -> ["#{path}.#{key} must be an integer from 1 to 65535" | errors]
    end
  end

  defp mapping_key_errors(errors, suffix, key, path) do
    if valid_identifier?(suffix),
      do: errors,
      else: ["#{path}.#{key} has an invalid mapping source or field name" | errors]
  end

  defp mapping_value_errors(errors, value, key, path, field_mapping?) do
    cond do
      not is_binary(value) ->
        ["#{path}.#{key} must be a string" | errors]

      not safe_string?(value) ->
        ["#{path}.#{key} is invalid" | errors]

      field_mapping? and not valid_identifier?(String.trim(value)) ->
        ["#{path}.#{key} must name a form field" | errors]

      true ->
        errors
    end
  end

  defp allowed_keys("http_header"), do: @common_keys ++ ~w(name scheme)
  defp allowed_keys("bearer_token"), do: @common_keys ++ ~w(name scheme)
  defp allowed_keys("basic_auth"), do: @common_keys
  defp allowed_keys("query"), do: @common_keys ++ ["name"]
  defp allowed_keys("form_urlencoded"), do: @common_keys ++ @target_keys

  defp allowed_keys(mode) when mode in ~w(oauth2_password_bearer oauth2_client_credentials),
    do: @common_keys ++ @target_keys ++ @token_target_keys

  defp allowed_keys(_mode), do: @common_keys

  defp allowed_key?(key, allowed, mode) do
    key in allowed or field_mapping_key?(key, mode) or fixed_mapping_key?(key, mode)
  end

  defp field_mapping_key?(key, mode),
    do: mode in (~w(form_urlencoded) ++ oauth2_modes()) and String.starts_with?(key, "field_")

  # A plugin can put non-secret fixed fields in its own form body. The only
  # fixed field the host must synthesize is the OAuth password grant type; a
  # general fixed_* surface would also let a manifest smuggle credential
  # literals into a host grant.
  defp fixed_mapping_key?("fixed_grant_type", mode)
       when mode in ~w(oauth2_password_bearer oauth2_client_credentials),
       do: true

  defp fixed_mapping_key?(_key, _mode), do: false

  # The two OAuth2 modes run the identical host-side exchange and differ only in
  # the grant they perform and the two credential fields that grant requires.
  defp oauth2_modes, do: ~w(oauth2_password_bearer oauth2_client_credentials)

  defp oauth2_grant("oauth2_password_bearer"), do: {:oauth, "password", ~w(username password)}

  defp oauth2_grant("oauth2_client_credentials"),
    do: {:oauth, "client_credentials", ~w(client_id client_secret)}

  defp mapping_key?(key),
    do: String.starts_with?(key, "field_") or String.starts_with?(key, "fixed_")

  defp mapping_keys(requirement) do
    requirement
    |> Map.keys()
    |> Enum.filter(&mapping_key?/1)
    |> Enum.sort()
  end

  defp mapping_entries(requirement, prefix) do
    requirement
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, prefix) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp mapping_suffix(key) do
    key
    |> String.replace_prefix("field_", "")
    |> String.replace_prefix("fixed_", "")
  end

  defp normalize_valid(requirement, mode) do
    allowed = allowed_keys(mode)

    requirement
    |> Enum.filter(fn {key, _value} -> allowed_key?(key, allowed, mode) end)
    |> Map.new(fn {key, value} -> {key, normalize_value(key, value)} end)
    |> Map.put("injection_mode", mode)
    |> put_bearer_defaults(mode)
  end

  defp normalize_value("allow", value), do: normalize_allow(value)
  defp normalize_value(key, value) when key in ~w(port token_port), do: value
  defp normalize_value(key, value) when key in ~w(required ttl_seconds), do: value

  defp normalize_value(key, value) when key in ~w(method token_method),
    do: value |> String.trim() |> String.upcase()

  defp normalize_value(key, value) when key in ~w(host token_host),
    do: value |> String.trim() |> String.trim_trailing(".") |> String.downcase()

  defp normalize_value(key, value) when is_binary(value) do
    if String.starts_with?(key, "fixed_"), do: value, else: String.trim(value)
  end

  defp normalize_value(_key, value), do: value

  defp normalize_allow(allow) do
    allow
    |> stringify_keys()
    |> Map.new(fn
      {"hosts", values} ->
        {"hosts",
         Enum.map(
           values,
           &(&1 |> String.trim() |> String.trim_trailing(".") |> String.downcase())
         )}

      {"schemes", values} ->
        {"schemes", Enum.map(values, &(&1 |> String.trim() |> String.downcase()))}

      {"methods", values} ->
        {"methods", Enum.map(values, &(&1 |> String.trim() |> String.upcase()))}

      {"paths", values} ->
        {"paths", Enum.map(values, &String.trim/1)}

      entry ->
        entry
    end)
  end

  defp put_bearer_defaults(requirement, "bearer_token") do
    requirement
    |> Map.put_new("name", "Authorization")
    |> Map.put_new("scheme", "Bearer")
  end

  defp put_bearer_defaults(requirement, _mode), do: requirement

  defp target_from(requirement, kind, prefix) do
    %{
      kind: kind,
      scheme: "https",
      method: requirement[prefix <> "method"],
      host: requirement[prefix <> "host"],
      port: requirement[prefix <> "port"],
      path: requirement[prefix <> "path"]
    }
  end

  defp valid_header_name?(value), do: valid_http_token?(value)
  defp valid_http_token?(value), do: value != "" and Regex.match?(@http_token, value)

  defp valid_identifier?(value),
    do:
      is_binary(value) and byte_size(value) <= @max_string_bytes and
        Regex.match?(@identifier, value)

  defp valid_method?(value), do: is_binary(value) and String.upcase(value) in @http_methods

  defp valid_host?(value) do
    value != "" and not String.contains?(value, "*") and Regex.match?(@host, value)
  end

  defp valid_path?(value) do
    String.starts_with?(value, "/") and not String.match?(value, ~r/[\x00-\x1F\x7F?#]/)
  end

  defp valid_port?(value), do: is_integer(value) and value >= 1 and value <= 65_535

  defp safe_string?(value) do
    trimmed = String.trim(value)

    trimmed != "" and byte_size(value) <= @max_string_bytes and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp safe_inject?(inject) do
    Enum.all?(inject, fn {key, value} ->
      is_binary(key) and is_binary(value) and safe_string?(key) and safe_string?(value)
    end)
  end

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(_value), do: nil

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
