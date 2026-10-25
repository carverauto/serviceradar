defmodule ServiceRadarWebNG.ArchiveStorageListener do
  @moduledoc """
  Starts the opt-in storage-purpose HTTPS listener from installation files.

  Identity and authentication are loaded once when the listener starts. Provider
  credentials are never accepted here; this process only coordinates core state.
  """

  alias ServiceRadar.JSONDocument
  alias ServiceRadarWebNG.ControlPlaneRuntimeAccess
  alias ServiceRadarWebNGWeb.ArchiveStorageRouter

  @config_keys ~w(schema_version deployment_ref generation storage_service_id credential_reference credential_generation client_cert_sha256 cert_file key_file ca_file)

  def child_spec(opts) do
    config = load!(opts)

    Supervisor.child_spec(
      {Bandit,
       plug: {ArchiveStorageRouter, config},
       scheme: :https,
       ip: {0, 0, 0, 0},
       port: Keyword.get(opts, :port, 4002),
       certfile: config.cert_file,
       keyfile: config.key_file,
       thousand_island_options: [
         transport_options: [
           cacertfile: config.ca_file,
           verify: :verify_peer,
           fail_if_no_peer_cert: true,
           versions: [:"tlsv1.3", :"tlsv1.2"]
         ]
       ]},
      id: __MODULE__
    )
  end

  defp load!(opts) do
    with {:ok, bytes} <- bounded_file(Keyword.get(opts, :config_file), 16_384),
         {:ok, document} <- JSONDocument.decode_object(bytes, 16_384),
         true <- Enum.sort(Map.keys(document)) == Enum.sort(@config_keys),
         1 <- document["schema_version"],
         true <- uuid?(document["deployment_ref"]),
         {:ok, generation} <- generation(document["generation"]),
         {:ok, credential_generation} <- generation(document["credential_generation"]),
         true <- reference?(document["storage_service_id"]),
         true <- reference?(document["credential_reference"]),
         true <- Enum.all?(~w(cert_file key_file ca_file), &absolute_path?(document[&1])),
         {:ok, pin} <- decode_pin(document["client_cert_sha256"]),
         {:ok, token} <- bounded_file(Keyword.get(opts, :token_file), 512),
         true <- byte_size(token) in 32..512 and text?(token, 512) and String.trim(token) == token,
         true <- separate_token?(token),
         {:ok, _} <- media_origin(document) do
      %{
        principal: %{
          deployment_ref: document["deployment_ref"],
          generation: generation,
          storage_service_id: document["storage_service_id"],
          credential_reference: document["credential_reference"],
          credential_generation: credential_generation
        },
        token_sha256: :crypto.hash(:sha256, token),
        client_cert_sha256: pin,
        cert_file: document["cert_file"],
        key_file: document["key_file"],
        ca_file: document["ca_file"]
      }
    else
      _ -> raise ArgumentError, "invalid archive storage listener installation"
    end
  end

  defp media_origin(document) do
    token =
      :serviceradar_web_ng
      |> Application.get_env(:control_plane_runtime, [])
      |> get_in([:media, :token])

    ControlPlaneRuntimeAccess.authenticate(
      :media,
      token,
      {document["deployment_ref"], document["generation"]}
    )
  end

  defp separate_token?(token) do
    config = Application.get_env(:serviceradar_web_ng, :control_plane_runtime, [])
    token != config[:token] and token != get_in(config, [:media, :token])
  end

  defp bounded_file(path, limit) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, limit + 1) do
            bytes when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
            _ -> :error
          end
        after
          File.close(file)
        end

      _ ->
        :error
    end
  end

  defp bounded_file(_, _), do: :error

  defp uuid?(value) when is_binary(value) and byte_size(value) == 36 do
    match?({:ok, ^value}, Ecto.UUID.cast(value))
  end

  defp uuid?(_), do: false

  defp generation(value) when is_binary(value) and byte_size(value) <= 19 do
    case Integer.parse(value) do
      {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 ->
        if Integer.to_string(number) == value, do: {:ok, number}, else: :error

      _ ->
        :error
    end
  end

  defp generation(_), do: :error

  defp reference?(value) when is_binary(value) and byte_size(value) in 1..256, do: Regex.match?(~r/\A[!-~]+\z/, value)

  defp reference?(_), do: false

  defp text?(value, max) when is_binary(value),
    do: byte_size(value) in 1..max and String.valid?(value) and not String.contains?(value, [<<0>>, "\r", "\n"])

  defp text?(_, _), do: false
  defp absolute_path?(value), do: text?(value, 4096) and Path.type(value) == :absolute

  defp decode_pin(value) when is_binary(value) and byte_size(value) == 64, do: Base.decode16(value, case: :lower)

  defp decode_pin(_), do: :error
end
