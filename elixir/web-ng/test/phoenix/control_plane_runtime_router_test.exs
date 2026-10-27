defmodule ServiceRadarWebNGWeb.ControlPlaneRuntimeRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarWebNG.ControlPlaneRuntimeAccess
  alias ServiceRadarWebNGWeb.ControlPlanePasswordResetDeliveryFake
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  @moduletag :db_free

  @runtime_token "test-control-plane-runtime-token-with-more-than-32-bytes"
  @media_token "synthetic-media-installation-token-with-more-than-32-bytes"
  @deployment_ref "ce032564-a123-4bc5-89ab-000000000001"
  @authorization_header "x-serviceradar-control-plane-authorization"
  @deployment_header "x-serviceradar-deployment-ref"
  @generation_header "x-serviceradar-media-generation"

  setup do
    previous_runtime = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    previous_delivery = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_delivery)
    previous_response = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_test_response)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_test_pid)

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @runtime_token,
      port: 4001,
      media: [token: @media_token, deployment_ref: @deployment_ref, generation: "1"]
    )

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

  test "media authentication cannot cross purposes or omit the installed identity" do
    for {header, value} <- [
          {@authorization_header, "Bearer " <> @runtime_token},
          {@deployment_header, "ce032564-a123-4bc5-89ab-000000000002"},
          {@generation_header, "2"},
          {@generation_header, "01"}
        ],
        {method, path} <- [
          {:put, "/v1/media/installation"},
          {:post, "/v1/media/archive-bindings"},
          {:post, "/v1/%6dedia/archive-bindings"},
          {:put, "/v1/media/configuration"},
          {:put, "/v1/media/init-authorities/not-a-uuid"},
          {:put, "/v1/media/init-authorities/not-a-uuid/revoke"},
          {:put, "/v1/media/manifest-authorities/not-a-uuid"},
          {:post, "/v1/media/manifest-authorities/not-a-uuid/revoke"},
          {:put, "/v%31/%6dedia/%6danifest-authorities/not-a-uuid"},
          {:put, "/v1/archive-bindings/not-a-uuid/qualification"}
        ] do
      conn =
        method
        |> conn(path, "invalid-json")
        |> media_headers()
        |> put_req_header(header, value)
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 401
      assert json_response(conn) == %{"status" => "unauthorized"}
    end

    for header <- [@authorization_header, @deployment_header, @generation_header],
        {method, path} <- [
          {:get, "/v1/media/installation"},
          {:get, "/v1/media/configuration"},
          {:get, "/v1/media/manifest-authorities/not-a-uuid"},
          {:post, "/v1/media/archive-bindings"},
          {:post, "/v1/%6dedia/archive-bindings"}
        ] do
      conn = method |> conn(path) |> media_headers()
      missing = conn |> delete_req_header(header) |> ControlPlaneRuntimeRouter.call([])
      assert missing.status == 401

      duplicate = %{conn | req_headers: [{header, "duplicate"} | conn.req_headers]}
      assert ControlPlaneRuntimeRouter.call(duplicate, []).status == 401
    end

    assert request(%{"email" => "owner@example.com"}, @media_token).status == 401
    refute_received {:password_reset_requested, _email}
  end

  test "installation reports the authenticated process identity without storage authority" do
    conn = :get |> conn("/v1/media/installation") |> media_headers() |> ControlPlaneRuntimeRouter.call([])

    assert conn.status == 200

    assert json_response(conn) == %{
             "schema_version" => 1,
             "status" => "installed",
             "deployment_ref" => @deployment_ref,
             "generation" => "1",
             "applied_revision" => nil,
             "readiness" => "unavailable",
             "reason" => "media_authentication_only"
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute conn.resp_body =~ @media_token
    refute conn.resp_body =~ @runtime_token
  end

  test "encoded media route segments cannot select account authentication" do
    for path <- ["/v1/%6dedia/installation", "/v%31/media/installation"] do
      conn =
        :get
        |> conn(path)
        |> media_headers()
        |> put_req_header(@authorization_header, "Bearer " <> @runtime_token)
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 401
      assert json_response(conn) == %{"status" => "unauthorized"}
    end
  end

  test "incomplete or invalid installations stay closed while account operations remain available" do
    previous = Application.fetch_env!(:serviceradar_web_ng, :control_plane_runtime)
    valid = Keyword.fetch!(previous, :media)

    for media <- [
          [],
          Keyword.delete(valid, :deployment_ref),
          Keyword.put(valid, :deployment_ref, String.upcase(@deployment_ref)),
          Keyword.put(valid, :token, @runtime_token),
          Keyword.put(valid, :token, "short"),
          Keyword.put(valid, :token, String.duplicate("x", 513)),
          Keyword.put(valid, :generation, "0"),
          Keyword.put(valid, :generation, "01"),
          Keyword.put(valid, :generation, "+1"),
          Keyword.put(valid, :generation, "1 "),
          Keyword.put(valid, :generation, "9223372036854775808")
        ] do
      Application.put_env(:serviceradar_web_ng, :control_plane_runtime, Keyword.put(previous, :media, media))
      assert ControlPlaneRuntimeAccess.enabled?()

      conn = :get |> conn("/v1/media/installation") |> media_headers() |> ControlPlaneRuntimeRouter.call([])
      assert conn.status == 401
      assert json_response(conn) == %{"status" => "unauthorized"}
    end

    set_delivery_response({:ok, :smtp_accepted})
    assert request(%{"email" => "owner@example.com"}, @runtime_token).status == 202
    assert_received {:password_reset_requested, "owner@example.com"}

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime, media: [])
    refute ControlPlaneRuntimeAccess.enabled?()
  end

  test "a replacement media installation accepts only its own identity and token without an account token" do
    replacement_token = "synthetic-replacement-media-token-with-more-than-32-bytes"
    replacement_ref = "ce032564-a123-4bc5-89ab-000000000002"

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      media: [token: replacement_token, deployment_ref: replacement_ref, generation: "9223372036854775807"]
    )

    assert ControlPlaneRuntimeAccess.enabled?()

    previous = :get |> conn("/v1/media/installation") |> media_headers()
    assert ControlPlaneRuntimeRouter.call(previous, []).status == 401

    installed =
      previous
      |> put_req_header(@authorization_header, "Bearer " <> replacement_token)
      |> put_req_header(@deployment_header, replacement_ref)
      |> put_req_header(@generation_header, "9223372036854775807")
      |> ControlPlaneRuntimeRouter.call([])

    assert installed.status == 200
    assert json_response(installed)["deployment_ref"] == replacement_ref
    assert json_response(installed)["generation"] == "9223372036854775807"
    assert request(%{"email" => "owner@example.com"}, @runtime_token).status == 401
    refute_received {:password_reset_requested, _email}
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

  test "rejects ambiguous recording JSON before interpreting the stop document" do
    for path <- ["/v1/media/configuration", "/v%31/%6dedia/%63onfiguration"],
        body <- [
          "{",
          "[]",
          ~s({"contract_version":1,"revision":"1","revision":"2","admission":"stopped"}),
          ~s({"contract_version":1,"revision":"1","admission":"stopped","admiss\\u0069on":"stopped"}),
          ~s({"nested":{"revision":"1","revision":"2"}})
        ] do
      conn = configuration_request(body, path)
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_request"}
    end
  end

  test "recording requests cannot smuggle enablement or origin through the document" do
    valid = %{"contract_version" => 1, "revision" => "1", "admission" => "stopped"}

    for document <- [
          Map.put(valid, "admission", "enabled"),
          Map.put(valid, "admission", "resume"),
          Map.put(valid, "deployment_ref", @deployment_ref),
          Map.put(valid, "generation", "1"),
          Map.put(valid, "actor", "system"),
          Map.put(valid, "contract_version", 2),
          Map.put(valid, "revision", 1),
          Map.put(valid, "revision", "01"),
          Map.put(valid, "revision", "9223372036854775808"),
          Map.delete(valid, "admission")
        ] do
      conn = configuration_request(Jason.encode!(document))
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_recording_configuration"}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  test "recording body limit and media type precede document validation on encoded routes too" do
    body = ~s({"contract_version":2,"revision":"1","admission":"stopped"})
    padded = body <> String.duplicate(" ", 1_024 - byte_size(body))

    for path <- ["/v1/media/configuration", "/v%31/%6dedia/%63onfiguration"] do
      conn = configuration_request(padded, path)
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_recording_configuration"}

      conn = configuration_request(padded <> " ", path)
      assert conn.status == 413
      assert json_response(conn) == %{"status" => "request_too_large"}

      conn = configuration_request(body, path, "text/plain")
      assert conn.status == 415
      assert json_response(conn) == %{"status" => "unsupported_media_type"}

      conn =
        :post
        |> conn(path, "invalid-json")
        |> media_headers()
        |> put_req_header("content-type", "application/json")
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 404
      assert json_response(conn) == %{"status" => "not_found"}
    end
  end

  test "archive registration rejects duplicate keys before the general JSON parser" do
    for path <- ["/v1/media/archive-bindings", "/v%31/%6dedia/archive-bindings"],
        body <- [
          "{",
          "[]",
          ~s({"schema_version":1,"schema_version":1,"destination":{}}),
          ~s({"schema_version":1,"destination":{"generation":1,"generation":2}}),
          ~s({"schema_version":1,"destination":{"generation":1,"generat\\u0069on":1}})
        ] do
      conn = binding_request(body, path)
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_request"}
    end
  end

  test "archive registration validates its exact envelope and destination before storage" do
    destination = %{
      "schema_version" => 1,
      "provisioning_ref" => "synthetic-binding-input",
      "generation" => 1,
      "purpose" => "recording",
      "provider" => "s3_compatible",
      "endpoint" => "https://objects.example.com",
      "region" => "example-region",
      "bucket" => "synthetic-recordings",
      "namespace" => "recordings/v1",
      "archive_format_version" => 1,
      "required_encryption" => "sse_s3_aes256"
    }

    valid = %{"schema_version" => 1, "destination" => destination}

    for document <- [
          Map.put(valid, "schema_version", 2),
          Map.put(valid, "actor", "system"),
          Map.put(valid, "deployment_ref", @deployment_ref),
          Map.delete(valid, "destination")
        ] do
      conn = binding_request(Jason.encode!(document))
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_archive_registration"}
    end

    for invalid <- [
          Map.put(destination, "generation", "1"),
          Map.put(destination, "purpose", "evidence"),
          Map.put(destination, "access_key_id", "synthetic-forbidden-credential"),
          Map.put(destination, "endpoint", "https://objects.example.com/path"),
          Map.delete(destination, "required_encryption")
        ] do
      conn = binding_request(Jason.encode!(%{valid | "destination" => invalid}))
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_archive_destination"}
    end
  end

  test "archive registration enforces the bounded JSON media contract on literal and encoded routes" do
    body = ~s({"schema_version":2,"destination":{}})
    padded = body <> String.duplicate(" ", 4096 - byte_size(body))

    for path <- ["/v1/media/archive-bindings", "/v%31/%6dedia/archive-bindings"] do
      conn = binding_request(padded, path)
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_archive_registration"}
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      conn = binding_request(padded <> " ", path)
      assert conn.status == 413
      assert json_response(conn) == %{"status" => "request_too_large"}

      conn = binding_request(body, path, "text/plain")
      assert conn.status == 415
      assert json_response(conn) == %{"status" => "unsupported_media_type"}
    end
  end

  test "malformed authority bodies use the route status and stay HTTP 400" do
    path_id = "11111111-1111-4111-8111-111111111111"
    other_id = "22222222-2222-4222-8222-222222222222"

    documents = [
      %{},
      %{"binding_id" => other_id},
      %{"desired" => %{"binding_id" => other_id}},
      %{"binding_id" => other_id, "desired" => %{"binding_id" => other_id}},
      %{"binding_id" => 1},
      %{"desired" => %{}}
    ]

    for {collection, status} <- [
          {"init-authorities", "invalid_init_authority"},
          {"media-authorities", "invalid_media_authority"},
          {"manifest-authorities", "invalid_manifest_authority"}
        ],
        document <- documents,
        {method, suffix} <- [{:put, ""}, {:post, "/revoke"}] do
      conn = authority_request(method, "/v1/media/#{collection}/#{path_id}#{suffix}", document)

      assert conn.status == 400
      assert json_response(conn) == %{"status" => status}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  defp authority_request(method, path, document) do
    method
    |> conn(path, Jason.encode!(document))
    |> put_req_header("content-type", "application/json")
    |> media_headers()
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp binding_request(body, path \\ "/v1/media/archive-bindings", content_type \\ "application/json") do
    :post
    |> conn(path, body)
    |> put_req_header("content-type", content_type)
    |> media_headers()
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp configuration_request(body, path \\ "/v1/media/configuration", content_type \\ "application/json") do
    :put
    |> conn(path, body)
    |> put_req_header("content-type", content_type)
    |> media_headers()
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp archive_request(body, content_type \\ "application/json") do
    :put
    |> conn("/v1/archive-bindings/not-a-uuid/qualification", body)
    |> put_req_header("content-type", content_type)
    |> media_headers()
    |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))
  end

  defp media_headers(conn) do
    conn
    |> put_req_header(@authorization_header, "Bearer " <> @media_token)
    |> put_req_header(@deployment_header, @deployment_ref)
    |> put_req_header(@generation_header, "1")
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
