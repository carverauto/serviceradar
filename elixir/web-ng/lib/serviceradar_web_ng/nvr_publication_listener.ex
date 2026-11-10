defmodule ServiceRadarWebNG.NVRPublicationListener do
  @moduledoc """
  Opt-in private listener for storage-bound NVR intent acceptance.

  Installation files bind certificate fingerprints to storage lifetimes. They
  contain ServiceRadar workload credentials, never monitored-device credentials.
  Configuration is loaded at startup; replacing it requires a listener restart.
  """

  alias ServiceRadar.JSONDocument
  alias ServiceRadarWebNGWeb.NVRPublicationRouter

  def child_spec(opts) do
    config = load!(opts)

    Supervisor.child_spec(
      {Bandit,
       plug: {NVRPublicationRouter, config},
       scheme: :https,
       ip: {0, 0, 0, 0},
       port: Keyword.get(opts, :port, 4003),
       certfile: config.cert_file,
       keyfile: config.key_file,
       http_1_options: [max_requests: 1],
       http_2_options: [enabled: false],
       thousand_island_options: [
         num_acceptors: 2,
         num_connections: 2,
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
    with {:ok, bytes} <- bounded_file(Keyword.get(opts, :config_file), 32_768),
         {:ok, document} <- JSONDocument.decode_object(bytes, 32_768),
         true <- Enum.sort(Map.keys(document)) == ~w(ca_file cert_file clients key_file),
         true <- Enum.all?(~w(cert_file key_file ca_file), &absolute_path?(document[&1])),
         {:ok, clients} <- clients(document["clients"]),
         {:ok, token} <- bounded_file(Keyword.get(opts, :token_file), 512),
         true <- byte_size(token) in 32..512 and Regex.match?(~r/\A[!-~]+\z/, token) do
      %{
        clients: clients,
        token_sha256: :crypto.hash(:sha256, token),
        cert_file: document["cert_file"],
        key_file: document["key_file"],
        ca_file: document["ca_file"]
      }
    else
      _ -> raise ArgumentError, "invalid NVR publication listener installation"
    end
  end

  defp clients(clients) when is_map(clients) and map_size(clients) in 1..64 do
    Enum.reduce_while(clients, {:ok, %{}}, fn {pin, storage_id}, {:ok, bindings} ->
      with true <- byte_size(pin) == 64,
           {:ok, digest} <- Base.decode16(pin, case: :lower),
           {:ok, ^storage_id} <- Ecto.UUID.cast(storage_id) do
        {:cont, {:ok, Map.put(bindings, digest, storage_id)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp clients(_), do: :error

  defp absolute_path?(value) when is_binary(value),
    do: byte_size(value) in 1..4096 and not String.contains?(value, [<<0>>, "\r", "\n"]) and Path.type(value) == :absolute

  defp absolute_path?(_), do: false

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
end
