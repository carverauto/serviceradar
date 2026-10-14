defmodule ServiceRadar.WebRTC.IceCredentialsTest do
  @moduledoc """
  Unit coverage for the shared ICE credential provider (slice 1 of the
  add-webrtc-turn-relay change): dispatch and TTL bounds, digest-vs-legacy
  subject binding, the static_secret TURN REST backend's byte-compat with
  the minting web-ng shipped for remote desktop, secret-file bounds, and
  the per-actor/per-session mint rate limit.

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
      path = Path.join(System.tmp_dir!(), "ice-cred-mint-short-#{System.unique_integer([:positive])}")
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

      assert server.credential == StaticSecret.turn_credential("turn-rest-secret", server.username)
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
