defmodule ServiceRadarWebNG.ArchiveStorageHTTP do
  @moduledoc "Synthetic mutual-TLS installation used by the private HTTP contract tests."

  alias ServiceRadarWebNG.ArchiveStorageListener

  def installation(directory) do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    algorithm = [digest: :sha256, key: {:namedCurve, :secp256r1}]

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: algorithm,
          intermediates: [],
          peer: algorithm ++ [extensions: [san]]
        },
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    cert_file = Path.join(directory, "server.pem")
    key_file = Path.join(directory, "server-key.pem")
    ca_file = Path.join(directory, "ca.pem")
    {key_type, key_der} = server[:key]

    File.write!(
      cert_file,
      :public_key.pem_encode([{:Certificate, server[:cert], :not_encrypted}])
    )

    File.write!(key_file, :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))

    File.write!(
      ca_file,
      :public_key.pem_encode(Enum.map(server[:cacerts], &{:Certificate, &1, :not_encrypted}))
    )

    document = %{
      "schema_version" => 1,
      "deployment_ref" => Ecto.UUID.generate(),
      "generation" => "1",
      "storage_service_id" => "spiffe://example.org/storage/init-test",
      "credential_reference" => "infrastructure/media/synthetic-test",
      "credential_generation" => "1",
      "client_cert_sha256" => Base.encode16(:crypto.hash(:sha256, client[:cert]), case: :lower),
      "cert_file" => cert_file,
      "key_file" => key_file,
      "ca_file" => ca_file
    }

    config_file = Path.join(directory, "config.json")
    token_file = Path.join(directory, "token")
    token = "synthetic-storage-listener-token-for-http-contract"
    File.write!(config_file, Jason.encode!(document))
    File.write!(token_file, token)

    %{
      document: document,
      client: client ++ [verify: :verify_peer, server_name_indication: ~c"localhost"],
      token: token,
      opts: [config_file: config_file, token_file: token_file, port: 0]
    }
  end

  def start!(installation) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:req)

    spec =
      Supervisor.child_spec(ArchiveStorageListener.child_spec(installation.opts), id: make_ref())

    pid = ExUnit.Callbacks.start_supervised!(spec)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    Map.put(installation, :port, port)
  end

  def request(installation, path, body, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, [{"authorization", "Bearer " <> installation.token}]) ++
        [{"content-type", "application/json"}]

    Req.request(
      method: :post,
      url: "https://localhost:#{installation.port}" <> path,
      headers: headers,
      body: body,
      retry: false,
      receive_timeout: 5_000,
      connect_options: [transport_opts: Keyword.get(opts, :client, installation.client)]
    )
  end
end
