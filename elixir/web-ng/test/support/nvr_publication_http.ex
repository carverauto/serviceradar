defmodule ServiceRadarWebNG.NVRPublicationHTTP do
  @moduledoc "Synthetic installation for the NVR HTTPS transport contract."

  alias ServiceRadarWebNG.ArchiveStorageHTTP
  alias ServiceRadarWebNG.NVRPublicationListener

  def installation(directory, storage_id) do
    installation = ArchiveStorageHTTP.installation(directory)

    document =
      installation.document
      |> Map.take(~w(cert_file key_file ca_file))
      |> Map.put("clients", %{installation.document["client_cert_sha256"] => storage_id})

    File.write!(installation.opts[:config_file], Jason.encode!(document))
    %{installation | document: document}
  end

  def start!(installation) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:req)
    spec = Supervisor.child_spec(NVRPublicationListener.child_spec(installation.opts), id: make_ref())
    pid = ExUnit.Callbacks.start_supervised!(spec)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    Map.merge(installation, %{port: port, child_id: spec.id})
  end

  def request(installation, body, opts \\ []) do
    Req.request(
      method: :post,
      url: "https://localhost:#{installation.port}/v1/local-publication-intents",
      headers:
        Keyword.get(opts, :headers, [
          {"authorization", "Bearer " <> installation.token},
          {"content-type", "application/json"}
        ]),
      body: body,
      retry: false,
      decode_body: false,
      receive_timeout: 15_000,
      connect_options: [transport_opts: Keyword.get(opts, :client, installation.client)]
    )
  end

  def send_without_reading(installation, body) do
    {:ok, socket} = :ssl.connect(~c"localhost", installation.port, [:binary, active: false] ++ installation.client, 5_000)

    :ok =
      :ssl.send(socket, [
        "POST /v1/local-publication-intents HTTP/1.1\r\nHost: localhost\r\n",
        "Authorization: Bearer ",
        installation.token,
        "\r\nContent-Type: application/json\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])

    socket
  end
end
