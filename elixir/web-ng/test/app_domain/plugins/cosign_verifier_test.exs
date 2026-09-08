defmodule ServiceRadarWebNG.Plugins.CosignVerifierTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.CosignVerifier

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

  test "accepts current cosign transparency log verification output" do
    output = """
    Verification for registry.example.test/plugins/example@sha256:abc --
    The following checks were performed on each of these signatures:
      - The cosign claims were validated
      - Existence of the claims in the transparency log was verified offline
      - The signatures were verified against the specified public key

    [{"optional":{"Bundle":{"Payload":{"logIndex":1410668944}}}}]
    """

    configure_cosign(output, 0)

    assert :ok = CosignVerifier.verify(%{ref: "registry.example.test/plugins/example:v1", digest: "sha256:abc"})
  end

  test "rejects successful cosign output without Rekor verification evidence" do
    configure_cosign("The signatures were verified against the specified public key", 0)

    assert {:error, :cosign_rekor_verification_missing} =
             CosignVerifier.verify(%{ref: "registry.example.test/plugins/example:v1", digest: "sha256:abc"})
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
    cat <<'EOF'
    transparency log was verified
    EOF
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

    assert :ok = CosignVerifier.verify(%{ref: "registry.example.test/plugins/example:v1", digest: "sha256:abc"})

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

  defp configure_cosign(output, status) do
    path = Path.join(System.tmp_dir!(), "serviceradar-cosign-test-#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/usr/bin/env sh
    cat <<'EOF'
    #{output}
    EOF
    exit #{status}
    """)

    File.chmod!(path, 0o700)

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import,
      cosign_binary: path,
      cosign_public_key: "test-public-key"
    )

    on_exit(fn -> File.rm(path) end)
  end
end
