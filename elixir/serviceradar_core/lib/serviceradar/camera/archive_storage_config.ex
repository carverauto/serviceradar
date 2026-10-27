defmodule ServiceRadar.Camera.ArchiveStorageConfig do
  @moduledoc """
  Loads one infrastructure-installed storage configuration and its secret files.

  Write credentials are checked against the desired authority; read credentials
  are fixed by the installation. No request selects a credential file, provider
  endpoint or installed identity.
  """
  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.HTTP.EgressProxy
  alias ServiceRadar.JSONDocument

  @fields ~w(schema_version deployment_ref generation provider_credentials_file listener runtime)
  @listener_fields ~w(port certfile keyfile cacertfile recorder_certificate_sha256 token_file)
  @runtime_fields ~w(base_url certfile keyfile cacertfile token_file)
  @credential_fields ~w(reference generation access_key_id secret_access_key)

  @doc "Loads a reader's fixed binding and private connection, never provider credentials."
  def load_reader(path) do
    with {:ok, document} <- read_json(path, 4096),
         true <-
           exact?(document, ~w(schema_version binding_id destination_sha256 storage)) and
             document["schema_version"] === 1,
         {:ok, id} <- Ecto.UUID.cast(document["binding_id"]),
         true <- sha?(document["destination_sha256"]),
         {:ok, client} <- runtime(document["storage"]) do
      {:ok, %{binding_id: id, destination_sha256: document["destination_sha256"], client: client}}
    else
      _ -> {:error, :invalid_archive_reader_configuration}
    end
  rescue
    _ -> {:error, :invalid_archive_reader_configuration}
  end

  @doc "Loads a read-only isolated listener; it has no write authority or runtime callback."
  def load_read_storage(path) do
    with {:ok, document} <- read_json(path, 8192),
         true <-
           exact?(
             document,
             ~w(schema_version binding_id destination provider_credentials_file listener)
           ) and
             document["schema_version"] === 1,
         {:ok, id} <- Ecto.UUID.cast(document["binding_id"]),
         {:ok, destination} <- ArchiveDestination.attributes(document["destination"]),
         {:ok, listener} <- listener(document["listener"], "reader_certificate_sha256"),
         {:ok, credential} <- read_json(document["provider_credentials_file"], 4096),
         true <- read_credential?(credential) do
      {:ok,
       %{
         binding_id: id,
         destination_sha256: destination.destination_sha256,
         listener: listener,
         provider: %{
           proxy: EgressProxy.from_env(),
           cacerts: :public_key.cacerts_get(),
           credential: credential,
           destination: document["destination"]
         }
       }}
    else
      _ -> {:error, :invalid_archive_read_storage_configuration}
    end
  rescue
    _ -> {:error, :invalid_archive_read_storage_configuration}
  end

  @doc "Loads only the recorder's installed spool/binding and private service connection."
  def load_recorder(path) do
    with {:ok, document} <- read_json(path, 4096),
         true <-
           exact?(document, ~w(schema_version spool_root binding_id storage)) and
             document["schema_version"] === 1,
         true <- path?(document["spool_root"]),
         {:ok, id} <- Ecto.UUID.cast(document["binding_id"]),
         {:ok, client} <- runtime(document["storage"]) do
      {:ok, %{root: document["spool_root"], binding_id: id, client: client}}
    else
      _ -> {:error, :invalid_media_upload_configuration}
    end
  rescue
    _ -> {:error, :invalid_media_upload_configuration}
  end

  def load(path) do
    with {:ok, document} <- read_json(path, 32_768),
         {:ok, generation} <- decimal(document["generation"]),
         installation = %{deployment_ref: document["deployment_ref"], generation: generation},
         {:ok, purposes} <- purposes(document, installation),
         [desired | rest] = Map.values(purposes),
         true <- Enum.all?(rest, &(shared_identity(&1) == shared_identity(desired))),
         {:ok, listener} <- listener(document["listener"]),
         {:ok, runtime} <- runtime(document["runtime"]),
         false <-
           Plug.Crypto.secure_compare(listener.token_sha256, :crypto.hash(:sha256, runtime.token)),
         {:ok, credential} <- read_json(document["provider_credentials_file"], 4096),
         true <- credential?(credential, desired.report["credential"]) do
      {:ok,
       %{
         installation: installation,
         purposes: purposes,
         listener: listener,
         runtime: runtime,
         provider: %{
           proxy: EgressProxy.from_env(),
           cacerts: :public_key.cacerts_get(),
           credential: credential,
           destination: desired.report["destination"]
         }
       }}
    else
      _ -> {:error, :invalid_storage_configuration}
    end
  rescue
    _ -> {:error, :invalid_storage_configuration}
  end

  defp purposes(%{"schema_version" => 1} = document, installation) do
    with true <- exact?(document, ["desired" | @fields]),
         {:ok, kind} <- ArchiveAuthorityConfig.kind(document["desired"]),
         {:ok, desired} <- ArchiveAuthorityConfig.parse(kind, installation, document["desired"]) do
      {:ok, %{kind => desired}}
    else
      _ -> {:error, :invalid_storage_configuration}
    end
  end

  defp purposes(%{"schema_version" => 2, "purposes" => purposes} = document, installation)
       when is_map(purposes) and map_size(purposes) in 1..3 do
    if exact?(document, ["purposes" | @fields]) do
      parse_purposes(purposes, installation)
    else
      {:error, :invalid_storage_configuration}
    end
  end

  defp purposes(_, _), do: {:error, :invalid_storage_configuration}

  defp parse_purposes(purposes, installation) do
    Enum.reduce_while(purposes, {:ok, %{}}, fn {name, value}, {:ok, parsed} ->
      with {:ok, kind} <-
             Map.fetch(%{"init" => :init, "media" => :media, "manifest" => :manifest}, name),
           {:ok, ^kind} <- ArchiveAuthorityConfig.kind(value),
           {:ok, desired} <- ArchiveAuthorityConfig.parse(kind, installation, value) do
        {:cont, {:ok, Map.put(parsed, kind, desired)}}
      else
        _ -> {:halt, {:error, :invalid_storage_configuration}}
      end
    end)
  end

  defp shared_identity(desired) do
    {
      desired.binding_id,
      desired.local_storage_id,
      desired.destination_sha256,
      Map.take(desired.report, ~w(provider_resource_id endpoint_type credential))
    }
  end

  defp listener(value, pin_field \\ "recorder_certificate_sha256") do
    fields = [pin_field | List.delete(@listener_fields, "recorder_certificate_sha256")]

    with true <- exact?(value, fields),
         port when is_integer(port) and port in 1..65_535 <- value["port"],
         pin when is_binary(pin) <- value[pin_field],
         true <- sha?(pin),
         {:ok, tls} <- tls(value),
         {:ok, token} <- token(value["token_file"]) do
      {:ok, %{port: port, tls: tls, pin: pin, token_sha256: :crypto.hash(:sha256, token)}}
    else
      _ -> {:error, :invalid_listener}
    end
  end

  defp runtime(value) do
    with true <- exact?(value, @runtime_fields),
         url when is_binary(url) and byte_size(url) <= 512 <- value["base_url"],
         %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path} <-
           URI.parse(url),
         true <- is_binary(host) and host != "" and path in [nil, ""],
         {:ok, tls} <- tls(value),
         {:ok, cacerts} <- ca_certificates(value["cacertfile"]),
         {:ok, token} <- token(value["token_file"]) do
      {:ok,
       %{
         base_url: url,
         token: token,
         proxy: nil,
         cacerts: cacerts,
         client_tls: Keyword.take(tls, [:certfile, :keyfile])
       }}
    else
      _ -> {:error, :invalid_runtime}
    end
  end

  defp tls(value) do
    paths = Enum.map(~w(certfile keyfile cacertfile), &value[&1])

    if Enum.all?(paths, &path?/1) do
      {:ok, Enum.zip([:certfile, :keyfile, :cacertfile], paths)}
    else
      {:error, :invalid_tls}
    end
  end

  defp credential?(value, expected) do
    exact?(value, @credential_fields) and value["reference"] === expected["reference"] and
      value["generation"] === expected["generation"] and
      secret?(value["access_key_id"], 1, 256) and secret?(value["secret_access_key"], 1, 512)
  end

  defp read_credential?(value) do
    exact?(value, @credential_fields) and secret?(value["reference"], 1, 256) and
      is_integer(value["generation"]) and value["generation"] in 1..9_223_372_036_854_775_807 and
      secret?(value["access_key_id"], 1, 256) and secret?(value["secret_access_key"], 1, 512)
  end

  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp token(path) do
    with {:ok, bytes} <- read_file(path, 512), true <- secret?(bytes, 32, 512) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp secret?(value, minimum, maximum) do
    is_binary(value) and byte_size(value) in minimum..maximum and
      String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, [<<0>>, "\r", "\n"])
  end

  defp ca_certificates(path) do
    with {:ok, bytes} <- read_file(path, 65_536) do
      certs = for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(bytes), do: der
      if certs == [], do: {:error, :invalid_ca}, else: {:ok, certs}
    end
  end

  defp read_json(path, limit) do
    with {:ok, bytes} <- read_file(path, limit), do: JSONDocument.decode_object(bytes, limit)
  end

  defp read_file(path, limit) do
    if path?(path) do
      case File.open(path, [:read, :binary]) do
        {:ok, file} ->
          try do
            case IO.binread(file, limit + 1) do
              bytes when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
              _ -> {:error, :invalid_file}
            end
          after
            File.close(file)
          end

        _ ->
          {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  defp path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..1024 and Path.type(path) == :absolute and
        not String.contains?(path, <<0>>)

  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp decimal(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..9_223_372_036_854_775_807 ->
        if Integer.to_string(integer) == value,
          do: {:ok, integer},
          else: {:error, :invalid_generation}

      _ ->
        {:error, :invalid_generation}
    end
  end

  defp decimal(_), do: {:error, :invalid_generation}
end
