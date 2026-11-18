defmodule ServiceRadarWebNG.Plugins.CosignVerifierTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.CosignVerifier

  @moduletag :db_free

  setup do
    original = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :first_party_plugin_import)
      else
        Application.put_env(:serviceradar_web_ng, :first_party_plugin_import, original)
      end
    end)

    :ok
  end

  @artifact %{ref: "registry.example.test/plugins/example:v1", digest: "sha256:abc"}

  # The stand-in below behaves like Cosign 3 on a host that cannot reach the
  # public transparency log: without `--insecure-ignore-tlog=true` the real
  # binary waits on the log lookup, which the stand-in reports as exit 1.
  test "verifies against the release key without consulting the transparency log" do
    configure_cosign_script("""
    for arg in "$@"; do
      if [ "$arg" = "--insecure-ignore-tlog=true" ]; then
        echo "The signatures were verified against the specified public key"
        exit 0
      fi
    done
    echo "transparency log lookup did not complete" >&2
    exit 1
    """)

    assert :ok = CosignVerifier.verify(@artifact)
  end

  test "verifies the digest it was given, not the mutable tag" do
    configure_cosign_script("""
    for arg in "$@"; do last="$arg"; done
    test "$last" = "registry.example.test/plugins/example@sha256:abc" || exit 1
    exit 0
    """)

    assert :ok = CosignVerifier.verify(@artifact)
  end

  test "rejects an artifact cosign does not verify" do
    configure_cosign_script("""
    echo "no matching signatures"
    exit 1
    """)

    assert {:error, {:cosign_verify_failed, 1, output}} = CosignVerifier.verify(@artifact)
    assert output =~ "no matching signatures"
  end

  test "fails closed when no release key is configured" do
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import, cosign_binary: "cosign")

    assert {:error, :cosign_public_key_not_configured} = CosignVerifier.verify(@artifact)
  end

  test "runs cosign with writable runtime cache paths" do
    record_path = Path.join(System.tmp_dir!(), "serviceradar-cosign-env-#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "serviceradar-cosign-test-#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/usr/bin/env sh
    test "$HOME" != "/app" || exit 8
    test -d "$HOME" || exit 9
    test -w "$HOME" || exit 10
    test -d "$XDG_CACHE_HOME" || exit 11
    test -w "$XDG_CACHE_HOME" || exit 12
    test -d "$XDG_CONFIG_HOME" || exit 13
    test -w "$XDG_CONFIG_HOME" || exit 14
    test -d "$SIGSTORE_CACHE_DIR" || exit 15
    test -w "$SIGSTORE_CACHE_DIR" || exit 16
    printf '%s|%s|%s|%s\\n' "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$SIGSTORE_CACHE_DIR" > #{record_path}
    """)

    File.chmod!(path, 0o700)

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import,
      cosign_binary: path,
      cosign_public_key: "test-public-key"
    )

    on_exit(fn ->
      File.rm(path)
      File.rm(record_path)
    end)

    assert :ok = CosignVerifier.verify(@artifact)

    assert [home, cache, config, sigstore] =
             record_path
             |> File.read!()
             |> String.trim()
             |> String.split("|")

    for path <- [home, cache, config, sigstore] do
      assert String.contains?(path, "serviceradar-cosign-runtime-")
      refute path == "/app"
    end
  end

  defp configure_cosign_script(body) do
    path = Path.join(System.tmp_dir!(), "serviceradar-cosign-test-#{System.unique_integer([:positive])}.sh")

    File.write!(path, "#!/usr/bin/env sh\n" <> body)
    File.chmod!(path, 0o700)

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import,
      cosign_binary: path,
      cosign_public_key: "test-public-key"
    )

    on_exit(fn -> File.rm(path) end)
  end
end
