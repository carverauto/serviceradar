defmodule ServiceRadarWebNG.RemoteDesktopWebRTCConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.RemoteDesktopWebRTCConfig

  @moduletag :db_free

  test "loads normalized STUN endpoints without a secret" do
    assert %{
             ice_servers: [
               %{urls: ["stun:stun.example.com:3478", "stuns:[2001:db8::1]:5349"]}
             ],
             turn_shared_secret: nil,
             credential_ttl_seconds: 600
           } =
             RemoteDesktopWebRTCConfig.load!(
               ice_servers_json:
                 Jason.encode!([
                   %{"urls" => ["STUN:stun.example.com:3478", "stuns:[2001:db8::1]:5349"]}
                 ])
             )
  end

  test "loads a mounted TURN REST secret and bounded TTL" do
    path = Path.join(System.tmp_dir!(), "serviceradar-turn-secret-#{System.unique_integer([:positive])}")
    File.write!(path, String.duplicate("a", 32) <> "\n")
    on_exit(fn -> File.rm(path) end)

    assert %{
             ice_servers: [
               %{urls: ["turn:turn.example.com:3478?transport=udp", "turns:turn.example.com:5349"]}
             ],
             turn_shared_secret: secret,
             credential_ttl_seconds: 300
           } =
             RemoteDesktopWebRTCConfig.load!(
               ice_servers_json:
                 Jason.encode!([
                   %{
                     "urls" => [
                       "turn:turn.example.com:3478?transport=udp",
                       "turns:turn.example.com:5349"
                     ]
                   }
                 ]),
               turn_shared_secret_file: path,
               credential_ttl_seconds: "300"
             )

    assert secret == String.duplicate("a", 32)
  end

  test "rejects static or inline TURN credentials" do
    for forbidden_key <- ~w(username credential turn_shared_secret shared_secret) do
      assert_raise ArgumentError, ~r/static credentials are forbidden/, fn ->
        RemoteDesktopWebRTCConfig.load!(
          ice_servers_json:
            Jason.encode!([
              %{"urls" => ["turn:turn.example.com:3478"], forbidden_key => "do-not-accept"}
            ])
        )
      end
    end
  end

  test "requires a mounted secret for TURN endpoints" do
    assert_raise ArgumentError, ~r/require a mounted TURN REST shared-secret file/, fn ->
      RemoteDesktopWebRTCConfig.load!(ice_servers_json: Jason.encode!([%{"urls" => "turn:turn.example.com:3478"}]))
    end
  end

  test "rejects an unused TURN secret mount" do
    assert_raise ArgumentError, ~r/configured without a TURN endpoint/, fn ->
      RemoteDesktopWebRTCConfig.load!(
        ice_servers_json: Jason.encode!([%{"urls" => "stun:stun.example.com:3478"}]),
        turn_shared_secret_file: "/not/read/when-turn-is-absent"
      )
    end
  end

  test "rejects invalid and credential-bearing ICE URLs" do
    invalid_urls = [
      "https://turn.example.com",
      "turn:user:password@turn.example.com:3478",
      "turn:turn.example.com:0",
      "turn:turn.example.com:65536",
      "turn:turn.example.com:3478?transport=sctp",
      "stun:stun.example.com:3478?transport=udp",
      "stun:bad_host.example.com:3478",
      "stun:127.0.0.1:3478 trailing"
    ]

    for url <- invalid_urls do
      assert_raise ArgumentError, ~r/remote desktop ICE URLs/, fn ->
        RemoteDesktopWebRTCConfig.load_ice_servers!(Jason.encode!([%{"urls" => url}]))
      end
    end
  end

  test "rejects malformed and oversized server collections" do
    assert_raise ArgumentError, ~r/must be a list/, fn ->
      RemoteDesktopWebRTCConfig.load_ice_servers!(Jason.encode!(%{"urls" => "stun:example.com"}))
    end

    assert_raise ArgumentError, ~r/exceeds 8 servers/, fn ->
      servers = Enum.map(1..9, &%{"urls" => "stun:stun#{&1}.example.com"})
      RemoteDesktopWebRTCConfig.load_ice_servers!(Jason.encode!(servers))
    end
  end

  test "rejects missing, weak, and invalid TURN secret material" do
    missing = Path.join(System.tmp_dir!(), "missing-turn-secret-#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/file is unreadable/, fn ->
      RemoteDesktopWebRTCConfig.load!(
        ice_servers_json: Jason.encode!([%{"urls" => "turn:turn.example.com"}]),
        turn_shared_secret_file: missing
      )
    end

    for secret <- ["too-short", String.duplicate("a", 31), String.duplicate("a", 32) <> " space"] do
      path = Path.join(System.tmp_dir!(), "invalid-turn-secret-#{System.unique_integer([:positive])}")
      File.write!(path, secret)

      assert_raise ArgumentError, ~r/must be 32-512 printable/, fn ->
        RemoteDesktopWebRTCConfig.load!(
          ice_servers_json: Jason.encode!([%{"urls" => "turn:turn.example.com"}]),
          turn_shared_secret_file: path
        )
      end

      File.rm!(path)
    end
  end

  test "accepts mounted secret symlinks and rejects relative or oversized TURN secret files" do
    root = Path.join(System.tmp_dir!(), "serviceradar-turn-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    target = Path.join(root, "target")
    symlink = Path.join(root, "shared-secret")
    File.write!(target, String.duplicate("a", 32))
    File.ln_s!(target, symlink)

    assert %{turn_shared_secret: secret} =
             RemoteDesktopWebRTCConfig.load!(
               ice_servers_json: Jason.encode!([%{"urls" => "turn:turn.example.com"}]),
               turn_shared_secret_file: symlink
             )

    assert secret == String.duplicate("a", 32)

    assert_raise ArgumentError, ~r/file is unreadable/, fn ->
      RemoteDesktopWebRTCConfig.load!(
        ice_servers_json: Jason.encode!([%{"urls" => "turn:turn.example.com"}]),
        turn_shared_secret_file: "relative/shared-secret"
      )
    end

    oversized = Path.join(root, "oversized")
    File.write!(oversized, String.duplicate("a", 515))

    assert_raise ArgumentError, ~r/file is unreadable/, fn ->
      RemoteDesktopWebRTCConfig.load!(
        ice_servers_json: Jason.encode!([%{"urls" => "turn:turn.example.com"}]),
        turn_shared_secret_file: oversized
      )
    end
  end

  test "rejects TURN credential TTLs above one hour" do
    for invalid <- [0, -1, 3_601, "3601", "not-a-number"] do
      assert_raise ArgumentError, ~r/TTL must be between 1 and 3600 seconds/, fn ->
        RemoteDesktopWebRTCConfig.credential_ttl_seconds!(invalid)
      end
    end
  end
end
