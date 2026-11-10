defmodule ServiceRadarWebNGWeb.NVRPublicationHTTPTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.NVRPublicationHTTP, as: HTTP
  alias ServiceRadarWebNG.NVRPublicationListener

  @moduletag :db_free
  @moduletag :tmp_dir

  test "HTTPS requires both the pinned client certificate and dedicated bearer token", %{tmp_dir: dir} do
    installation = HTTP.installation(dir, Ecto.UUID.generate())
    server = HTTP.start!(installation)
    assert {:ok, %{status: 400, body: body}} = HTTP.request(server, "{}")
    assert Jason.decode!(body) == %{"error" => "invalid_intent"}

    for headers <- [[], [{"authorization", "Bearer wrong-token"}]] do
      assert {:ok, %{status: 401}} = HTTP.request(server, "{}", headers: headers)
    end

    no_certificate = Keyword.drop(installation.client, [:cert, :key])
    assert {:error, _} = HTTP.request(server, "{}", client: no_certificate)

    document = Map.put(installation.document, "clients", %{String.duplicate("0", 64) => Ecto.UUID.generate()})
    File.write!(installation.opts[:config_file], Jason.encode!(document))
    unpinned = HTTP.start!(installation)
    assert {:ok, %{status: 401}} = HTTP.request(unpinned, "{}")
  end

  test "body size is bounded and malformed installations fail closed", %{tmp_dir: dir} do
    installation = HTTP.installation(dir, Ecto.UUID.generate())
    server = HTTP.start!(installation)
    assert {:ok, %{status: 413}} = HTTP.request(server, String.duplicate("x", 65_537))
    assert {:ok, %{status: 400}} = HTTP.request(server, "{}", headers: [{"authorization", "Bearer " <> server.token}])

    for clients <- [%{}, %{"bad-pin" => Ecto.UUID.generate()}, %{String.duplicate("0", 64) => "bad-storage"}] do
      File.write!(installation.opts[:config_file], Jason.encode!(Map.put(installation.document, "clients", clients)))

      assert_raise ArgumentError, "invalid NVR publication listener installation", fn ->
        NVRPublicationListener.child_spec(installation.opts)
      end
    end
  end
end
