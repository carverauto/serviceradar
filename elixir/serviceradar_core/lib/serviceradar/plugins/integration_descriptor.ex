defmodule ServiceRadar.Plugins.IntegrationDescriptor do
  @moduledoc """
  Validates declarative integration metadata shipped in a signed plugin package.

  Descriptors let approved packages publish credential-provider and inventory-source
  metadata without loading provider-specific code into ServiceRadar. Core consumes
  only this bounded, validated data and the package's JSON configuration schema.
  """

  alias ServiceRadar.Plugins.MapUtils

  @allowed_root_keys ~w(documentation credential_profiles inventory_sources)
  @allowed_profile_keys ~w(
    provider label description auth_methods purposes scope_types provisioning
  )
  @allowed_auth_method_keys ~w(id credential_kind)
  @allowed_provisioning_keys ~w(mode schedule_id credential_requirement)
  @allowed_inventory_source_keys ~w(source label description metadata_fields)
  @allowed_metadata_field_keys ~w(key label description format)
  @allowed_documentation_keys ~w(title path url)

  @allowed_auth_methods ~w(
    proxmox_api_token ssh_private_key username_password api_key certificate opaque
  )
  @allowed_credential_kinds ~w(api_token username_password ssh_private_key certificate opaque)
  @allowed_purposes ~w(
    inventory_enrichment console_access discovery generic camera_inventory camera_stream
    device_inventory
  )
  @allowed_scope_types ~w(agent gateway partition)
  @allowed_field_formats ~w(text boolean number timestamp)
  @id_regex ~r/^[a-z0-9][a-z0-9_.-]{0,127}$/
  @metadata_key_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
  @max_description_bytes 2_048
  @max_documentation_url_bytes 2_048
  @max_label_bytes 120
  @max_profiles 16
  @max_sources 16
  @max_metadata_fields 64

  @type descriptor :: %{String.t() => map() | [map()]}

  @spec validate(term(), [map()]) :: {:ok, descriptor()} | {:error, [String.t()]}
  def validate(nil, _producer_schedules), do: {:ok, empty()}

  def validate(value, producer_schedules) when is_map(value) and is_list(producer_schedules) do
    descriptor = MapUtils.stringify_keys(value)
    schedule_by_id = Map.new(producer_schedules, &{Map.get(&1, "schedule_id"), &1})

    errors = unknown_keys(descriptor, @allowed_root_keys, "integrations")

    {documentation, errors} =
      validate_documentation(Map.get(descriptor, "documentation"), errors)

    {credential_profiles, errors} =
      validate_profiles(
        Map.get(descriptor, "credential_profiles"),
        schedule_by_id,
        errors
      )

    {inventory_sources, errors} =
      validate_inventory_sources(Map.get(descriptor, "inventory_sources"), errors)

    errors =
      errors
      |> duplicate_errors(credential_profiles, "provider", "integrations.credential_profiles")
      |> duplicate_errors(inventory_sources, "source", "integrations.inventory_sources")

    case errors do
      [] ->
        {:ok,
         %{
           "documentation" => documentation,
           "credential_profiles" => credential_profiles,
           "inventory_sources" => inventory_sources
         }}

      _ ->
        {:error, Enum.reverse(errors)}
    end
  end

  def validate(_value, _producer_schedules), do: {:error, ["integrations must be a map"]}

  @spec empty() :: descriptor()
  def empty do
    %{
      "documentation" => %{},
      "credential_profiles" => [],
      "inventory_sources" => []
    }
  end

  defp validate_documentation(nil, errors), do: {%{}, errors}

  defp validate_documentation(value, errors) when is_map(value) do
    value = MapUtils.stringify_keys(value)

    errors =
      unknown_keys(value, @allowed_documentation_keys, "integrations.documentation") ++ errors

    {title, errors} = optional_label(value, "title", "integrations.documentation.title", errors)
    {path, errors} = required_string(value, "path", "integrations.documentation.path", errors)
    {url, errors} = optional_documentation_url(value, errors)

    errors =
      if is_binary(path) and safe_documentation_path?(path) do
        errors
      else
        ["integrations.documentation.path must reference a relative docs/*.md file" | errors]
      end

    {%{}
     |> maybe_put("title", title)
     |> maybe_put("path", path)
     |> maybe_put("url", url), errors}
  end

  defp validate_documentation(_value, errors),
    do: {%{}, ["integrations.documentation must be a map" | errors]}

  defp validate_profiles(nil, _schedule_by_id, errors), do: {[], errors}

  defp validate_profiles(values, schedule_by_id, errors)
       when is_list(values) and length(values) <= @max_profiles do
    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {profiles, acc_errors} ->
      case validate_profile(value, index, schedule_by_id) do
        {:ok, profile} -> {[profile | profiles], acc_errors}
        {:error, profile_errors} -> {profiles, profile_errors ++ acc_errors}
      end
    end)
    |> then(fn {profiles, acc_errors} -> {Enum.reverse(profiles), acc_errors} end)
  end

  defp validate_profiles(_values, _schedule_by_id, errors) do
    {[],
     [
       "integrations.credential_profiles must be a list with at most #{@max_profiles} entries"
       | errors
     ]}
  end

  defp validate_profile(value, index, schedule_by_id) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "integrations.credential_profiles[#{index}]"
    errors = unknown_keys(value, @allowed_profile_keys, path)
    {provider, errors} = required_id(value, "provider", "#{path}.provider", errors)
    {label, errors} = required_label(value, "label", "#{path}.label", errors)

    {description, errors} =
      optional_description(value, "description", "#{path}.description", errors)

    {auth_methods, errors} =
      validate_auth_methods(Map.get(value, "auth_methods"), "#{path}.auth_methods", errors)

    {purposes, errors} =
      enum_list(Map.get(value, "purposes"), @allowed_purposes, "#{path}.purposes", errors)

    {scope_types, errors} =
      enum_list(
        Map.get(value, "scope_types"),
        @allowed_scope_types,
        "#{path}.scope_types",
        errors
      )

    {provisioning, errors} =
      validate_provisioning(Map.get(value, "provisioning"), path, schedule_by_id, errors)

    case errors do
      [] ->
        {:ok,
         maybe_put(
           %{
             "provider" => provider,
             "label" => label,
             "auth_methods" => auth_methods,
             "purposes" => purposes,
             "scope_types" => scope_types,
             "provisioning" => provisioning
           },
           "description",
           description
         )}

      _ ->
        {:error, errors}
    end
  end

  defp validate_profile(_value, index, _schedule_by_id),
    do: {:error, ["integrations.credential_profiles[#{index}] must be a map"]}

  defp validate_auth_methods(values, path, errors) when is_list(values) and values != [] do
    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {methods, acc_errors} ->
      item_path = "#{path}[#{index}]"

      if is_map(value) do
        value = MapUtils.stringify_keys(value)
        item_errors = unknown_keys(value, @allowed_auth_method_keys, item_path)

        {id, item_errors} =
          enum(value, "id", @allowed_auth_methods, "#{item_path}.id", item_errors)

        {kind, item_errors} =
          enum(
            value,
            "credential_kind",
            @allowed_credential_kinds,
            "#{item_path}.credential_kind",
            item_errors
          )

        if item_errors == [] do
          {[%{"id" => id, "credential_kind" => kind} | methods], acc_errors}
        else
          {methods, item_errors ++ acc_errors}
        end
      else
        {methods, ["#{item_path} must be a map" | acc_errors]}
      end
    end)
    |> then(fn {methods, acc_errors} ->
      methods = Enum.reverse(methods)
      {methods, duplicate_errors(acc_errors, methods, "id", path)}
    end)
  end

  defp validate_auth_methods(_values, path, errors),
    do: {[], ["#{path} must be a non-empty list" | errors]}

  defp validate_provisioning(value, profile_path, schedule_by_id, errors) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "#{profile_path}.provisioning"
    errors = unknown_keys(value, @allowed_provisioning_keys, path) ++ errors
    {mode, errors} = enum(value, "mode", ["producer_schedule"], "#{path}.mode", errors)
    {schedule_id, errors} = required_id(value, "schedule_id", "#{path}.schedule_id", errors)

    {credential_requirement, errors} =
      required_id(
        value,
        "credential_requirement",
        "#{path}.credential_requirement",
        errors
      )

    schedule = Map.get(schedule_by_id, schedule_id)

    errors =
      cond do
        is_nil(schedule_id) ->
          errors

        is_nil(schedule) ->
          ["#{path}.schedule_id must reference a declared producer schedule" | errors]

        not Map.has_key?(
          Map.get(schedule, "credential_requirements", %{}),
          credential_requirement
        ) ->
          [
            "#{path}.credential_requirement must reference a requirement on the producer schedule"
            | errors
          ]

        true ->
          errors
      end

    {%{
       "mode" => mode,
       "schedule_id" => schedule_id,
       "credential_requirement" => credential_requirement
     }, errors}
  end

  defp validate_provisioning(_value, profile_path, _schedule_by_id, errors),
    do: {%{}, ["#{profile_path}.provisioning must be a map" | errors]}

  defp validate_inventory_sources(nil, errors), do: {[], errors}

  defp validate_inventory_sources(values, errors)
       when is_list(values) and length(values) <= @max_sources do
    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {sources, acc_errors} ->
      case validate_inventory_source(value, index) do
        {:ok, source} -> {[source | sources], acc_errors}
        {:error, source_errors} -> {sources, source_errors ++ acc_errors}
      end
    end)
    |> then(fn {sources, acc_errors} -> {Enum.reverse(sources), acc_errors} end)
  end

  defp validate_inventory_sources(_values, errors) do
    {[],
     [
       "integrations.inventory_sources must be a list with at most #{@max_sources} entries"
       | errors
     ]}
  end

  defp validate_inventory_source(value, index) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "integrations.inventory_sources[#{index}]"
    errors = unknown_keys(value, @allowed_inventory_source_keys, path)
    {source, errors} = required_id(value, "source", "#{path}.source", errors)
    {label, errors} = required_label(value, "label", "#{path}.label", errors)

    {description, errors} =
      optional_description(value, "description", "#{path}.description", errors)

    {metadata_fields, errors} =
      validate_metadata_fields(Map.get(value, "metadata_fields"), path, errors)

    case errors do
      [] ->
        {:ok,
         maybe_put(
           %{"source" => source, "label" => label, "metadata_fields" => metadata_fields},
           "description",
           description
         )}

      _ ->
        {:error, errors}
    end
  end

  defp validate_inventory_source(_value, index),
    do: {:error, ["integrations.inventory_sources[#{index}] must be a map"]}

  defp validate_metadata_fields(nil, _source_path, errors), do: {[], errors}

  defp validate_metadata_fields(values, source_path, errors)
       when is_list(values) and length(values) <= @max_metadata_fields do
    path = "#{source_path}.metadata_fields"

    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {fields, acc_errors} ->
      item_path = "#{path}[#{index}]"

      if is_map(value) do
        value = MapUtils.stringify_keys(value)
        item_errors = unknown_keys(value, @allowed_metadata_field_keys, item_path)
        {key, item_errors} = required_metadata_key(value, item_path, item_errors)
        {label, item_errors} = required_label(value, "label", "#{item_path}.label", item_errors)

        {description, item_errors} =
          optional_description(value, "description", "#{item_path}.description", item_errors)

        {format, item_errors} =
          optional_enum(
            value,
            "format",
            @allowed_field_formats,
            "#{item_path}.format",
            item_errors
          )

        if item_errors == [] do
          field =
            maybe_put(
              %{"key" => key, "label" => label, "format" => format || "text"},
              "description",
              description
            )

          {[field | fields], acc_errors}
        else
          {fields, item_errors ++ acc_errors}
        end
      else
        {fields, ["#{item_path} must be a map" | acc_errors]}
      end
    end)
    |> then(fn {fields, acc_errors} ->
      fields = Enum.reverse(fields)
      {fields, duplicate_errors(acc_errors, fields, "key", path)}
    end)
  end

  defp validate_metadata_fields(_values, source_path, errors) do
    {[],
     [
       "#{source_path}.metadata_fields must be a list with at most #{@max_metadata_fields} entries"
       | errors
     ]}
  end

  defp required_metadata_key(value, path, errors) do
    case normalized_string(Map.get(value, "key")) do
      key when is_binary(key) ->
        if Regex.match?(@metadata_key_regex, key) do
          {key, errors}
        else
          {nil, ["#{path}.key is invalid" | errors]}
        end

      _ ->
        {nil, ["#{path}.key must be a non-empty string" | errors]}
    end
  end

  defp enum_list(values, allowed, path, errors) when is_list(values) and values != [] do
    normalized = Enum.map(values, &normalized_string/1)

    cond do
      Enum.any?(normalized, &is_nil/1) ->
        {[], ["#{path} must contain non-empty strings" | errors]}

      Enum.any?(normalized, &(&1 not in allowed)) ->
        {[], ["#{path} contains an unsupported value" | errors]}

      length(Enum.uniq(normalized)) != length(normalized) ->
        {[], ["#{path} must not contain duplicates" | errors]}

      true ->
        {normalized, errors}
    end
  end

  defp enum_list(_values, _allowed, path, errors),
    do: {[], ["#{path} must be a non-empty list" | errors]}

  defp enum(value, key, allowed, path, errors) do
    case normalized_string(Map.get(value, key)) do
      item when is_binary(item) ->
        if item in allowed do
          {item, errors}
        else
          {nil, ["#{path} must be one of: #{Enum.join(allowed, ", ")}" | errors]}
        end

      _ ->
        {nil, ["#{path} must be one of: #{Enum.join(allowed, ", ")}" | errors]}
    end
  end

  defp optional_enum(value, key, allowed, path, errors) do
    case Map.get(value, key) do
      nil -> {nil, errors}
      _ -> enum(value, key, allowed, path, errors)
    end
  end

  defp required_id(value, key, path, errors) do
    case normalized_string(Map.get(value, key)) do
      id when is_binary(id) ->
        if Regex.match?(@id_regex, id) do
          {id, errors}
        else
          {nil, ["#{path} is invalid" | errors]}
        end

      _ ->
        {nil, ["#{path} must be a non-empty string" | errors]}
    end
  end

  defp required_label(value, key, path, errors) do
    case normalized_string(Map.get(value, key)) do
      label when is_binary(label) and byte_size(label) <= @max_label_bytes -> {label, errors}
      _ -> {nil, ["#{path} must be a non-empty string up to #{@max_label_bytes} bytes" | errors]}
    end
  end

  defp optional_label(value, key, path, errors) do
    case Map.get(value, key) do
      nil -> {nil, errors}
      _ -> required_label(value, key, path, errors)
    end
  end

  defp optional_description(value, key, path, errors) do
    case Map.get(value, key) do
      nil ->
        {nil, errors}

      raw ->
        case normalized_string(raw) do
          description
          when is_binary(description) and byte_size(description) <= @max_description_bytes ->
            {description, errors}

          _ ->
            {nil,
             ["#{path} must be a non-empty string up to #{@max_description_bytes} bytes" | errors]}
        end
    end
  end

  defp required_string(value, key, path, errors) do
    case normalized_string(Map.get(value, key)) do
      string when is_binary(string) -> {string, errors}
      _ -> {nil, ["#{path} must be a non-empty string" | errors]}
    end
  end

  defp optional_documentation_url(value, errors) do
    case Map.get(value, "url") do
      nil ->
        {nil, errors}

      raw ->
        case normalized_string(raw) do
          url when is_binary(url) ->
            if safe_documentation_url?(url) do
              {url, errors}
            else
              {nil,
               [
                 "integrations.documentation.url must be an HTTPS URL up to #{@max_documentation_url_bytes} bytes"
                 | errors
               ]}
            end

          _ ->
            {nil,
             [
               "integrations.documentation.url must be an HTTPS URL up to #{@max_documentation_url_bytes} bytes"
               | errors
             ]}
        end
    end
  end

  defp unknown_keys(value, allowed, path) do
    value
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.map(&"#{path}.#{&1} is not allowed")
  end

  defp duplicate_errors(errors, values, key, path) do
    values
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.reduce(errors, fn
      {value, count}, acc when count > 1 -> ["#{path} contains duplicate #{key} #{value}" | acc]
      _, acc -> acc
    end)
  end

  defp safe_documentation_path?(path) do
    String.starts_with?(path, "docs/") and String.ends_with?(path, ".md") and
      not String.starts_with?(path, "/") and
      not String.contains?(path, ["..", "\\"]) and
      byte_size(path) <= 240
  end

  defp safe_documentation_url?(url) do
    uri = URI.parse(url)

    byte_size(url) <= @max_documentation_url_bytes and uri.scheme == "https" and
      is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo)
  end

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalized_string()

  defp normalized_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
