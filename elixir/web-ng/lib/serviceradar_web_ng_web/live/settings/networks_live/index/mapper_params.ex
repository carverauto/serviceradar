defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperParams do
  @moduledoc false

  def normalize_mapper_job_params(params) do
    params
    |> normalize_boolean("enabled")
    |> normalize_integer("concurrency")
    |> normalize_integer("retries")
    |> drop_blank(~w(agent_id))
    |> blank_to_nil("snmp_credential_secret_id")
  end

  # The select's empty option means "no SNMP credential". The attribute is a
  # UUID, which does not cast "" to nil, so send nil explicitly.
  def blank_to_nil(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: Map.put(params, key, nil), else: params

      _ ->
        params
    end
  end

  def normalize_unifi_params(params) do
    params
    |> normalize_boolean("insecure_skip_verify")
    |> drop_blank(~w(api_key))
  end

  def normalize_mikrotik_params(params) do
    params
    |> normalize_boolean("insecure_skip_verify")
    |> drop_blank(~w(password))
  end

  def normalize_boolean(params, key) do
    case Map.get(params, key) do
      "true" -> Map.put(params, key, true)
      "false" -> Map.put(params, key, false)
      true -> params
      false -> params
      _ -> params
    end
  end

  def normalize_integer(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) ->
        params

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> Map.put(params, key, parsed)
          :error -> Map.delete(params, key)
        end

      _ ->
        params
    end
  end

  def drop_blank(params, keys) do
    Enum.reduce(keys, params, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        "" -> Map.delete(acc, key)
        _ -> acc
      end
    end)
  end
end
