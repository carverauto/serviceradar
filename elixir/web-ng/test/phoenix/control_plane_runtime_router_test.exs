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
  @entitlement_token "synthetic-entitlement-purpose-token-with-more-than-32-bytes"
  @media_worker_token "synthetic-media-worker-purpose-token-with-more-than-32-bytes"
  @deployment_ref "ce032564-a123-4bc5-89ab-000000000001"
  @authorization_header "x-serviceradar-control-plane-authorization"
  @deployment_header "x-serviceradar-deployment-ref"
  @generation_header "x-serviceradar-media-generation"
  @entitlement_generation_header "x-serviceradar-entitlement-generation"
  @media_worker_generation_header "x-serviceradar-media-worker-generation"

  defmodule FakeMediaWorkerGrantsIssuer do
    @moduledoc false
    def issue_read_grant(installation, document, opts) do
      if pid = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_test_pid) do
        send(pid, {:media_worker_read_grant_requested, installation, document, opts})
      end

      Application.get_env(
        :serviceradar_web_ng,
        :control_plane_media_worker_grants_test_response,
        {:error, :recording_gone}
      )
    end
  end

  setup do
    previous_runtime = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    previous_delivery = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_delivery)
    previous_response = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_test_response)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_test_pid)

    previous_grants_issuer =
      Application.get_env(:serviceradar_web_ng, :control_plane_media_worker_grants_issuer)

    previous_grants_response =
      Application.get_env(:serviceradar_web_ng, :control_plane_media_worker_grants_test_response)

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @runtime_token,
      port: 4001,
      media: [token: @media_token, deployment_ref: @deployment_ref, generation: "1"],
      entitlements: [token: @entitlement_token, deployment_ref: @deployment_ref, generation: "1"],
      media_worker: [token: @media_worker_token, deployment_ref: @deployment_ref, generation: "1"]
    )

    Application.put_env(
      :serviceradar_web_ng,
      :control_plane_password_reset_delivery,
      ControlPlanePasswordResetDeliveryFake
    )

    Application.put_env(
      :serviceradar_web_ng,
      :control_plane_media_worker_grants_issuer,
      FakeMediaWorkerGrantsIssuer
    )

    Application.put_env(:serviceradar_web_ng, :control_plane_password_reset_test_pid, self())

    on_exit(fn ->
      restore_env(:control_plane_runtime, previous_runtime)
      restore_env(:control_plane_password_reset_delivery, previous_delivery)
      restore_env(:control_plane_password_reset_test_response, previous_response)
      restore_env(:control_plane_password_reset_test_pid, previous_test_pid)
      restore_env(:control_plane_media_worker_grants_issuer, previous_grants_issuer)
      restore_env(:control_plane_media_worker_grants_test_response, previous_grants_response)
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

  test "entitlements authentication enforces strict 3-way domain separation across account, media, and storage routes" do
    storage_paths = [
      {:put, "/v1/storage/entitlement"},
      {:get, "/v1/storage/entitlement"},
      {:get, "/v1/storage/usage?from=2026-10-01"},
      {:get, "/v1/storage/holds"},
      {:put, "/v%31/%73torage/%65ntitlement"}
    ]

    for {header, value} <- [
          {@authorization_header, "Bearer " <> @runtime_token},
          {@authorization_header, "Bearer " <> @media_token},
          {@deployment_header, "ce032564-a123-4bc5-89ab-000000000002"},
          {@entitlement_generation_header, "2"},
          {@entitlement_generation_header, "01"},
          {@entitlement_generation_header, "+1"}
        ],
        {method, path} <- storage_paths do
      conn =
        method
        |> conn(path, "invalid-json")
        |> entitlement_headers()
        |> put_req_header(header, value)
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 401
      assert json_response(conn) == %{"status" => "unauthorized"}
      refute conn.resp_body =~ @entitlement_token
    end

    # Media generation header alone cannot satisfy entitlements authentication
    for {method, path} <- storage_paths do
      conn =
        method
        |> conn(path, "invalid-json")
        |> put_req_header(@authorization_header, "Bearer " <> @entitlement_token)
        |> put_req_header(@deployment_header, @deployment_ref)
        |> put_req_header(@generation_header, "1")
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 401
      assert json_response(conn) == %{"status" => "unauthorized"}
    end

    # Missing or duplicate required headers fail closed
    for header <- [@authorization_header, @deployment_header, @entitlement_generation_header],
        {method, path} <- storage_paths do
      base = method |> conn(path) |> entitlement_headers()
      assert ControlPlaneRuntimeRouter.call(delete_req_header(base, header), []).status == 401

      duplicate = %{base | req_headers: [{header, "duplicate"} | base.req_headers]}
      assert ControlPlaneRuntimeRouter.call(duplicate, []).status == 401
    end

    # Entitlement token cannot access account or media routes
    assert request(%{"email" => "owner@example.com"}, @entitlement_token).status == 401
    refute_received {:password_reset_requested, _email}

    media_with_entitlement_token =
      :get
      |> conn("/v1/media/installation")
      |> media_headers()
      |> put_req_header(@authorization_header, "Bearer " <> @entitlement_token)
      |> ControlPlaneRuntimeRouter.call([])

    assert media_with_entitlement_token.status == 401

    archive_creds_with_entitlement_token =
      :get
      |> conn("/v1/media/archive-credentials/writer")
      |> media_headers()
      |> put_req_header(@authorization_header, "Bearer " <> @entitlement_token)
      |> ControlPlaneRuntimeRouter.call([])

    assert archive_creds_with_entitlement_token.status == 401
  end

  test "entitlements installation refuses shared or malformed tokens and enables listener standalone" do
    previous = Application.fetch_env!(:serviceradar_web_ng, :control_plane_runtime)
    valid = Keyword.fetch!(previous, :entitlements)

    for invalid_ent <- [
          [],
          Keyword.put(valid, :token, @runtime_token),
          Keyword.put(valid, :token, @media_token),
          Keyword.put(valid, :token, "too-short-entitlement-token"),
          Keyword.put(valid, :token, String.duplicate("e", 513)),
          Keyword.delete(valid, :deployment_ref),
          Keyword.put(valid, :deployment_ref, String.upcase(@deployment_ref)),
          Keyword.put(valid, :generation, "0"),
          Keyword.put(valid, :generation, "01")
        ] do
      Application.put_env(
        :serviceradar_web_ng,
        :control_plane_runtime,
        Keyword.put(previous, :entitlements, invalid_ent)
      )

      conn =
        :get
        |> conn("/v1/storage/entitlement")
        |> entitlement_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 401
      assert json_response(conn) == %{"status" => "unauthorized"}
    end

    # Standalone entitlements configuration keeps ControlPlaneRuntimeAccess enabled
    Application.put_env(:serviceradar_web_ng, :control_plane_runtime, entitlements: valid)
    assert ControlPlaneRuntimeAccess.enabled?()
  end

  test "storage entitlement route enforces bounded JSON, duplicate-key rejection, and method bounds" do
    for path <- ["/v1/storage/entitlement", "/v%31/%73torage/%65ntitlement"],
        body <- [
          "{",
          "[]",
          ~s({"schema_version":1,"revision":1,"revision":2}),
          ~s({"schema_version":1,"revi\\u0073ion":1,"revision":1})
        ] do
      conn = entitlement_put_request(body, path)
      assert conn.status == 400
      assert json_response(conn) == %{"status" => "invalid_request"}
    end

    invalid_schema = ~s({"schema_version":2,"revision":1})
    padded = invalid_schema <> String.duplicate(" ", 16_384 - byte_size(invalid_schema))

    conn = entitlement_put_request(padded)
    assert conn.status in [400, 409]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    too_large = entitlement_put_request(padded <> " ")
    assert too_large.status == 413
    assert json_response(too_large) == %{"status" => "request_too_large"}

    wrong_type = entitlement_put_request(invalid_schema, "/v1/storage/entitlement", "text/plain")
    assert wrong_type.status == 415
    assert json_response(wrong_type) == %{"status" => "unsupported_media_type"}

    wrong_method =
      :post
      |> conn("/v1/storage/entitlement", "invalid-json")
      |> entitlement_headers()
      |> put_req_header("content-type", "application/json")
      |> ControlPlaneRuntimeRouter.call([])

    assert wrong_method.status == 404
    assert json_response(wrong_method) == %{"status" => "not_found"}

    unknown_subroute =
      :get
      |> conn("/v1/storage/unknown")
      |> entitlement_headers()
      |> ControlPlaneRuntimeRouter.call([])

    assert unknown_subroute.status == 404
    assert json_response(unknown_subroute) == %{"status" => "not_found"}
  end

  test "storage usage and holds routes validate bounded query parameters before hitting CNPG" do
    today = Date.to_iso8601(Date.utc_today())
    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    for bad_query <- [
          "",
          "from=not-a-date",
          "from=2026-10-01&to=not-a-date",
          "from=2026-10-10&to=2026-10-05",
          "from=2026-01-01&to=2026-02-05",
          "from=#{today}",
          "from=2026-10-01&to=#{today}",
          "from=#{tomorrow}",
          "from=2026-10-01&extra=1"
        ] do
      path = if bad_query == "", do: "/v1/storage/usage", else: "/v1/storage/usage?#{bad_query}"

      conn =
        :get
        |> conn(path)
        |> entitlement_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 400, "expected 400 for #{path}, got #{conn.status}"
    end

    for bad_holds_query <- [
          "limit=0",
          "limit=101",
          "limit=01",
          "limit=abc",
          "unknown=1"
        ] do
      conn =
        :get
        |> conn("/v1/storage/holds?#{bad_holds_query}")
        |> entitlement_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 400
    end
  end

  test "archive credentials route enforces media auth, allowed roles, and 4 KiB bounded JSON" do
    for bad_role <- ["admin", "owner", "delete", "writer/extra"] do
      conn =
        :get
        |> conn("/v1/media/archive-credentials/#{bad_role}")
        |> media_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert conn.status == 404
      assert json_response(conn) == %{"status" => "not_found"}
    end

    for role <- ["writer", "reader", "retention"] do
      dup_conn =
        :put
        |> conn(
          "/v1/media/archive-credentials/#{role}",
          ~s({"credential_generation":1,"credential_generation":2})
        )
        |> put_req_header("content-type", "application/json")
        |> media_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert dup_conn.status == 400
      assert json_response(dup_conn) == %{"status" => "invalid_request"}

      invalid_payload = ~s({"schema_version":2,"unknown":"field"})
      padded = invalid_payload <> String.duplicate(" ", 4_096 - byte_size(invalid_payload))

      exact_limit =
        :put
        |> conn("/v1/media/archive-credentials/#{role}", padded)
        |> put_req_header("content-type", "application/json")
        |> media_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert exact_limit.status == 400
      assert json_response(exact_limit) == %{"status" => "invalid_archive_credential_payload"}

      too_large =
        :put
        |> conn("/v1/media/archive-credentials/#{role}", padded <> " ")
        |> put_req_header("content-type", "application/json")
        |> media_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert too_large.status == 413
      assert json_response(too_large) == %{"status" => "request_too_large"}

      wrong_type =
        :put
        |> conn("/v1/media/archive-credentials/#{role}", invalid_payload)
        |> put_req_header("content-type", "text/plain")
        |> media_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert wrong_type.status == 415
      assert json_response(wrong_type) == %{"status" => "unsupported_media_type"}

      wrong_method =
        :post
        |> conn("/v1/media/archive-credentials/#{role}", "invalid-json")
        |> put_req_header("content-type", "application/json")
        |> media_headers()
        |> ControlPlaneRuntimeRouter.call([])

      assert wrong_method.status == 404
      assert json_response(wrong_method) == %{"status" => "not_found"}
    end
  end

  test "Telemetry.emit_camera_recording_storage_gauges is safe in db_free mode and emits all 4 gauges" do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    handler_id = "camera-recording-storage-gauges-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :camera_recording],
        &__MODULE__.forward_telemetry_event/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Safe with Repo unstarted in db_free test mode
    assert :ok = ServiceRadarWebNGWeb.Telemetry.emit_camera_recording_storage_gauges()

    assert_receive {:telemetry_event, [:serviceradar, :camera_recording], fallback_m, %{}}
    assert fallback_m.object_used_bytes == 0
    assert fallback_m.object_hard_limit_bytes == 0
    assert fallback_m.object_cutoff_days == -1.0
    assert fallback_m.object_held_bytes == 0

    # Emits supplied live gauge values accurately
    assert :ok =
             ServiceRadarWebNGWeb.Telemetry.emit_camera_recording_storage_gauges(
               gauges: %{
                 used_bytes: 53_687_091_200,
                 hard_limit_bytes: 107_374_182_400,
                 cutoff_days: 32.5,
                 held_bytes: 2_147_483_648
               }
             )

    assert_receive {:telemetry_event, [:serviceradar, :camera_recording], live_m, %{}}
    assert live_m.object_used_bytes == 53_687_091_200
    assert live_m.object_hard_limit_bytes == 107_374_182_400
    assert live_m.object_cutoff_days == 32.5
    assert live_m.object_held_bytes == 2_147_483_648
  end

  describe "POST /v1/media/workers/read-grants (Stage 1.6)" do
    test "enforces 4-way token domain separation across account, media, entitlements, and media_worker" do
      for reused <- [@runtime_token, @media_token, @entitlement_token] do
        Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
          token: @runtime_token,
          port: 4001,
          media: [token: @media_token, deployment_ref: @deployment_ref, generation: "1"],
          entitlements: [token: @entitlement_token, deployment_ref: @deployment_ref, generation: "1"],
          media_worker: [token: reused, deployment_ref: @deployment_ref, generation: "1"]
        )

        refute ControlPlaneRuntimeAccess.media_worker_enabled?()

        conn =
          :post
          |> conn("/v1/media/workers/read-grants", Jason.encode!(%{job_id: Ecto.UUID.generate()}))
          |> put_req_header("content-type", "application/json")
          |> put_req_header(@authorization_header, "Bearer " <> reused)
          |> put_req_header(@deployment_header, @deployment_ref)
          |> put_req_header(@media_worker_generation_header, "1")
          |> ControlPlaneRuntimeRouter.call([])

        assert conn.status == 401
        assert json_response(conn) == %{"status" => "unauthorized"}
        refute_received {:media_worker_read_grant_requested, _, _, _}
      end
    end

    test "rejects cross-domain tokens, human Authorization headers, and missing media-worker generation headers" do
      payload = Jason.encode!(%{"job_id" => Ecto.UUID.generate()})

      for wrong_token <- [@runtime_token, @media_token, @entitlement_token, "wrong-worker-token-with-more-than-32-bytes"] do
        conn =
          :post
          |> conn("/v1/media/workers/read-grants", payload)
          |> put_req_header("content-type", "application/json")
          |> put_req_header(@authorization_header, "Bearer " <> wrong_token)
          |> put_req_header(@deployment_header, @deployment_ref)
          |> put_req_header(@media_worker_generation_header, "1")
          |> ControlPlaneRuntimeRouter.call([])

        assert conn.status == 401
        assert json_response(conn) == %{"status" => "unauthorized"}
        refute conn.resp_body =~ wrong_token
        refute_received {:media_worker_read_grant_requested, _, _, _}
      end

      human_conn =
        :post
        |> conn("/v1/media/workers/read-grants", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> @media_worker_token)
        |> put_req_header(@deployment_header, @deployment_ref)
        |> put_req_header(@media_worker_generation_header, "1")
        |> ControlPlaneRuntimeRouter.call([])

      assert human_conn.status == 401
      refute_received {:media_worker_read_grant_requested, _, _, _}

      missing_gen_conn =
        :post
        |> conn("/v1/media/workers/read-grants", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header(@authorization_header, "Bearer " <> @media_worker_token)
        |> put_req_header(@deployment_header, @deployment_ref)
        |> put_req_header(@generation_header, "1")
        |> ControlPlaneRuntimeRouter.call([])

      assert missing_gen_conn.status == 401
      refute_received {:media_worker_read_grant_requested, _, _, _}
    end

    test "media_worker token cannot access account, media, or entitlement endpoints" do
      reset_conn =
        :post
        |> conn("/v1/password-reset", Jason.encode!(%{"email" => "owner@example.com"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header(@authorization_header, "Bearer " <> @media_worker_token)
        |> ControlPlaneRuntimeRouter.call([])

      assert reset_conn.status == 401

      media_conn =
        :put
        |> conn("/v1/media/configuration", "{}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header(@authorization_header, "Bearer " <> @media_worker_token)
        |> put_req_header(@deployment_header, @deployment_ref)
        |> put_req_header(@generation_header, "1")
        |> ControlPlaneRuntimeRouter.call([])

      assert media_conn.status == 401

      ent_conn =
        :put
        |> conn("/v1/storage/entitlement", "{}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header(@authorization_header, "Bearer " <> @media_worker_token)
        |> put_req_header(@deployment_header, @deployment_ref)
        |> put_req_header(@entitlement_generation_header, "1")
        |> ControlPlaneRuntimeRouter.call([])

      assert ent_conn.status == 401
    end

    test "returns 200 read plan with Cache-Control: no-store and redacts RedactedCredential secrets" do
      job_id = "00000000-0000-4000-8000-000000000901"
      entry_id = "00000000-0000-4000-8000-000000000902"
      desc_sha = String.duplicate("ab", 32)
      secret_marker = "synthetic-do-not-echo-s3-secret-material"

      redacted = %ServiceRadar.Camera.VisualWorkerReadGrants.RedactedCredential{
        reference: "secret:00000000-0000-4000-8000-000000000903",
        generation: 1,
        role: :reader,
        secret_id: "00000000-0000-4000-8000-000000000903",
        access_key_id: "SYNTHETIC_ACCESS_KEY",
        secret_access_key: secret_marker
      }

      Application.put_env(
        :serviceradar_web_ng,
        :control_plane_media_worker_grants_test_response,
        {:ok,
         %{
           schema_version: 1,
           backing: :archive,
           source: "archive",
           job_id: job_id,
           catalog_entry_id: entry_id,
           ttl_seconds: 300,
           grant: %{"role" => "reader", "allowed_methods" => ["GET", "HEAD"]},
           credential: redacted
         }}
      )

      conn =
        media_worker_grant_request(
          Jason.encode!(%{
            "schema_version" => 1,
            "job_id" => job_id,
            "catalog_entry_id" => entry_id,
            "descriptor_sha256" => desc_sha
          })
        )

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      refute conn.resp_body =~ secret_marker
      refute conn.resp_body =~ "SYNTHETIC_ACCESS_KEY"
      refute conn.resp_body =~ @media_worker_token

      body = json_response(conn)
      assert body["source"] == "archive"
      assert body["grant"]["role"] == "reader"
      assert body["grant"]["allowed_methods"] == ["GET", "HEAD"]
      assert body["credential"]["role"] == "reader"
      refute Map.has_key?(body["credential"], "secret_access_key")

      assert_received {:media_worker_read_grant_requested, installation, decoded_doc, _opts}
      assert installation == %{purpose: :media_worker, deployment_ref: @deployment_ref, generation: 1}
      assert decoded_doc["job_id"] == job_id
    end

    test "maps deleted/quarantined entries to 410 Gone, conflicts to 409, bad requests to 400, and bounds body <= 8192 bytes" do
      Application.put_env(
        :serviceradar_web_ng,
        :control_plane_media_worker_grants_test_response,
        {:error, :recording_gone}
      )

      gone_conn = media_worker_grant_request(Jason.encode!(%{"job_id" => Ecto.UUID.generate()}))
      assert gone_conn.status == 410
      assert json_response(gone_conn) == %{"status" => "recording_gone"}
      assert get_resp_header(gone_conn, "cache-control") == ["no-store"]

      Application.put_env(
        :serviceradar_web_ng,
        :control_plane_media_worker_grants_test_response,
        {:error, :descriptor_sha256_mismatch}
      )

      conflict_conn = media_worker_grant_request(Jason.encode!(%{"job_id" => Ecto.UUID.generate()}))
      assert conflict_conn.status == 409
      assert json_response(conflict_conn) == %{"status" => "descriptor_sha256_mismatch"}

      Application.put_env(
        :serviceradar_web_ng,
        :control_plane_media_worker_grants_test_response,
        {:error, :invalid_read_grant_request}
      )

      bad_conn = media_worker_grant_request(Jason.encode!(%{"job_id" => "bad"}))
      assert bad_conn.status == 400
      assert json_response(bad_conn) == %{"status" => "invalid_read_grant_request"}

      oversized = Jason.encode!(%{"pad" => String.duplicate("a", 9_000)})
      large_conn = media_worker_grant_request(oversized)
      assert large_conn.status == 413
      assert json_response(large_conn) == %{"status" => "request_too_large"}
    end
  end

  defp media_worker_grant_request(body, path \\ "/v1/media/workers/read-grants", content_type \\ "application/json") do
    :post
    |> conn(path, body)
    |> put_req_header("content-type", content_type)
    |> put_req_header(@authorization_header, "Bearer " <> @media_worker_token)
    |> put_req_header(@deployment_header, @deployment_ref)
    |> put_req_header(@media_worker_generation_header, "1")
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp entitlement_put_request(body, path \\ "/v1/storage/entitlement", content_type \\ "application/json") do
    :put
    |> conn(path, body)
    |> put_req_header("content-type", content_type)
    |> entitlement_headers()
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp entitlement_headers(conn) do
    conn
    |> put_req_header(@authorization_header, "Bearer " <> @entitlement_token)
    |> put_req_header(@deployment_header, @deployment_ref)
    |> put_req_header(@entitlement_generation_header, "1")
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

  def forward_telemetry_event(event, measurements, metadata, parent) do
    send(parent, {:telemetry_event, event, measurements, metadata})
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
