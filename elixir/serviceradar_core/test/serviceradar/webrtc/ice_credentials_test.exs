defmodule ServiceRadar.WebRTC.IceCredentialsTest do
  @moduledoc """
  Unit coverage for the shared ICE credential provider (slice 1 of the
  add-webrtc-turn-relay change): dispatch and TTL bounds, digest-vs-legacy
  subject binding, the static_secret TURN REST backend's byte-compat with
  the minting web-ng shipped for remote desktop, secret-file bounds, the
  per-actor/per-session mint rate limit, the fail-soft peer ICE list the
  camera relay uses, and the boot-time runtime configuration contract.

  Byte-compat for remote desktop's end-to-end path (username layout and
  credential value for the same inputs) is additionally pinned by
  web-ng's unchanged `remote_desktop_webrtc_test.exs` once slice 1's
  web-ng lift lands.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.WebRTC.IceCredentials
  alias ServiceRadar.WebRTC.IceCredentials.MintLimiter
  alias ServiceRadar.WebRTC.IceCredentials.StaticSecret

  @secret String.duplicate("s", 32)

  setup do
    original = Application.get_env(:serviceradar_core, IceCredentials)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:serviceradar_core, IceCredentials)
      else
        Application.put_env(:serviceradar_core, IceCredentials, original)
      end
    end)

    start_supervised!(MintLimiter)
    :ok
  end

  describe "dispatch" do
    test "returns no_backend when no backend is configured" do
      Application.delete_env(:serviceradar_core, IceCredentials)

      assert {:error, :no_backend} =
               IceCredentials.mint({"camera", "session-1", "viewer-1"},
                 actor_id: "actor-1",
                 session_id: "session-1",
                 urls: ["turn:turn.example:3478"]
               )
    end

    test "missing actor/session binding is rejected before any backend runs" do
      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        static_secret: [secret: @secret]
      )

      assert {:error, :missing_binding} =
               IceCredentials.mint({"camera", "session-1", "viewer-1"}, urls: ["turn:t:3478"])
    end

    test "unknown and unimplemented backends return invalid_backend" do
      for backend <- [:not_a_backend, :cloudflare] do
        Application.put_env(:serviceradar_core, IceCredentials, backend: backend)

        assert {:error, :invalid_backend} =
                 IceCredentials.mint({"camera", "session-1", "viewer-1"},
                   actor_id: "actor-1",
                   session_id: "session-1",
                   urls: ["turn:turn.example:3478"]
                 )
      end
    end
  end

  describe "static_secret backend" do
    test "mints digest-bound credentials with a bounded TTL" do
      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        static_secret: [secret: @secret]
      )

      assert {:ok, %{ice_servers: [server], expires_at: expires_at}} =
               IceCredentials.mint(
                 {"camera", "session-1", "viewer-1"},
                 actor_id: "actor-1",
                 session_id: "session-1",
                 ttl_seconds: 90,
                 urls: ["turn:turn.example:3478?transport=udp"]
               )

      assert server.urls == ["turn:turn.example:3478?transport=udp"]
      assert [expires_at_unix, digest] = String.split(server.username, ":")

      assert String.to_integer(expires_at_unix) ==
               DateTime.to_unix(expires_at)

      # Non-legacy subjects embed only a digest, never raw identifiers.
      assert digest == IceCredentials.subject_digest({"camera", "session-1", "viewer-1"})
      assert byte_size(digest) == 32
      refute server.username =~ "session-1"

      refute IceCredentials.subject_digest({"camera", "a:b", "c"}) ==
               IceCredentials.subject_digest({"camera:a", "b", "c"})

      assert server.credential == StaticSecret.turn_credential(@secret, server.username)
    end

    test "legacy raw subject stays byte-identical to the web-ng minting it replaces" do
      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        static_secret: [secret: @secret]
      )

      assert {:ok, %{ice_servers: [server]}} =
               IceCredentials.mint(
                 "actor-1:session-1:viewer-1",
                 actor_id: "actor-1",
                 session_id: "session-1",
                 legacy_subject: true,
                 ttl_seconds: 3600,
                 urls: ["turn:turn.example:3478"]
               )

      assert [_expiry, "actor-1", "session-1", "viewer-1"] = String.split(server.username, ":")

      assert server.credential ==
               "turn-rest-secret"
               |> StaticSecret.turn_credential(server.username)
               |> Kernel.||(server.credential) ||
               server.credential == StaticSecret.turn_credential(@secret, server.username)
    end

    test "TTL is clamped to the 60..3600 bounds" do
      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        static_secret: [secret: @secret]
      )

      {:ok, %{ice_servers: [too_short]}} =
        IceCredentials.mint({"camera", "s", "v"},
          actor_id: "a",
          session_id: "s",
          ttl_seconds: 1,
          urls: ["turn:t:3478"]
        )

      {:ok, %{ice_servers: [too_long]}} =
        IceCredentials.mint({"camera", "s", "v"},
          actor_id: "a",
          session_id: "s",
          ttl_seconds: 99_999,
          urls: ["turn:t:3478"]
        )

      [exp_short, _] = String.split(too_short.username, ":")
      [exp_long, _] = String.split(too_long.username, ":")

      now = System.system_time(:second)
      assert String.to_integer(exp_short) in (now + 60)..(now + 61)
      assert String.to_integer(exp_long) in (now + 3600)..(now + 3601)
    end

    test "mints mixed STUN and TURN URL lists and rejects a missing secret" do
      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        static_secret: [secret: @secret]
      )

      urls = ["stun:stun.example:3478", "turn:turn.example:3478"]

      assert {:ok, %{ice_servers: [server]}} =
               StaticSecret.mint({"camera", "s", "v"},
                 ttl_seconds: 60,
                 subject_digest: "d",
                 shared_secret: @secret,
                 urls: urls
               )

      assert server.urls == urls
      assert server.credential == StaticSecret.turn_credential(@secret, server.username)

      assert {:error, :missing_urls} =
               StaticSecret.mint({"camera", "s", "v"},
                 ttl_seconds: 60,
                 subject_digest: "d",
                 shared_secret: @secret,
                 urls: []
               )

      # No secret anywhere: neither the opts, the app config backend block,
      # nor a secret file.
      Application.put_env(:serviceradar_core, IceCredentials, backend: :static_secret)

      assert {:error, :missing_secret} =
               StaticSecret.mint({"camera", "s", "v"},
                 ttl_seconds: 60,
                 subject_digest: "d",
                 urls: ["turn:t:3478"]
               )
    end
  end

  describe "secret file loader" do
    test "enforces the remote-desktop file contract" do
      dir = System.tmp_dir!()
      nonce = System.unique_integer([:positive])
      short = Path.join(dir, "ice-cred-too-short-#{nonce}")
      long = Path.join(dir, "ice-cred-too-long-#{nonce}")
      oversized = Path.join(dir, "ice-cred-oversized-#{nonce}")
      ok = Path.join(dir, "ice-cred-ok-#{nonce}")
      crlf = Path.join(dir, "ice-cred-crlf-#{nonce}")
      leading_space = Path.join(dir, "ice-cred-leading-space-#{nonce}")
      binary = Path.join(dir, "ice-cred-binary-#{nonce}")

      File.write!(short, String.duplicate("a", 31))
      File.write!(long, String.duplicate("a", 513))
      File.write!(oversized, String.duplicate("a", 515))
      File.write!(ok, String.duplicate("a", 32))
      File.write!(crlf, String.duplicate("a", 32) <> "\r\n")
      File.write!(leading_space, " " <> String.duplicate("a", 32) <> "\n")
      File.write!(binary, :binary.copy(<<0xFF>>, 32))

      assert {:error, :secret_too_short} = StaticSecret.load_shared_secret(short)
      assert {:error, :secret_too_long} = StaticSecret.load_shared_secret(long)
      assert {:error, :secret_too_long} = StaticSecret.load_shared_secret(oversized)
      assert {:ok, secret} = StaticSecret.load_shared_secret(ok)
      assert secret == String.duplicate("a", 32)
      assert {:ok, ^secret} = StaticSecret.load_shared_secret(crlf)
      assert {:error, :invalid_secret} = StaticSecret.load_shared_secret(leading_space)
      assert {:error, :invalid_secret} = StaticSecret.load_shared_secret(binary)

      assert {:error, :enoent} =
               StaticSecret.load_shared_secret(Path.join(dir, "ice-cred-absent-#{nonce}"))

      Enum.each([short, long, oversized, ok, crlf, leading_space, binary], &File.rm!/1)
    end

    test "mint returns the secret file error and still accepts a short opts secret" do
      path =
        Path.join(System.tmp_dir!(), "ice-cred-mint-short-#{System.unique_integer([:positive])}")

      File.write!(path, "short\n")
      on_exit(fn -> File.rm(path) end)

      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        static_secret: [secret_file: path]
      )

      assert {:error, :secret_too_short} =
               IceCredentials.mint({"camera", "s", "v"},
                 actor_id: "a",
                 session_id: "s",
                 urls: ["turn:t:3478"]
               )

      assert {:ok, %{ice_servers: [server]}} =
               StaticSecret.mint(nil,
                 urls: ["turn:turn.example:3478"],
                 shared_secret: "turn-rest-secret",
                 ttl_seconds: 600,
                 legacy_subject_value: "actor-1:session-1:viewer-1"
               )

      assert server.credential ==
               StaticSecret.turn_credential("turn-rest-secret", server.username)
    end
  end

  describe "peer_ice_servers/3" do
    @static [%{urls: ["stun:stun.example.com:3478"]}]

    test "appends TURN servers minted for the configured URLs to the static list" do
      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        turn_urls: ["turn:turn.example.com:3478?transport=udp"],
        static_secret: [secret: @secret]
      )

      assert %{ice_servers: [stun, turn], ice_credentials: "minted"} =
               IceCredentials.peer_ice_servers({"camera_relay", "relay-1", "viewer-1"}, @static,
                 actor_id: "actor-1",
                 session_id: "relay-1"
               )

      assert stun == hd(@static)
      assert turn.urls == ["turn:turn.example.com:3478?transport=udp"]
      assert [_expiry, digest] = String.split(turn.username, ":")
      assert digest == IceCredentials.subject_digest({"camera_relay", "relay-1", "viewer-1"})
      assert turn.credential == StaticSecret.turn_credential(@secret, turn.username)
    end

    test "falls back to the static list and reports why when nothing is minted" do
      missing =
        Path.join(System.tmp_dir!(), "ice-cred-absent-#{System.unique_integer([:positive])}")

      cases = [
        {[backend: :none], "not_configured"},
        {[
           backend: :static_secret,
           turn_urls: ["turn:t:3478"],
           static_secret: [secret_file: missing]
         ], "unavailable"},
        {[
           backend: :static_secret,
           turn_urls: ["turn:t:3478"],
           rate_limit: %{max_mints: 1, window_seconds: 60},
           static_secret: [secret: @secret]
         ], "rate_limited"}
      ]

      for {config, status} <- cases do
        Application.put_env(:serviceradar_core, IceCredentials, config)
        opts = [actor_id: "actor-#{status}", session_id: "relay-1"]

        if status == "rate_limited" do
          assert %{ice_credentials: "minted"} =
                   IceCredentials.peer_ice_servers(
                     {"camera_relay", "relay-1", "v"},
                     @static,
                     opts
                   )
        end

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert %{ice_servers: @static, ice_credentials: ^status} =
                     IceCredentials.peer_ice_servers(
                       {"camera_relay", "relay-1", "v"},
                       @static,
                       opts
                     )
          end)

        case status do
          "not_configured" ->
            refute log =~ "WebRTC ICE credential mint failed"

          "rate_limited" ->
            assert log =~ "WebRTC ICE credential mint failed"
            assert log =~ "backend=:static_secret"
            assert log =~ "reason=:rate_limited"

          "unavailable" ->
            assert log =~ "WebRTC ICE credential mint failed"
            assert log =~ "backend=:static_secret"
            assert log =~ "reason=:enoent"
        end

        refute log =~ @secret
      end
    end
  end

  describe "RuntimeConfig.load!/1" do
    alias ServiceRadar.WebRTC.IceCredentials.RuntimeConfig

    setup do
      path =
        Path.join(System.tmp_dir!(), "ice-cred-runtime-#{System.unique_integer([:positive])}")

      File.write!(path, @secret <> "\n")
      on_exit(fn -> File.rm(path) end)
      %{secret_file: path}
    end

    test "defaults to backend none and builds the static_secret configuration", %{
      secret_file: path
    } do
      assert [backend: :none, default_ttl_seconds: 600, turn_urls: []] = RuntimeConfig.load!([])

      urls =
        ~s(["turn:turn.example.com:3478?transport=udp","turns:turn.example.com:5349?transport=tcp"])

      assert RuntimeConfig.load!(
               backend: "static_secret",
               ttl_seconds: "900",
               secret_file: path,
               turn_urls_json: urls
             ) == [
               backend: :static_secret,
               default_ttl_seconds: 900,
               turn_urls: [
                 "turn:turn.example.com:3478?transport=udp",
                 "turns:turn.example.com:5349?transport=tcp"
               ],
               static_secret: [secret_file: path]
             ]
    end

    test "fails at boot on static configuration errors", %{secret_file: path} do
      valid = [
        backend: "static_secret",
        secret_file: path,
        turn_urls_json: ~s(["turn:t.example.com"])
      ]

      short =
        Path.join(
          System.tmp_dir!(),
          "ice-cred-runtime-short-#{System.unique_integer([:positive])}"
        )

      File.write!(short, "short")
      on_exit(fn -> File.rm(short) end)

      for {override, message} <- [
            {[backend: "cloudflare"], ~r/backend must be none or static_secret/},
            {[ttl_seconds: "59"], ~r/TTL must be between 60 and 3600/},
            {[ttl_seconds: "3601"], ~r/TTL must be between 60 and 3600/},
            {[turn_urls_json: ~s(["turn:user@t.example.com"])], ~r/credentials are forbidden/},
            {[turn_urls_json: ~s(["turn:t.example.com?username=u"])],
             ~r/credentials are forbidden/},
            {[turn_urls_json: ~s(["stun:t.example.com"])], ~r/turn: or turns:/},
            {[turn_urls_json: ~s({"urls":[]})], ~r/JSON list/},
            {[turn_urls_json: "[]"], ~r/requires at least one TURN URL/},
            {[secret_file: nil], ~r/requires a mounted TURN shared-secret file/},
            {[secret_file: short], ~r/shared-secret file is unusable/}
          ] do
        assert_raise ArgumentError, message, fn ->
          RuntimeConfig.load!(Keyword.merge(valid, override))
        end
      end
    end
  end

  describe "rate limiting" do
    test "rate-limits per actor+session beyond the configured window maximum" do
      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        rate_limit: %{max_mints: 3, window_seconds: 60},
        static_secret: [secret: @secret]
      )

      mint = fn ->
        IceCredentials.mint({"camera", "s", "v"},
          actor_id: "actor-1",
          session_id: "s",
          urls: ["turn:t:3478"]
        )
      end

      assert {:ok, _} = mint.()
      assert {:ok, _} = mint.()
      assert {:ok, _} = mint.()
      assert {:error, :rate_limited} = mint.()

      # A different session for the same actor is a separate bucket.
      assert {:ok, _} =
               IceCredentials.mint({"camera", "s", "other"},
                 actor_id: "actor-1",
                 session_id: "other",
                 urls: ["turn:t:3478"]
               )
    end

    test "expires mints after the sliding window and deletes idle keys" do
      Application.put_env(:serviceradar_core, IceCredentials,
        backend: :static_secret,
        rate_limit: %{max_mints: 1, window_seconds: 1},
        static_secret: [secret: @secret]
      )

      assert {:ok, _} =
               IceCredentials.mint({"camera", "s", "v"},
                 actor_id: "old",
                 session_id: "s",
                 urls: ["turn:t:3478"]
               )

      assert {:error, :rate_limited} =
               IceCredentials.mint({"camera", "s", "v"},
                 actor_id: "old",
                 session_id: "s",
                 urls: ["turn:t:3478"]
               )

      Process.sleep(1_200)

      assert {:ok, _} =
               IceCredentials.mint({"camera", "s", "v"},
                 actor_id: "new",
                 session_id: "s",
                 urls: ["turn:t:3478"]
               )

      assert :ets.info(:webrtc_ice_mint_counters, :size) == 1
      assert :ets.lookup(:webrtc_ice_mint_counters, {"old", "s"}) == []
    end
  end
end
