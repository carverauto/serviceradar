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
      notify_query("in:test_rows")
      {:ok, %{"results" => [%{"id" => "row-1", "value" => 7}], "pagination" => %{"limit" => 1}}}
    end

    def query("in:test_paged_rows", opts) do
      notify_query({"in:test_paged_rows", Map.get(opts, :cursor)})
      id = if Map.get(opts, :cursor) == "page-two", do: "row-2", else: "row-1"

      {:ok,
       %{
         "results" => [%{"id" => id, "value" => 7}],
         "pagination" => %{"next_cursor" => "page-two", "prev_cursor" => Map.get(opts, :cursor), "limit" => 1}
       }}
    end

    def query("in:test_optional_rows", _opts) do
      notify_query("in:test_optional_rows")
      {:ok, %{"results" => [%{"id" => "row-optional", "value" => 9}], "pagination" => %{"limit" => 1}}}
    end

    def query("in:test_flaky_rows", _opts) do
      notify_query("in:test_flaky_rows")

      case Application.get_env(:serviceradar_web_ng, :dashboard_frame_flaky_mode) do
        :error -> {:error, :flaky_error}
        _ -> {:ok, %{"results" => [%{"id" => "row-good", "value" => 13}], "pagination" => %{"limit" => 1}}}
      end
    end

    def query("in:test_slow_rows", _opts) do
      if pid = Application.get_env(:serviceradar_web_ng, :dashboard_frame_test_pid) do
        send(pid, {:srql_query_started, "in:test_slow_rows", self()})
      end

      receive do
        :release_dashboard_frame_query ->
          {:ok, %{"results" => [%{"id" => "row-slow", "value" => 11}], "pagination" => %{"limit" => 1}}}
      after
        5_000 ->
          {:error, :timeout}
      end
    end

    def query_arrow("in:test_arrow", _opts) do
      {:ok, %{payload: "arrow bytes", schema: %{"columns" => ["id"]}}}
    end

    defp notify_query(query) do
      if pid = Application.get_env(:serviceradar_web_ng, :dashboard_frame_test_pid) do
        send(pid, {:srql_query, query})
      end
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
    token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

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

  test "pages one frame through the existing SRQL cursor without replacing the query", %{user: user, scope: scope} do
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "rows", "query" => "in:test_paged_rows", "encoding" => "json_rows", "limit" => 1}]
    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames)

    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert_push "frames:replace", %{"frames" => [%{"id" => "rows", "results" => [%{"id" => "row-1"}]}]}

    ref = push(socket, "frames:page", %{"frame_id" => "rows", "cursor" => "page-two"})
    assert_reply ref, :ok, %{}

    assert_push "frames:replace", %{
      "frames" => [
        %{
          "id" => "rows",
          "query" => "in:test_paged_rows",
          "results" => [%{"id" => "row-2"}]
        }
      ]
    }
  end

  test "streams Arrow IPC frame payloads as channel binary frames", %{user: user, scope: scope} do
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "arrow", "query" => "in:test_arrow", "encoding" => "arrow_ipc", "limit" => 1}]
    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

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

  test "skips optional frames until the stream token marks them active", %{user: user, scope: scope} do
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"

    data_frames = [
      %{"id" => "required", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1},
      %{"id" => "optional", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1, "required" => false}
    ]

    create_dashboard_instance!(route_slug, data_frames, scope)

    inactive_token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

    assert {:ok, _reply, _socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => inactive_token})

    assert_push "frames:replace", %{
      "frames" => [
        %{"id" => "required", "status" => "ok"}
      ]
    }

    active_token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id, ["optional"])

    assert {:ok, _reply, _socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => active_token})

    assert_push "frames:replace", %{
      "frames" => [
        %{"id" => "required", "status" => "ok"}
      ]
    }

    assert_push "frames:replace", %{
      "frames" => [
        %{"id" => "required", "status" => "ok"},
        %{"id" => "optional", "status" => "ok"}
      ]
    }
  end

  test "refresh ticks keep cached optional frames without re-running them", %{user: user, scope: scope} do
    Application.put_env(:serviceradar_web_ng, :dashboard_frame_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :dashboard_frame_test_pid)
    end)

    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"

    data_frames = [
      %{"id" => "required", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1},
      %{
        "id" => "optional",
        "query" => "in:test_optional_rows",
        "encoding" => "json_rows",
        "limit" => 1,
        "required" => false
      }
    ]

    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id, ["optional"])

    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert_push "frames:replace", %{
      "frames" => [
        %{"id" => "required", "status" => "ok"}
      ]
    }

    assert_push "frames:replace", %{
      "frames" => [
        %{"id" => "required", "status" => "ok"},
        %{"id" => "optional", "status" => "ok"}
      ]
    }

    assert_receive {:srql_query, "in:test_rows"}
    assert_receive {:srql_query, "in:test_optional_rows"}
    refute_receive {:srql_query, _query}, 50

    send(socket.channel_pid, :dashboard_frame_tick)

    assert_receive {:srql_query, "in:test_rows"}
    refute_receive {:srql_query, "in:test_optional_rows"}, 100
  end

  test "active optional frames do not block the required-frame update", %{user: user, scope: scope} do
    Application.put_env(:serviceradar_web_ng, :dashboard_frame_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :dashboard_frame_test_pid)
    end)

    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"

    data_frames = [
      %{"id" => "required", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1},
      %{
        "id" => "optional",
        "query" => "in:test_slow_rows",
        "encoding" => "json_rows",
        "limit" => 1,
        "required" => false
      }
    ]

    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id, ["optional"])

    assert {:ok, _reply, _socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert_push "frames:replace", %{
      "frames" => [%{"id" => "required", "status" => "ok"}]
    }

    assert_receive {:srql_query_started, "in:test_slow_rows", optional_query_pid}
    send(optional_query_pid, :release_dashboard_frame_query)

    assert_push "frames:replace", %{
      "frames" => [
        %{"id" => "required", "status" => "ok"},
        %{"id" => "optional", "status" => "ok"}
      ]
    }
  end

  test "refresh errors preserve last successful frame results as stale", %{user: user, scope: scope} do
    Application.put_env(:serviceradar_web_ng, :dashboard_frame_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :dashboard_frame_test_pid)
      Application.delete_env(:serviceradar_web_ng, :dashboard_frame_flaky_mode)
    end)

    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "flaky", "query" => "in:test_flaky_rows", "encoding" => "json_rows", "limit" => 1}]

    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert_push "frames:replace", %{
      "frames" => [
        %{"id" => "flaky", "status" => "ok", "results" => [%{"id" => "row-good", "value" => 13}]}
      ]
    }

    Application.put_env(:serviceradar_web_ng, :dashboard_frame_flaky_mode, :error)

    ref = push(socket, "frames:refresh", %{})
    assert_reply ref, :ok, %{}, 100

    assert_push "frames:replace", %{
      "frames" => [
        %{
          "id" => "flaky",
          "status" => "error",
          "error" => ":flaky_error",
          "stale" => true,
          "stale_reason" => ":flaky_error",
          "results" => [%{"id" => "row-good", "value" => 13}]
        }
      ]
    }
  end

  test "frame queries run outside the channel process", %{user: user, scope: scope} do
    Application.put_env(:serviceradar_web_ng, :dashboard_frame_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :dashboard_frame_test_pid)
    end)

    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "slow", "query" => "in:test_slow_rows", "encoding" => "json_rows", "limit" => 1}]

    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert_receive {:srql_query_started, "in:test_slow_rows", query_pid}

    ref = push(socket, "frames:refresh", %{})
    assert_reply ref, :ok, %{}, 100

    send(query_pid, :release_dashboard_frame_query)

    assert_push "frames:replace", %{
      "frames" => [
        %{"id" => "slow", "status" => "ok", "results" => [%{"id" => "row-slow", "value" => 11}]}
      ]
    }
  end

  test "rejects missing or mismatched stream tokens", %{user: user, scope: scope} do
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows"}]
    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token("other-route", data_frames, user.id)

    assert {:error, %{reason: "invalid_stream"}} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    assert {:error, %{reason: "missing_stream_token"}} =
             UserSocket
             |> socket("user-id", %{current_user: user, current_scope: scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{})
  end

  test "rejects a stream token minted for another user", %{user: user, scope: scope} do
    other = AccountsFixtures.user_fixture()
    other_scope = Scope.for_user(other, permissions: RBAC.permissions_for_user(other))
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows"}]
    create_dashboard_instance!(route_slug, data_frames, scope)
    token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

    assert {:error, %{reason: "unauthorized"}} =
             UserSocket
             |> socket("other-user", %{current_user: other, current_scope: other_scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})
  end

  test "rejects a still-valid token after the view grant is revoked", %{scope: owner_scope} do
    alias ServiceRadar.Actors.SystemActor
    alias ServiceRadar.Dashboards.DashboardInstanceAccessGrant

    viewer = AccountsFixtures.user_fixture(%{role: :viewer})
    viewer_scope = Scope.for_user(viewer, permissions: RBAC.permissions_for_user(viewer))
    route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
    data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows"}]

    instance =
      create_dashboard_instance!(route_slug, data_frames, owner_scope, %{
        visibility: :shared,
        owner_id: owner_scope.user.id
      })

    {:ok, grant} =
      DashboardInstanceAccessGrant
      |> Ash.Changeset.for_create(:create, %{
        dashboard_instance_id: instance.id,
        subject_user_id: viewer.id,
        access: :view,
        granted_by_id: owner_scope.user.id
      })
      |> Ash.create(actor: SystemActor.system(:test))

    token = DashboardFrameChannel.stream_token(route_slug, data_frames, viewer.id)

    assert {:ok, _reply, _socket} =
             UserSocket
             |> socket("viewer-id", %{current_user: viewer, current_scope: viewer_scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    :ok = Ash.destroy(grant, actor: SystemActor.system(:test))

    assert {:error, %{reason: "dashboard_unavailable"}} =
             UserSocket
             |> socket("viewer-id", %{current_user: viewer, current_scope: viewer_scope})
             |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})
  end

  defp create_dashboard_instance!(route_slug, data_frames, scope, extra \\ %{}) do
    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, package_attrs(data_frames))
      |> Ash.create!(scope: scope)

    DashboardInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          dashboard_package_id: package.id,
          name: "Test Dashboard",
          route_slug: route_slug,
          placement: :custom,
          enabled: true,
          settings: %{},
          metadata: %{}
        },
        extra
      )
    )
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
