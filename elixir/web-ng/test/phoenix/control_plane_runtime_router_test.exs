defmodule ServiceRadarWebNGWeb.ControlPlaneRuntimeRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarWebNGWeb.ControlPlanePasswordResetDeliveryFake
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  @moduletag :db_free

  @runtime_token "test-control-plane-runtime-token-with-more-than-32-bytes"
  @authorization_header "x-serviceradar-control-plane-authorization"

  setup do
    previous_runtime = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    previous_delivery = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_delivery)
    previous_response = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_test_response)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_test_pid)

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime, token: @runtime_token, port: 4001)

    Application.put_env(
      :serviceradar_web_ng,
      :control_plane_password_reset_delivery,
      ControlPlanePasswordResetDeliveryFake
    )

    Application.put_env(:serviceradar_web_ng, :control_plane_password_reset_test_pid, self())

    on_exit(fn ->
      restore_env(:control_plane_runtime, previous_runtime)
      restore_env(:control_plane_password_reset_delivery, previous_delivery)
      restore_env(:control_plane_password_reset_test_response, previous_response)
      restore_env(:control_plane_password_reset_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "rejects a missing bearer credential without invoking delivery" do
    conn = request(%{"email" => "owner@example.com"})

    assert conn.status == 401
    assert json_response(conn) == %{"status" => "unauthorized"}
    refute_received {:password_reset_requested, _email}
  end

  test "rejects an incorrect bearer credential without exposing token details" do
    conn = request(%{"email" => "owner@example.com"}, "wrong-token-with-more-than-32-bytes")

    assert conn.status == 401
    assert json_response(conn) == %{"status" => "unauthorized"}
    refute conn.resp_body =~ "wrong-token"
    refute_received {:password_reset_requested, _email}
  end

  test "does not accept the standard Authorization header" do
    conn =
      :post
      |> conn("/v1/password-reset", Jason.encode!(%{"email" => "owner@example.com"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{@runtime_token}")
      |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

    assert conn.status == 401
    assert json_response(conn) == %{"status" => "unauthorized"}
    refute_received {:password_reset_requested, _email}
  end

  test "accepts the dedicated control-plane bearer header even when Kubernetes authorization is present" do
    set_delivery_response({:ok, :smtp_accepted})

    conn =
      :post
      |> conn("/v1/password-reset", Jason.encode!(%{"email" => "owner@example.com"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer kubernetes-api-credential")
      |> put_req_header(@authorization_header, "Bearer #{@runtime_token}")
      |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

    assert conn.status == 202
    assert json_response(conn) == %{"status" => "smtp_accepted"}
    assert_received {:password_reset_requested, "owner@example.com"}
  end

  test "returns accepted only after the mail adapter accepts the reset message" do
    set_delivery_response({:ok, :smtp_accepted})

    conn = request(%{"email" => "owner@example.com"}, @runtime_token)

    assert conn.status == 202
    assert json_response(conn) == %{"status" => "smtp_accepted"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert_received {:password_reset_requested, "owner@example.com"}
  end

  test "returns one non-enumerating failure for unknown users and SMTP rejection" do
    Enum.each([:request_rejected, :smtp_delivery_failed], fn reason ->
      set_delivery_response({:error, reason})

      conn = request(%{"email" => "owner@example.com"}, @runtime_token)

      assert conn.status == 502
      assert json_response(conn) == %{"status" => "delivery_failed"}
    end)
  end

  test "rejects malformed input without invoking delivery" do
    conn = request(%{"not_email" => "owner@example.com"}, @runtime_token)

    assert conn.status == 400
    assert json_response(conn) == %{"status" => "invalid_request"}
    refute_received {:password_reset_requested, _email}
  end

  test "does not expose delivery details for an unknown route" do
    set_delivery_response({:ok, :smtp_accepted})

    conn =
      :post
      |> conn("/v1/not-a-runtime-operation", Jason.encode!(%{"email" => "owner@example.com"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header(@authorization_header, "Bearer #{@runtime_token}")
      |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

    assert conn.status == 404
    assert json_response(conn) == %{"status" => "not_found"}
    refute_received {:password_reset_requested, _email}
  end

  test "rejects an empty email with a bounded response" do
    set_delivery_response({:error, :invalid_request})

    conn = request(%{"email" => ""}, @runtime_token)

    assert conn.status == 400
    assert json_response(conn) == %{"status" => "invalid_request"}
  end

  test "authenticates archive requests before reading their bodies" do
    for method <- [:put, :get] do
      conn =
        method
        |> conn("/v1/archive-bindings/not-a-uuid/qualification", "invalid-json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{@runtime_token}")
        |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

      assert conn.status == 401
      assert json_response(conn) == %{"status" => "unauthorized"}
    end
  end

  test "rejects malformed and duplicate-key archive JSON before interpreting it" do
    for body <- [
          "{",
          "[]",
          ~s({"revision":1,"revision":2}),
          ~s({"report":{"credential":{"generation":1,"generation":2}}}),
          ~s({"revision":1,"revi\\u0073ion":1})
        ] do
      conn = archive_request(body)
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_request"}
    end
  end

  test "bounds archive JSON bytes and requires its media type" do
    body = ~s({"schema_version":1,"revision":1,"state":"withdrawn","report":null})
    padded = body <> String.duplicate(" ", 16_384 - byte_size(body))

    conn = archive_request(padded)
    assert conn.status == 400
    assert json_response(conn) == %{"status" => "invalid_archive_binding_id"}

    conn = archive_request(padded <> " ")
    assert conn.status == 413
    assert json_response(conn) == %{"status" => "request_too_large"}

    conn = archive_request(body, "text/plain")
    assert conn.status == 415
    assert json_response(conn) == %{"status" => "unsupported_media_type"}
  end

  defp archive_request(body, content_type \\ "application/json") do
    :put
    |> conn("/v1/archive-bindings/not-a-uuid/qualification", body)
    |> put_req_header("content-type", content_type)
    |> put_req_header(@authorization_header, "Bearer #{@runtime_token}")
    |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))
  end

  defp request(params, token \\ nil) do
    conn =
      :post
      |> conn("/v1/password-reset", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")

    conn =
      if token do
        put_req_header(conn, @authorization_header, "Bearer #{token}")
      else
        conn
      end

    ControlPlaneRuntimeRouter.call(conn, ControlPlaneRuntimeRouter.init([]))
  end

  defp set_delivery_response(response) do
    Application.put_env(:serviceradar_web_ng, :control_plane_password_reset_test_response, response)
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
