defmodule ServiceRadarWebNGWeb.ArchiveStorageRouterTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.ArchiveStorageHTTP
  alias ServiceRadarWebNG.ArchiveStorageListener

  @moduletag :db_free
  @moduletag :tmp_dir

  @account_token "synthetic-account-purpose-token-for-storage-test"
  @media_token "synthetic-media-purpose-token-for-storage-test"
  @path "/v1/init-uploads/prepare"

  setup %{tmp_dir: directory} do
    previous = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    installation = ArchiveStorageHTTP.installation(directory)

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @account_token,
      media: [
        token: @media_token,
        deployment_ref: installation.document["deployment_ref"],
        generation: "1"
      ]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_runtime, previous),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_runtime)
    end)

    %{installation: installation}
  end

  test "the actual HTTPS listener requires a trusted certificate, exact pin and separate bearer before decoding",
       %{installation: installation} do
    server = ArchiveStorageHTTP.start!(installation)
    without_certificate = Keyword.drop(server.client, [:cert, :key])

    assert {:error, _} =
             ArchiveStorageHTTP.request(server, @path, "not-json", client: without_certificate)

    for token <- [@account_token, @media_token, "wrong-token"] do
      assert {:ok, %{status: 401, body: %{"status" => "unauthorized"}}} =
               ArchiveStorageHTTP.request(server, @path, "not-json", headers: [{"authorization", "Bearer " <> token}])
    end

    for headers <- [
          [],
          [{"x-serviceradar-control-plane-authorization", "Bearer " <> server.token}],
          [
            {"authorization", "Bearer " <> server.token},
            {"authorization", "Bearer " <> server.token}
          ]
        ] do
      assert {:ok, %{status: 401, body: %{"status" => "unauthorized"}}} =
               ArchiveStorageHTTP.request(server, @path, "not-json", headers: headers)
    end

    assert {:ok, %{status: 400, body: %{"status" => "invalid_request"}}} =
             ArchiveStorageHTTP.request(server, @path, "not-json")

    # A chain-valid client still fails when its leaf is not the installed pin.
    changed = Map.put(installation.document, "client_cert_sha256", String.duplicate("0", 64))
    File.write!(installation.opts[:config_file], Jason.encode!(changed))
    wrong_pin = ArchiveStorageHTTP.start!(installation)

    assert {:ok, %{status: 401, body: %{"status" => "unauthorized"}}} =
             ArchiveStorageHTTP.request(wrong_pin, @path, "not-json")

    # Changing the installation file cannot mutate a running listener identity.
    assert {:ok, %{status: 400}} = ArchiveStorageHTTP.request(server, @path, "not-json")
  end

  test "storage wire rejects ambiguous, oversized and caller-selected identities before core", %{
    installation: installation
  } do
    server = ArchiveStorageHTTP.start!(installation)

    lease = %{
      "id" => "d371cf4a-a123-4bc5-89ab-000000000001",
      "upload_token" => "d371cf4a-a123-4bc5-89ab-000000000002",
      "upload_epoch" => "1",
      "descriptor_sha256" => String.duplicate("a", 64)
    }

    document = %{"schema_version" => 1, "lease" => lease}
    bytes = Jason.encode!(document)
    duplicate_version = String.replace(bytes, ~s("schema_version":1), ~s("schema_version":1,"schema_version":1))
    duplicate_lease_id = String.replace(bytes, ~s("id":"#{lease["id"]}"), ~s("id":"#{lease["id"]}","id":"#{lease["id"]}"))

    for {path, body} <- [
          {@path, duplicate_version},
          {@path, duplicate_lease_id},
          {@path, Jason.encode!(Map.put(document, "actor", "caller-selected"))},
          {@path, Jason.encode!(Map.put(document, "schema_version", 1.0))},
          {@path, ~s({"schema_version":1,"lease":[]})},
          {"/v1/init-uploads/grant", ~s({"schema_version":1,"lease":{},"dispatch_id":"invalid"})},
          {"/v1/init-uploads/observe", ~s({"schema_version":1,"lease":{},"outcome":"response"})},
          {"/v1/init-uploads/verify", ~s({"schema_version":1,"verification":{}})}
        ] do
      assert {:ok, %{status: 400, body: %{"status" => "invalid_request"}}} =
               ArchiveStorageHTTP.request(server, path, body)
    end

    assert {:ok, %{status: 413, body: %{"status" => "request_too_large"}}} =
             ArchiveStorageHTTP.request(server, @path, String.duplicate(" ", 16_385) <> "{}")

    assert {:ok, %{status: 404, body: %{"status" => "not_found"}}} =
             ArchiveStorageHTTP.request(server, "/v1/media/installation", "{}")
  end

  test "installation rejects shared-purpose credentials and ambiguous identity before starting a socket",
       %{installation: installation} do
    for token <- [@account_token, @media_token, "short"] do
      File.write!(installation.opts[:token_file], token)

      assert_raise ArgumentError, "invalid archive storage listener installation", fn ->
        ArchiveStorageListener.child_spec(installation.opts)
      end
    end

    File.write!(installation.opts[:token_file], installation.token)

    for {key, value} <- [
          {"generation", "01"},
          {"generation", "2"},
          {"credential_generation", "0"},
          {"deployment_ref", String.upcase(installation.document["deployment_ref"])},
          {"client_cert_sha256", "invalid"},
          {"provider_access_key", "forbidden"}
        ] do
      File.write!(
        installation.opts[:config_file],
        Jason.encode!(Map.put(installation.document, key, value))
      )

      assert_raise ArgumentError, "invalid archive storage listener installation", fn ->
        ArchiveStorageListener.child_spec(installation.opts)
      end
    end
  end
end
