defmodule ServiceRadarWebNGWeb.Api.AutomationCallbackGrantControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNGWeb.Api.AutomationCallbackGrantController
  alias ServiceRadarWebNGWeb.Plugs.AutomationCallbackRequestGuard
  alias ServiceRadarWebNGWeb.Plugs.AutomationCallbackResponseHeaders
  alias ServiceRadarWebNGWeb.Plugs.RateLimit
  alias ServiceRadarWebNGWeb.Plugs.SafeParsers

  @moduletag :db_free

  @grant_id "0190a4c2-1000-7000-8000-000000000009"
  @path "/api/v1/automation/callback-grants/#{@grant_id}/actions/remote_access.ssh_ca.bundle.read"
  @bearer String.duplicate("A", 43)
  @idempotency_key "srci_v1_" <> String.duplicate("B", 43)
  @denied ~s({"error":"callback_denied"})

  defmodule Consumer do
    @moduledoc false

    def consume(grant_id, bearer, idempotency_key, request, _opts) do
      send(self(), {:callback_consumed, grant_id, bearer, idempotency_key, request})
      Process.get(:automation_callback_result, {:error, :not_configured})
    end
  end

  setup_all do
    case Process.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _pid -> :ok
    end

    :ok
  end

  setup do
    previous_runtime = Application.get_env(:serviceradar_core, :automation_callback_grants)

    Application.put_env(:serviceradar_core, :automation_callback_grants,
      consumer: Consumer,
      verifier_config: []
    )

    :ets.delete_all_objects(RateLimiter.__table__())

    on_exit(fn ->
      restore_env(:automation_callback_grants, previous_runtime)
      :ets.delete_all_objects(RateLimiter.__table__())
    end)

    :ok
  end

  test "accepts only the callback bearer and returns canonical lifecycle bytes" do
    Process.put(:automation_callback_result, {
      :ok,
      %{status: 200, content_type: "application/json", body: ~s({"answer":"canonical"}), replay: false}
    })

    conn = AutomationCallbackGrantController.consume_ssh_ca_bundle(callback_request(), %{"grant_id" => @grant_id})

    assert conn.status == 200
    assert conn.resp_body == ~s({"answer":"canonical"})
    assert_private(conn)
    assert_receive {:callback_consumed, @grant_id, @bearer, @idempotency_key, received}
    assert received == request()
  end

  test "cookies, current-user assigns, and API keys cannot become callback authority" do
    Process.put(:automation_callback_result, {
      :ok,
      %{status: 200, content_type: "application/json", body: "{}", replay: false}
    })

    conn =
      callback_request()
      |> assign(:current_user, %{id: "admin"})
      |> assign(:current_scope, %{user: %{id: "admin"}})
      |> put_req_header("cookie", "_serviceradar_web_ng_key=user-session")
      |> put_req_header("x-api-key", "platform-admin-key")
      |> AutomationCallbackGrantController.consume_ssh_ca_bundle(%{"grant_id" => @grant_id})

    assert conn.status == 200
    assert_receive {:callback_consumed, @grant_id, @bearer, @idempotency_key, _}
  end

  test "current-user bearers, malformed headers, and strict request mismatches share one denial" do
    variants = [
      build_request([], request()),
      build_request([{"authorization", "bearer #{@bearer}"}], request()),
      build_request([{"authorization", "Bearer short"}], request()),
      build_request(
        [
          {"authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.user-token.signature"},
          {"idempotency-key", @idempotency_key},
          {"cookie", "session=admin"},
          {"x-api-key", "platform-admin"}
        ],
        request()
      ),
      build_request(
        [{"authorization", "Bearer #{@bearer}"}, {"idempotency-key", "short"}],
        request()
      ),
      build_request(
        [
          {"authorization", "Bearer #{@bearer}"},
          {"idempotency-key", @idempotency_key},
          {"idempotency-key", @idempotency_key}
        ],
        request()
      ),
      build_request(callback_headers(), Map.put(request(), "extra", true))
    ]

    Enum.each(variants, fn request_conn ->
      response =
        AutomationCallbackGrantController.consume_ssh_ca_bundle(request_conn, %{
          "grant_id" => @grant_id
        })

      assert response.status == 401
      assert response.resp_body == @denied
      assert_private(response)
    end)

    refute_receive {:callback_consumed, _, _, _, _}
  end

  test "pending and replay preserve the exact public wire contract" do
    Process.put(:automation_callback_result, {
      :retry,
      %{status: 409, code: "grant_pending", retryable: true, retry_after_seconds: 1}
    })

    pending = AutomationCallbackGrantController.consume_ssh_ca_bundle(callback_request(), %{"grant_id" => @grant_id})

    assert pending.status == 409
    assert pending.resp_body == ~s({"code":"grant_pending","retryable":true})
    assert get_resp_header(pending, "retry-after") == ["1"]
    assert_private(pending)

    committed = ~s({"action":"remote_access.ssh_ca.bundle.read","targets":[]})

    Process.put(:automation_callback_result, {
      :ok,
      %{status: 200, content_type: "application/json", body: committed, replay: true}
    })

    replay = AutomationCallbackGrantController.consume_ssh_ca_bundle(callback_request(), %{"grant_id" => @grant_id})

    assert replay.status == 200
    assert replay.resp_body == committed
  end

  test "authority contraction is indistinguishable from other callback denial" do
    for reason <- [:current_permission_denied, :tenant_changed, :target_no_longer_authorized] do
      Process.put(:automation_callback_result, {:error, reason})

      denied = AutomationCallbackGrantController.consume_ssh_ca_bundle(callback_request(), %{"grant_id" => @grant_id})

      assert denied.status == 401
      assert denied.resp_body == @denied
      assert_private(denied)
    end
  end

  test "parser, media, and accept denials are bounded, private, and compact" do
    parser_opts =
      SafeParsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: 67_108_864
      )

    malformed =
      :post
      |> conn(@path, "{")
      |> put_req_header("content-type", "application/json")
      |> SafeParsers.call(parser_opts)

    assert malformed.status == 401
    assert malformed.resp_body == @denied
    assert_private(malformed)

    oversized =
      :post
      |> conn(@path, Jason.encode!(Map.put(request(), "padding", String.duplicate("x", 4_096))))
      |> put_req_header("content-type", "application/json")
      |> SafeParsers.call(parser_opts)

    assert oversized.status == 401
    assert oversized.resp_body == @denied
    assert_private(oversized)

    for {header, value} <- [
          {"content-type", "text/plain"},
          {"accept", "text/html"},
          {"accept", "text/html, application/json;q=0"}
        ] do
      guarded =
        :post
        |> conn(@path, "{}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header(header, value)
        |> AutomationCallbackResponseHeaders.call([])
        |> AutomationCallbackRequestGuard.call([])

      assert guarded.status == 401
      assert guarded.resp_body == @denied
      assert_private(guarded)
    end
  end

  test "dedicated rate limiting never redirects or makes responses cacheable" do
    opts =
      RateLimit.init(
        bucket: :automation_callback_grant,
        subject: :ip,
        limit: 2,
        window_seconds: 60,
        response_mode: :json,
        json_body_builder: &ServiceRadarWebNGWeb.Plugs.RateLimit.Bodies.automation_callback/1
      )

    limited = fn ->
      :post
      |> conn(@path, "{}")
      |> AutomationCallbackResponseHeaders.call([])
      |> RateLimit.call(opts)
    end

    refute limited.().halted
    refute limited.().halted
    denied = limited.()

    assert denied.status == 429
    assert denied.resp_body == @denied
    assert get_resp_header(denied, "location") == []
    assert_private(denied)
  end

  test "router publishes only the exact POST action path" do
    route =
      Enum.find(ServiceRadarWebNGWeb.Router.__routes__(), fn route ->
        route.path ==
          "/api/v1/automation/callback-grants/:grant_id/actions/remote_access.ssh_ca.bundle.read"
      end)

    assert route.verb == :post
    assert route.plug == AutomationCallbackGrantController
    assert route.plug_opts == :consume_ssh_ca_bundle
  end

  defp callback_request, do: build_request(callback_headers(), request())

  defp build_request(headers, body) do
    :post
    |> conn(@path, "")
    |> Map.put(:req_headers, headers)
    |> Map.put(:body_params, body)
  end

  defp callback_headers do
    [
      {"authorization", "Bearer #{@bearer}"},
      {"idempotency-key", @idempotency_key},
      {"content-type", "application/json"}
    ]
  end

  defp request do
    %{
      "action" => "remote_access.ssh_ca.bundle.read",
      "schema_version" => "serviceradar.remote_access.ssh_ca_bundle/v1",
      "manifest_sha256" => String.duplicate("f", 64),
      "job_id" => 9_001,
      "phase" => "stage",
      "operation" => "enroll",
      "state" => "present"
    }
  end

  defp assert_private(conn) do
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
