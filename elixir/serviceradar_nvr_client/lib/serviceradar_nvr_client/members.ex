defmodule ServiceRadarNVRClient.Members do
  @moduledoc """
  The NVR members one installed client configuration may reach.

  The document is `{"version": 1, "port", "ca_file", "cert_file", "key_file",
  "members"}`, where `members` maps each member name to `{"host", "storage_id"}`
  and an optional per-member `"port"`. Every member shares the TLS files and the
  token in the separate token file. Endpoints, credentials and storage UUIDs
  come only from these operator-mounted files, never from a request. Storage
  UUIDs are unique across members, so a block's `storage_id` names exactly one
  member.
  """

  alias ServiceRadarNVRClient.Config

  @max_config_bytes 32_768
  @max_token_bytes 512
  @member_pattern ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type target :: %{member: String.t(), storage_id: String.t(), client_config: Config.t()}

  @doc "Loads and validates the members of one configuration, keyed by member name."
  @spec load(String.t(), String.t()) ::
          {:ok, %{String.t() => target()}} | {:error, :invalid_nvr_client_config | :duplicate_nvr_storage_id}
  def load(config_path, token_path) do
    with {:ok, raw_config} <- Config.read(config_path, @max_config_bytes),
         {:ok, %{} = document} <- Jason.decode(raw_config),
         {:ok, token} <- Config.read(token_path, @max_token_bytes) do
      validate_document(document, token)
    else
      _ -> {:error, :invalid_nvr_client_config}
    end
  end

  @doc "True for a well-formed member name."
  def valid_name?(name), do: is_binary(name) and Regex.match?(@member_pattern, name)

  @doc "The member whose provisioned storage is `storage_id`."
  @spec by_storage_id(%{String.t() => target()}, String.t()) :: {:ok, target()} | {:error, :unknown_nvr_storage}
  def by_storage_id(members, storage_id) do
    case Enum.find(Map.values(members), &(&1.storage_id == storage_id)) do
      nil -> {:error, :unknown_nvr_storage}
      target -> {:ok, target}
    end
  end

  defp validate_document(
         %{
           "version" => 1,
           "port" => default_port,
           "ca_file" => ca_file,
           "cert_file" => cert_file,
           "key_file" => key_file,
           "members" => members
         } = document,
         token
       )
       when map_size(document) == 6 and is_integer(default_port) and default_port in 1..65_535 and is_map(members) and
              map_size(members) > 0 do
    shared = %{port: default_port, ca: ca_file, cert: cert_file, key: key_file, token: token}

    members
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {name, entry}, {:ok, acc, seen_ids} ->
      with true <- valid_name?(name) || {:error, :invalid_nvr_client_config},
           {:ok, target} <- target(name, entry, shared),
           false <- MapSet.member?(seen_ids, target.storage_id) do
        {:cont, {:ok, Map.put(acc, name, target), MapSet.put(seen_ids, target.storage_id)}}
      else
        true -> {:halt, {:error, :duplicate_nvr_storage_id}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, validated, _seen} -> {:ok, validated}
      {:error, _} = error -> error
    end
  end

  defp validate_document(_document, _token), do: {:error, :invalid_nvr_client_config}

  defp target(name, %{"host" => host, "storage_id" => storage_id} = entry, shared) do
    port = Map.get(entry, "port", shared.port)

    config = %Config{
      host: host,
      port: port,
      ca: shared.ca,
      cert: shared.cert,
      key: shared.key,
      token: shared.token
    }

    if Map.keys(entry) -- ["host", "storage_id", "port"] == [] and valid_uuid?(storage_id) and is_integer(port) and
         port in 1..65_535 and Config.validate(config) == :ok do
      {:ok, %{member: name, storage_id: storage_id, client_config: config}}
    else
      {:error, :invalid_nvr_client_config}
    end
  end

  defp target(_name, _entry, _shared), do: {:error, :invalid_nvr_client_config}

  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid_pattern, value)
end
