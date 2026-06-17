defmodule ServiceRadarWebNGWeb.Api.AddonPackageControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNGWeb.Api.AddonPackageController

  setup do
    original = Application.get_env(:serviceradar_web_ng, :plugin_storage)

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :jetstream,
      signing_secret: "test-secret"
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :plugin_storage)
      else
        Application.put_env(:serviceradar_web_ng, :plugin_storage, original)
      end
    end)

    :ok
  end

  test "POST /api/addon-packages/:id/blob/download returns datasvc object bytes" do
    object_key = object_key()
    package = create_addon_package(object_key)
    payload = "downloadable-addon-tarball"
    {token, _expires_at} = Storage.sign_token(:download, package.id, object_key, 300)

    download_object = fn ^object_key, _opts -> {:ok, {nil, payload}} end

    conn =
      "POST"
      |> Plug.Test.conn("/api/addon-packages/#{package.id}/blob/download", "")
      |> Plug.Conn.put_req_header("x-serviceradar-plugin-token", token)
      |> Plug.Conn.put_private(:addon_package_controller_opts, download_object: download_object)
      |> AddonPackageController.download_blob(%{"id" => package.id})

    assert conn.status == 200
    assert conn.resp_body == payload
    assert ["application/gzip; charset=utf-8"] = Plug.Conn.get_resp_header(conn, "content-type")
  end

  test "POST /api/addon-packages/:id/blob/download maps missing datasvc object to 404" do
    object_key = object_key()
    package = create_addon_package(object_key)
    {token, _expires_at} = Storage.sign_token(:download, package.id, object_key, 300)

    not_found = GRPC.RPCError.exception(status: 5, message: "object not found")
    download_object = fn ^object_key, _opts -> {:error, not_found} end

    conn =
      "POST"
      |> Plug.Test.conn("/api/addon-packages/#{package.id}/blob/download", "")
      |> Plug.Conn.put_req_header("x-serviceradar-plugin-token", token)
      |> Plug.Conn.put_private(:addon_package_controller_opts, download_object: download_object)
      |> AddonPackageController.download_blob(%{"id" => package.id})

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
  end

  defp create_addon_package(object_key) do
    uid = System.unique_integer([:positive])

    AddonPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        addon_id: "netprobe-test-#{uid}",
        name: "Netprobe Test #{uid}",
        version: "0.2.1",
        delivery: :pushed_artifact,
        supervision: :systemd_service,
        binary: "serviceradar-netprobe",
        capabilities: ["host-network-visibility"],
        artifacts: %{
          "linux/amd64" => %{
            "object_key" => object_key,
            "sha256" => String.duplicate("a", 64),
            "signature" => String.duplicate("b", 128)
          }
        },
        verification_status: "verified"
      },
      actor: system_actor()
    )
    |> Ash.create!(actor: system_actor())
  end

  defp object_key do
    "native-addons/netprobe/0.2.1/linux/amd64/#{String.duplicate("c", 64)}.tar.gz"
  end
end
