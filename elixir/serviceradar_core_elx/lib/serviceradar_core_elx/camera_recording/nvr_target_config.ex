defmodule ServiceRadarCoreElx.CameraRecording.NVRTargetConfig do
  @moduledoc """
  Resolves installed workload credentials and storage identity for an NVR member.

  Target endpoints, TLS paths, bearer tokens and per-member storage UUIDs come
  only from operator-mounted configuration files, never from request parameters
  or camera credentials.
  """

  alias ServiceRadarNVRClient.Config

  @max_config_bytes 32_768
  @max_token_bytes 512
  @member_pattern ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type resolved_target :: %{
          member: String.t(),
          storage_id: String.t(),
          client_config: Config.t()
        }

  @spec resolve(String.t(), keyword()) :: {:ok, resolved_target()} | {:error, atom()}
  def resolve(member, opts \\ [])

  def resolve(member, opts) when is_binary(member) and is_list(opts) do
    with :ok <- validate_member_name(member),
         {:ok, config_path, token_path} <- config_paths(opts),
         {:ok, parsed} <- load_document(config_path, token_path) do
      fetch_member(parsed, member)
    end
  end

  def resolve(_member, _opts), do: {:error, :invalid_nvr_member}

  defp validate_member_name(member) do
    if Regex.match?(@member_pattern, member), do: :ok, else: {:error, :invalid_nvr_member}
  end

  defp config_paths(opts) do
    config_file =
      Keyword.get_lazy(opts, :config_file, fn ->
        Application.get_env(:serviceradar_core_elx, :camera_nvr_client_config_file)
      end)

    token_file =
      Keyword.get_lazy(opts, :token_file, fn ->
        Application.get_env(:serviceradar_core_elx, :camera_nvr_client_token_file)
      end)

    case {config_file, token_file} do
      {cfg, tok} when cfg in [nil, ""] and tok in [nil, ""] ->
        {:error, :nvr_client_not_configured}

      {cfg, tok} when is_binary(cfg) and is_binary(tok) ->
        if Path.type(cfg) == :absolute and Path.type(tok) == :absolute do
          {:ok, cfg, tok}
        else
          {:error, :invalid_nvr_client_config}
        end

      _ ->
        {:error, :invalid_nvr_client_config}
    end
  end

  defp load_document(config_path, token_path) do
    with {:ok, raw_config} <- Config.read(config_path, @max_config_bytes),
         {:ok, decoded} <- decode_object(raw_config),
         {:ok, raw_token} <- Config.read(token_path, @max_token_bytes) do
      validate_document(decoded, raw_token)
    else
      {:error, _} -> {:error, :invalid_nvr_client_config}
    end
  end

  defp decode_object(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_nvr_client_config}
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
         } = doc,
         token
       )
       when map_size(doc) == 6 and is_integer(default_port) and default_port in 1..65_535 and is_map(members) and
              map_size(members) > 0 do
    validate_members(members, default_port, ca_file, cert_file, key_file, token)
  end

  defp validate_document(_doc, _token), do: {:error, :invalid_nvr_client_config}

  defp validate_members(members, default_port, ca_file, cert_file, key_file, token) do
    members
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {name, entry}, {:ok, acc, seen_ids} ->
      with :ok <- member_key_valid(name),
           {:ok, target} <- build_target(name, entry, default_port, ca_file, cert_file, key_file, token),
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

  defp member_key_valid(name) when is_binary(name) do
    if Regex.match?(@member_pattern, name), do: :ok, else: {:error, :invalid_nvr_client_config}
  end

  defp member_key_valid(_name), do: {:error, :invalid_nvr_client_config}

  defp build_target(name, entry, default_port, ca_file, cert_file, key_file, token) when is_map(entry) do
    allowed_keys? =
      Map.keys(entry) -- ["host", "storage_id", "port"] == [] and
        Map.has_key?(entry, "host") and Map.has_key?(entry, "storage_id")

    port = Map.get(entry, "port", default_port)
    storage_id = Map.get(entry, "storage_id")
    host = Map.get(entry, "host")

    client_config = %Config{
      host: host,
      port: port,
      ca: ca_file,
      cert: cert_file,
      key: key_file,
      token: token
    }

    if allowed_keys? and valid_uuid?(storage_id) and is_integer(port) and port in 1..65_535 and
         Config.validate(client_config) == :ok do
      {:ok, %{member: name, storage_id: storage_id, client_config: client_config}}
    else
      {:error, :invalid_nvr_client_config}
    end
  end

  defp build_target(_name, _entry, _default_port, _ca_file, _cert_file, _key_file, _token),
    do: {:error, :invalid_nvr_client_config}

  defp fetch_member(validated_members, member) do
    case Map.fetch(validated_members, member) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, :unknown_nvr_member}
    end
  end

  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid_pattern, value)
end
