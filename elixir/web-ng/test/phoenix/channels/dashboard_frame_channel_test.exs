defmodule ServiceRadarWebNGWeb.DashboardFrameChannelTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Phoenix.ChannelTest

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.DashboardFrameChannel
  alias ServiceRadarWebNGWeb.UserSocket

  @endpoint ServiceRadarWebNGWeb.Endpoint

  defmodule FakeSRQL do
    @moduledoc false

    def query("in:test_rows", _opts) do
      {:ok, %{"results" => [%{"id" => "row-1", "value" => 7}], "pagination" => %{"limit" => 1}}}
    end

    def query_arrow("in:test_arrow", _opts) do
      {:ok, %{payload: "arrow bytes", schema: %{"columns" => ["id"]}}}
    end
  end

  setup do
    previous_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, FakeSRQL)

    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user, permissions: RBAC.permissions_for_user(user))

    on_exit(fn ->
      if is_nil(previous_srql_module) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, previous_srql_module)
      end
    end)

    {:ok, user: user, scope: scope}
  end

  test "joins with a signed stream token and pushes JSON row frames", %{user: user, scope: scope} do
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1}]
    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames)

    assert {:ok, %{"refresh_interval_ms" => 15_000}, _socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert_push "frames:replace", %{
      "frames" => [
        %{
          "id" => "rows",
          "status" => "ok",
          "encoding" => "json_rows",
          "results" => [%{"id" => "row-1", "value" => 7}]
        }
      ],
      "pending_binary_frame_ids" => []
    }

    refute_push "frame:binary", _payload, 100
  end

  test "streams Arrow IPC frame payloads as channel binary frames", %{user: user, scope: scope} do
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "arrow", "query" => "in:test_arrow", "encoding" => "arrow_ipc", "limit" => 1}]
    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames)

    assert {:ok, _reply, _socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert_push "frames:replace", %{
      "frames" => [
        %{
          "id" => "arrow",
          "status" => "ok",
          "encoding" => "arrow_ipc",
          "payload_transport" => "channel_binary"
        }
      ],
      "pending_binary_frame_ids" => ["arrow"]
    }

    assert_push "frame:binary", {:binary, frame}
    assert <<"DFB1", id_size::unsigned-integer-size(16), metadata_size::unsigned-integer-size(32), rest::binary>> = frame
    assert <<id::binary-size(id_size), metadata::binary-size(metadata_size), payload::binary>> = rest
    assert id == "arrow"
    assert Jason.decode!(metadata)["byte_length"] == byte_size("arrow bytes")
    assert payload == "arrow bytes"
  end

  test "rejects missing or mismatched stream tokens", %{user: user, scope: scope} do
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows"}]
    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token("other-route", data_frames)

    assert {:error, %{reason: "invalid_stream"}} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert {:error, %{reason: "missing_stream_token"}} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{})
  end

  defp create_dashboard_instance!(route_slug, data_frames, scope) do
    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, package_attrs(data_frames))
      |> Ash.create!(scope: scope)

    DashboardInstance
    |> Ash.Changeset.for_create(:create, %{
      dashboard_package_id: package.id,
      name: "Test Dashboard",
      route_slug: route_slug,
      placement: :custom,
      enabled: true,
      settings: %{},
      metadata: %{}
    })
    |> Ash.create!(scope: scope)
  end

  defp package_attrs(data_frames) do
    manifest = %{
      "id" => "com.test.dashboard.#{System.unique_integer([:positive])}",
      "name" => "Test Dashboard",
      "version" => "0.1.0",
      "renderer" => %{
        "kind" => "browser_wasm",
        "interface_version" => "dashboard-wasm-v1",
        "artifact" => "dashboard.wasm",
        "sha256" => String.duplicate("a", 64)
      },
      "data_frames" => data_frames,
      "capabilities" => ["srql.execute"],
      "settings_schema" => %{}
    }

    %{
      dashboard_id: manifest["id"],
      name: manifest["name"],
      version: manifest["version"],
      manifest: manifest,
      renderer: manifest["renderer"],
      data_frames: data_frames,
      capabilities: manifest["capabilities"],
      settings_schema: manifest["settings_schema"],
      wasm_object_key: "dashboards/test/dashboard.wasm",
      content_hash: String.duplicate("a", 64),
      verification_status: "verified"
    }
  end
end
