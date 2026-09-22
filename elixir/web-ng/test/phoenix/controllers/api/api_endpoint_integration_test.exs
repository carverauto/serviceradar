# credo:disable-for-this-file Credo.Check.Readability.MaxLineLength
defmodule ServiceRadarWebNGWeb.Api.ApiEndpointIntegrationTest do
  @moduledoc """
  End-to-end integration coverage for the JSON/SRQL API.

  Every request is dispatched through the *full* router pipeline
  (`ServiceRadarWebNGWeb.Endpoint`), so each test exercises auth
  (`:api_auth` + OAuth2 client-credentials), pagination, and serialization
  together — the same path that shipped four latent 500s once the OAuth
  API-access fix (#4441) made these endpoints reachable.

  Tokens are minted the real way: a seeded owner `User` owns an
  `OAuthClient`, and we POST `/oauth/token` (client_credentials) to get a
  `Bearer` token that the `:api_auth` pipeline resolves to the owner's scope.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Auth.Guardian

  @ip "127.0.0.1"

  # Stub SRQL handler that returns a *non-string* error reason (a tagged
  # tuple, like the `%Postgrex.Error{}` the DB-execution path can surface).
  # Guards the QueryController fix that coerces such reasons instead of
  # crashing `to_string/1` into a 500.
  defmodule NonStringErrorStub do
    @moduledoc false
    def query_request(_params), do: {:error, {:db_failure, "boom", %{code: 42}}}
  end

  defmodule CanonicalTimeStub do
    @moduledoc false

    def query_request(%{"query" => "in:logs limit:1"}) do
      {:ok,
       %{
         "results" => [%{"time" => "2026-08-30T18:00:00Z", "message" => "canonical"}],
         "pagination" => %{}
       }}
    end
  end

  setup do
    # Keep the per-IP OAuth rate-limit buckets clear so minting one token per
    # test never trips the client-credentials limiter across the suite.
    RateLimiter.clear(:oauth_client_credentials, @ip)
    RateLimiter.clear(:oauth_password_grant, @ip)

    on_exit(fn ->
      RateLimiter.clear(:oauth_client_credentials, @ip)
      RateLimiter.clear(:oauth_password_grant, @ip)
    end)

    owner = admin_user_fixture()

    {:ok, client, secret} =
      Credentials.create_client(owner.id,
        name: "API Integration Suite #{System.unique_integer([:positive])}",
        scopes: ["read"],
        actor: owner
      )

    %{owner: owner, client: client, secret: secret}
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp mint_token(client, secret) do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post(~p"/oauth/token", %{
        "grant_type" => "client_credentials",
        "client_id" => client.id,
        "client_secret" => secret
      })

    json_response(conn, 200)["access_token"]
  end

  defp api_conn(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
  end

  defp authed(%{client: client, secret: secret}), do: api_conn(mint_token(client, secret))

  defp client_for_user(owner, user, scopes) do
    {:ok, client, secret} =
      Credentials.create_client(user.id,
        name: "API Restricted #{System.unique_integer([:positive])}",
        scopes: scopes,
        actor: owner
      )

    {client, secret}
  end

  defp restricted_client(owner, permissions) do
    user = restrict_user(viewer_user_fixture(), permissions)
    client_for_user(owner, user, ["read"])
  end

  defp restrict_user(user, permissions) do
    actor = SystemActor.system(:srql_rbac_test)

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "srql-rbac-#{System.unique_integer([:positive])}",
          description: "catalog-gate fixture",
          permissions: permissions
        },
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    {:ok, assigned} = User.update_role_profile(user, %{role_profile_id: profile.id}, actor: actor)
    RBAC.invalidate_user_cache(assigned.id)
    RBAC.clear_process_cache()
    assigned
  end

  # Seed devices with strictly-decreasing last_seen_time so `sort:desc` +
  # offset paging is deterministic (no tie ambiguity across pages).
  defp seed_devices(n, overrides \\ %{}) do
    now = DateTime.utc_now()

    for i <- 1..n do
      last_seen = DateTime.add(now, -i, :second)

      attrs =
        Map.merge(
          %{
            uid: "api-suite-#{System.unique_integer([:positive])}",
            hostname: "host-#{i}-#{System.unique_integer([:positive])}.local",
            ip: "10.20.#{i}.#{:rand.uniform(250)}",
            type_id: rem(i, 3),
            is_available: true,
            first_seen_time: DateTime.add(now, -3600, :second),
            last_seen_time: last_seen
          },
          overrides
        )

      device_fixture(attrs)
    end
  end

  # ==========================================================================
  # POST /oauth/token
  # ==========================================================================

  describe "POST /oauth/token (client_credentials)" do
    test "success returns a Bearer access token", %{client: client, secret: secret} do
      conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => client.id,
          "client_secret" => secret
        })

      body = json_response(conn, 200)
      assert is_binary(body["access_token"])
      assert body["token_type"] == "Bearer"
      assert body["expires_in"] == 3600
      assert body["scope"] == "read"
    end

    test "supports HTTP Basic credentials", %{client: client, secret: secret} do
      basic = Base.encode64("#{client.id}:#{secret}")

      conn =
        build_conn()
        |> put_req_header("authorization", "Basic #{basic}")
        |> post(~p"/oauth/token", %{"grant_type" => "client_credentials"})

      body = json_response(conn, 200)
      assert is_binary(body["access_token"])
      assert body["token_type"] == "Bearer"
    end

    test "wrong secret returns 401 invalid_client", %{client: client} do
      conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => client.id,
          "client_secret" => "sr_totally-wrong-secret"
        })

      assert json_response(conn, 401)["error"] == "invalid_client"
    end

    test "malformed client_id returns 401 invalid_client" do
      conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => "not-a-uuid",
          "client_secret" => "sr_whatever"
        })

      assert json_response(conn, 401)["error"] == "invalid_client"
    end

    test "missing grant_type returns 400 invalid_request", %{client: client, secret: secret} do
      conn =
        post(build_conn(), ~p"/oauth/token", %{
          "client_id" => client.id,
          "client_secret" => secret
        })

      assert json_response(conn, 400)["error"] == "invalid_request"
    end

    test "unsupported grant_type returns 400" do
      conn = post(build_conn(), ~p"/oauth/token", %{"grant_type" => "implicit"})

      assert json_response(conn, 400)["error"] == "unsupported_grant_type"
    end
  end

  # ==========================================================================
  # GET /api/devices  (DeviceController.index — the endpoint the fix repairs)
  # ==========================================================================

  describe "GET /api/devices" do
    test "without a token returns 401", %{} do
      conn = get(build_conn(), ~p"/api/devices")
      assert json_response(conn, 401)["error"] == "authentication_required"
    end

    test "a refresh token (wrong typ) is rejected with 401", %{owner: owner} do
      {:ok, refresh, _claims} = Guardian.create_refresh_token(owner)

      conn = get(api_conn(refresh), ~p"/api/devices")
      assert json_response(conn, 401)["error"] == "authentication_required"
    end

    test "returns data + pagination and does NOT 500", ctx do
      seed_devices(5)
      conn = get(authed(ctx), ~p"/api/devices")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert length(body["data"]) == 5
      assert is_map(body["pagination"])
      assert body["pagination"]["limit"] == 100
      assert body["pagination"]["offset"] == 0
      # 5 < limit(100) => no further page
      assert body["pagination"]["next_offset"] == nil

      device = List.first(body["data"])
      assert is_binary(device["uid"])
      assert Map.has_key?(device, "hostname")
      assert Map.has_key?(device, "is_available")
    end

    test "limit/offset paginate deterministically", ctx do
      seed_devices(5)
      conn = authed(ctx)

      page1 = json_response(get(conn, ~p"/api/devices?#{[limit: 2, offset: 0]}"), 200)
      assert length(page1["data"]) == 2
      assert page1["pagination"] == %{"limit" => 2, "offset" => 0, "next_offset" => 2}

      page2 = json_response(get(conn, ~p"/api/devices?#{[limit: 2, offset: 2]}"), 200)
      assert length(page2["data"]) == 2
      assert page2["pagination"]["next_offset"] == 4

      page3 = json_response(get(conn, ~p"/api/devices?#{[limit: 2, offset: 4]}"), 200)
      assert length(page3["data"]) == 1
      # last (partial) page => no next
      assert page3["pagination"]["next_offset"] == nil

      uids1 = MapSet.new(page1["data"], & &1["uid"])
      uids2 = MapSet.new(page2["data"], & &1["uid"])
      assert MapSet.disjoint?(uids1, uids2)
    end

    test "status filter narrows to (un)available devices", ctx do
      seed_devices(2, %{is_available: true})
      seed_devices(3, %{is_available: false})

      body = json_response(get(authed(ctx), ~p"/api/devices?#{[status: "offline"]}"), 200)
      assert length(body["data"]) == 3
      assert Enum.all?(body["data"], &(&1["is_available"] == false))
    end

    test "device_type filter matches the OCSF type", ctx do
      seed_devices(2, %{type: "router"})
      seed_devices(1, %{type: "switch"})

      body = json_response(get(authed(ctx), ~p"/api/devices?#{[device_type: "router"]}"), 200)
      assert length(body["data"]) == 2
      assert Enum.all?(body["data"], &(&1["type"] == "router"))
    end

    test "gateway_id filter matches", ctx do
      seed_devices(1, %{gateway_id: "gw-alpha"})
      seed_devices(2, %{gateway_id: "gw-beta"})

      body = json_response(get(authed(ctx), ~p"/api/devices?#{[gateway_id: "gw-alpha"]}"), 200)
      assert length(body["data"]) == 1
      assert List.first(body["data"])["gateway_id"] == "gw-alpha"
    end

    test "search filter matches hostname", ctx do
      needle = "needle#{System.unique_integer([:positive])}"
      seed_devices(1, %{hostname: "#{needle}.example.internal"})
      seed_devices(2)

      body = json_response(get(authed(ctx), ~p"/api/devices?#{[search: needle]}"), 200)
      assert length(body["data"]) == 1
      assert String.contains?(List.first(body["data"])["hostname"], needle)
    end

    test "invalid limit returns 400", ctx do
      conn = get(authed(ctx), ~p"/api/devices?#{[limit: "abc"]}")
      assert json_response(conn, 400)["error"] == "invalid limit"
    end
  end

  # ==========================================================================
  # GET /api/devices/:uid  (show)
  # ==========================================================================

  describe "GET /api/devices/:uid" do
    test "existing uid returns 200 with the device", ctx do
      [device] = seed_devices(1)
      conn = get(authed(ctx), ~p"/api/devices/#{device.uid}")

      body = json_response(conn, 200)
      assert body["data"]["uid"] == device.uid
      assert body["data"]["hostname"] == device.hostname
    end

    test "unknown uid returns 404", ctx do
      uid = "does-not-exist-#{System.unique_integer([:positive])}"
      conn = get(authed(ctx), ~p"/api/devices/#{uid}")
      assert json_response(conn, 404)["error"] == "device not found"
    end

    test "malformed uid returns 400", ctx do
      # `!` is outside the allowed uid charset -> parse_uid rejects it.
      conn = get(authed(ctx), "/api/devices/invalid!uid")
      assert json_response(conn, 400)["error"] == "invalid uid"
    end

    test "without a token returns 401" do
      conn = get(build_conn(), ~p"/api/devices/#{"whatever"}")
      assert json_response(conn, 401)["error"] == "authentication_required"
    end
  end

  # ==========================================================================
  # GET /api/devices/ocsf/export
  # ==========================================================================

  describe "GET /api/devices/ocsf/export" do
    test "returns the OCSF export envelope and does NOT 500", ctx do
      seed_devices(3)
      conn = get(authed(ctx), ~p"/api/devices/ocsf/export")

      body = json_response(conn, 200)
      assert body["ocsf_version"] == "1.7.0"
      assert body["class_uid"] == 5001
      assert is_list(body["devices"])
      assert body["count"] == 3
      assert is_map(body["pagination"])
      assert body["pagination"]["limit"] == 100
      assert body["pagination"]["offset"] == 0
      assert Map.has_key?(body["pagination"], "next_offset")

      device = List.first(body["devices"])
      assert is_binary(device["uid"])
      assert Map.has_key?(device, "type_id")
    end

    test "honors limit/offset", ctx do
      seed_devices(4)

      body =
        json_response(
          get(authed(ctx), ~p"/api/devices/ocsf/export?#{[limit: 2, offset: 0]}"),
          200
        )

      assert body["count"] == 2
      assert body["pagination"]["next_offset"] == 2
    end

    test "without a token returns 401" do
      conn = get(build_conn(), ~p"/api/devices/ocsf/export")
      assert json_response(conn, 401)["error"] == "authentication_required"
    end
  end

  # ==========================================================================
  # POST /api/query  (SRQL engine)
  # ==========================================================================

  describe "POST /api/query" do
    @tag :web_ng_shared_fixture_db
    test "returns canonical UTC time payload values unchanged for a non-UTC user", ctx do
      owner =
        Ash.update!(ctx.owner, %{timezone: "America/Chicago"},
          action: :update_timezone_preference,
          actor: ctx.owner
        )

      previous = Application.get_env(:serviceradar_web_ng, :srql_module)
      Application.put_env(:serviceradar_web_ng, :srql_module, CanonicalTimeStub)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:serviceradar_web_ng, :srql_module),
          else: Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      end)

      {client, secret} = client_for_user(owner, owner, ["read"])

      conn =
        post(authed(%{client: client, secret: secret}), ~p"/api/query", %{
          "query" => "in:logs limit:1"
        })

      assert %{"results" => [%{"time" => "2026-08-30T18:00:00Z"}]} = json_response(conn, 200)
    end

    test "a valid SRQL query returns results", ctx do
      seed_devices(3)
      conn = post(authed(ctx), ~p"/api/query", %{"query" => "in:devices limit:10"})

      body = json_response(conn, 200)
      assert is_list(body["results"])
      assert length(body["results"]) >= 3
      assert Map.has_key?(body, "pagination")
    end

    test "a missing query returns a clean 400 (not a 500)", ctx do
      conn = post(authed(ctx), ~p"/api/query", %{"not_query" => "in:devices"})
      body = json_response(conn, 400)
      assert body["error"] =~ "query"
    end

    test "a malformed SRQL query returns a clean 4xx (not a 500)", ctx do
      conn = post(authed(ctx), ~p"/api/query", %{"query" => "in:not_a_real_entity_zzz"})
      # The SRQL NIF rejects the unknown entity; the controller must turn that
      # into a clean 4xx, never a 500.
      assert conn.status in 400..499
      assert conn.status != 401
      assert is_binary(json_response(conn, conn.status)["error"])
    end

    test "a non-string SRQL error reason is coerced to 400, never a 500", ctx do
      previous = Application.get_env(:serviceradar_web_ng, :srql_module)
      Application.put_env(:serviceradar_web_ng, :srql_module, NonStringErrorStub)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:serviceradar_web_ng, :srql_module)
        else
          Application.put_env(:serviceradar_web_ng, :srql_module, previous)
        end
      end)

      conn = post(authed(ctx), ~p"/api/query", %{"query" => "in:devices"})
      body = json_response(conn, 400)
      assert is_binary(body["error"])
    end

    test "without a token returns 401" do
      conn = post(build_conn(), ~p"/api/query", %{"query" => "in:devices"})
      assert json_response(conn, 401)["error"] == "authentication_required"
    end

    test "a custom profile without devices.view cannot query in:devices", %{owner: owner} do
      {client, secret} = restricted_client(owner, ["observability.logs.view"])

      conn =
        post(authed(%{client: client, secret: secret}), ~p"/api/query", %{
          "query" => "in:devices limit:1"
        })

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
    end

    test "a custom profile without observability.logs.view cannot query in:logs", %{owner: owner} do
      {client, secret} = restricted_client(owner, ["devices.view"])

      conn =
        post(authed(%{client: client, secret: secret}), ~p"/api/query", %{
          "query" => "in:logs limit:1"
        })

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
    end

    test "a built-in viewer can query in:devices", %{owner: owner} do
      seed_devices(1)
      viewer = viewer_user_fixture()
      {client, secret} = client_for_user(owner, viewer, ["read"])

      conn =
        post(authed(%{client: client, secret: secret}), ~p"/api/query", %{
          "query" => "in:devices limit:10"
        })

      body = json_response(conn, 200)
      assert is_list(body["results"])
    end

    test "in:dashboards is not catalog-forbidden for a custom profile", %{owner: owner} do
      {client, secret} = restricted_client(owner, ["observability.logs.view"])

      conn =
        post(authed(%{client: client, secret: secret}), ~p"/api/query", %{
          "query" => "in:dashboards"
        })

      refute conn.status == 403
      assert conn.status in 200..499
    end
  end

  # ==========================================================================
  # GET /api/srql/catalog
  # ==========================================================================

  describe "GET /api/srql/catalog" do
    test "returns the SRQL catalog payload", ctx do
      conn = get(authed(ctx), ~p"/api/srql/catalog")

      body = json_response(conn, 200)
      assert is_map(body["entities"])
      assert is_list(body["operators"])
      assert is_binary(body["version"])
      assert Enum.any?(get_resp_header(conn, "etag"))
    end

    test "without a token returns 401" do
      conn = get(build_conn(), ~p"/api/srql/catalog")
      assert json_response(conn, 401)["error"] == "authentication_required"
    end
  end

  # ==========================================================================
  # Session-creation endpoints (live agents/hardware required).
  # AUTH + input-VALIDATION only — behavior that needs live infra is omitted.
  # ==========================================================================

  describe "POST /api/camera-relay-sessions (auth + validation only)" do
    test "without a token returns 401" do
      conn = post(build_conn(), ~p"/api/camera-relay-sessions", %{})
      assert json_response(conn, 401)["error"] == "authentication_required"
    end

    test "invalid request body returns 400 before touching live infra", ctx do
      conn =
        post(authed(ctx), ~p"/api/camera-relay-sessions", %{"camera_source_id" => "not-a-uuid"})

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
    end
  end

  describe "POST /api/proxmox/console-sessions (auth + validation only)" do
    test "without a token returns 401" do
      conn = post(build_conn(), ~p"/api/proxmox/console-sessions", %{})
      assert json_response(conn, 401)["error"] == "authentication_required"
    end

    test "bad input returns a clean 4xx (400/403/422), never a 500", ctx do
      conn = post(authed(ctx), ~p"/api/proxmox/console-sessions", %{"device_uid" => ""})
      assert conn.status in [400, 403, 422]
    end
  end

  describe "GET /api/remote-access/host-keys (auth only)" do
    test "without a token returns 401" do
      conn = get(build_conn(), ~p"/api/remote-access/host-keys")
      assert json_response(conn, 401)["error"] == "authentication_required"
    end
  end
end
