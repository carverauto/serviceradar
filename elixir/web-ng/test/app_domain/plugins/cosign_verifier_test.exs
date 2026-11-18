defmodule ServiceRadarWebNG.Plugins.CosignVerifierTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.CosignVerifier

  @moduletag :db_free

  @digest "sha256:" <> String.duplicate("a", 64)
  @allowlisted_digest "sha256:" <> String.duplicate("b", 64)
  @log_id String.duplicate("c", 64)
  @artifact_ref "registry.example.test/plugins/example:v1"

  setup do
    originals =
      for key <- [:first_party_plugin_import, :first_party_transparency_log],
          do: {key, Application.get_env(:serviceradar_web_ng, key)}

    on_exit(fn ->
      for {key, value} <- originals do
        if is_nil(value),
          do: Application.delete_env(:serviceradar_web_ng, key),
          else: Application.put_env(:serviceradar_web_ng, key, value)
      end
    end)

    trust_dir = temp_dir("serviceradar-cosign-trust")
    File.mkdir_p!(Path.join(trust_dir, "rekor-keys"))
    File.write!(Path.join([trust_dir, "rekor-keys", @log_id <> ".pub"]), "synthetic pinned log key\n")
    allowlist = Path.join(trust_dir, "allowlist.json")
    File.write!(allowlist, Jason.encode!(%{"digests" => [@allowlisted_digest]}))

    Application.put_env(:serviceradar_web_ng, :first_party_transparency_log,
      rekor_keys_dir: Path.join(trust_dir, "rekor-keys"),
      pre_cutover_digests_file: allowlist
    )

    %{trust_dir: trust_dir}
  end

  describe "with a stand-in cosign" do
    test "a receipt is verified offline under the shipped key for its log ID", %{trust_dir: trust_dir} do
      record = configure_cosign_script(verified_output(@log_id, 42, 1_767_225_600))

      assert {:ok, receipt} = verify(@digest, signature_manifest(receipt_annotation(@log_id)))

      assert receipt == %{
               "status" => "verified",
               "log_id" => @log_id,
               "log_index" => 42,
               "integrated_time" => 1_767_225_600
             }

      %{args: args, env: env} = read_record(record)
      assert env["SIGSTORE_REKOR_PUBLIC_KEY"] == Path.join([trust_dir, "rekor-keys", @log_id <> ".pub"])
      assert "--offline=true" in args and "--new-bundle-format=false" in args
      refute Enum.any?(args, &String.starts_with?(&1, "--insecure-ignore-tlog"))
      refute "--trusted-root" in args
      assert List.last(args) == "registry.example.test/plugins/example@" <> @digest
    end

    test "an allowlisted digest whose signature carries a receipt is still held to it" do
      record = configure_cosign_script(verified_output(@log_id, 7, 1))

      assert {:ok, %{"status" => "verified", "log_index" => 7}} =
               verify(@allowlisted_digest, signature_manifest(receipt_annotation(@log_id)))

      assert "--offline=true" in read_record(record).args
    end

    test "an allowlisted digest without a receipt verifies with the release key alone" do
      record = configure_cosign_script("exit 0")

      assert {:ok, %{"status" => "absent_allowlisted"}} = verify(@allowlisted_digest, signature_manifest(nil))

      %{args: args, env: env} = read_record(record)
      assert "--insecure-ignore-tlog=true" in args
      refute "--offline=true" in args
      refute Map.has_key?(env, "SIGSTORE_REKOR_PUBLIC_KEY")
    end

    test "a missing receipt on a digest that is not allowlisted fails before cosign runs" do
      record = configure_cosign_script("exit 0")

      assert {:error, :transparency_receipt_missing} = verify(@digest, signature_manifest(nil))
      refute File.exists?(record.args)
    end

    test "a receipt from a log with no shipped key fails before cosign runs" do
      record = configure_cosign_script("exit 0")
      unknown = String.duplicate("d", 64)

      assert {:error, {:unknown_transparency_log, ^unknown}} =
               verify(@allowlisted_digest, signature_manifest(receipt_annotation(unknown)))

      refute File.exists?(record.args)
    end

    test "a malformed receipt fails closed, even on an allowlisted digest" do
      record = configure_cosign_script("exit 0")

      assert {:error, :malformed_transparency_receipt} =
               verify(@allowlisted_digest, signature_manifest(~s({"Payload":{"logID":"../../etc/passwd"}})))

      refute File.exists?(record.args)
    end

    test "rejects an artifact cosign does not verify" do
      configure_cosign_script(~s(echo "no matching signatures"; exit 1))

      assert {:error, {:cosign_verify_failed, 1, output}} =
               verify(@digest, signature_manifest(receipt_annotation(@log_id)))

      assert output =~ "no matching signatures"
    end

    test "fails closed when no release key is configured" do
      Application.put_env(:serviceradar_web_ng, :first_party_plugin_import, cosign_binary: "cosign")

      assert {:error, :cosign_public_key_not_configured} =
               verify(@digest, signature_manifest(receipt_annotation(@log_id)))
    end

    test "runs cosign with isolated runtime paths and no inherited Sigstore trust override" do
      System.put_env("SIGSTORE_ROOT_FILE", "/operator/fulcio.pem")
      on_exit(fn -> System.delete_env("SIGSTORE_ROOT_FILE") end)

      record = configure_cosign_script("exit 0")
      assert {:ok, _receipt} = verify(@allowlisted_digest, signature_manifest(nil))

      %{env: env} = read_record(record)

      for name <- ["HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "SIGSTORE_CACHE_DIR"] do
        assert String.contains?(env[name], "serviceradar-cosign-runtime-"), name
      end

      refute Map.has_key?(env, "SIGSTORE_ROOT_FILE")
    end
  end

  # The pinned cosign against synthetic keys, a stand-in transparency log and a
  # loopback registry. Every other destination, any Rekor included, goes through a
  # recording proxy that answers nothing, so a request leaves evidence and fails.
  describe "with the pinned cosign binary" do
    setup %{trust_dir: trust_dir} do
      cosign = pinned_cosign()
      fixture = __MODULE__.Fixture.start(trust_dir)

      Application.put_env(:serviceradar_web_ng, :first_party_plugin_import,
        cosign_binary: cosign,
        cosign_public_key: fixture.release_public_pem
      )

      proxy = __MODULE__.Fixture.start_recording_proxy()

      for {name, value} <- [
            {"HTTPS_PROXY", proxy.url},
            {"HTTP_PROXY", proxy.url},
            {"NO_PROXY", "localhost,127.0.0.1"}
          ] do
        System.put_env(name, value)
        on_exit(fn -> System.delete_env(name) end)
      end

      %{fixture: fixture, proxy: proxy, cosign: cosign}
    end

    test "verifies a receipt offline, records the logged entry, and contacts no Rekor", %{
      fixture: fixture,
      proxy: proxy
    } do
      {ref, digest, signature_manifest} = __MODULE__.Fixture.publish(fixture, :own_entry)

      assert {:ok, receipt} = CosignVerifier.verify(%{ref: ref, digest: digest, signature_manifest: signature_manifest})

      assert receipt == %{
               "status" => "verified",
               "log_id" => fixture.log_id,
               "log_index" => 4242,
               "integrated_time" => 1_767_225_600
             }

      assert __MODULE__.Fixture.proxied_requests(proxy) == []
    end

    # Control for the assertion above: the proxy does see a transparency-log lookup
    # when cosign is asked for one (no receipt, no --offline, no --insecure-ignore-tlog).
    test "the recording proxy sees the Rekor lookup cosign makes without a receipt", %{
      fixture: fixture,
      proxy: proxy,
      cosign: cosign
    } do
      {ref, digest, _signature_manifest} = __MODULE__.Fixture.publish(fixture, :no_receipt)
      key = Path.join(temp_dir("serviceradar-cosign-control"), "release.pub")
      File.write!(key, fixture.release_public_pem)
      home = temp_dir("serviceradar-cosign-control-home")
      target = String.replace(ref, ":v1", "@" <> digest)

      {_output, status} =
        System.cmd(cosign, ["verify", "--timeout", "20s", "--new-bundle-format=false", "--key", key, target],
          stderr_to_stdout: true,
          env: [{"HOME", home}, {"SIGSTORE_CACHE_DIR", Path.join(home, "sigstore")}]
        )

      assert status != 0
      requests = __MODULE__.Fixture.proxied_requests(proxy)
      assert Enum.any?(requests, &String.contains?(&1, "sigstore.dev")), inspect(requests)
    end

    test "rejects a valid receipt for another artifact's log entry", %{fixture: fixture} do
      {ref, digest, signature_manifest} = __MODULE__.Fixture.publish(fixture, :other_entry)

      assert {:error, {:cosign_verify_failed, _status, output}} =
               CosignVerifier.verify(%{ref: ref, digest: digest, signature_manifest: signature_manifest})

      assert output =~ "signature in bundle does not match signature being verified"
    end
  end

  defp verify(digest, signature_manifest) do
    CosignVerifier.verify(%{ref: @artifact_ref, digest: digest, signature_manifest: signature_manifest})
  end

  defp signature_manifest(nil), do: %{"layers" => [%{"annotations" => %{"dev.cosignproject.cosign/signature" => "c2ln"}}]}

  defp signature_manifest(annotation) do
    %{
      "layers" => [
        %{
          "annotations" => %{
            "dev.cosignproject.cosign/signature" => "c2ln",
            "dev.sigstore.cosign/bundle" => annotation
          }
        }
      ]
    }
  end

  defp receipt_annotation(log_id) do
    Jason.encode!(%{
      "SignedEntryTimestamp" => "c2V0",
      "Payload" => %{"body" => "e30=", "integratedTime" => 1, "logIndex" => 1, "logID" => log_id}
    })
  end

  # What `cosign verify` prints on stdout for a verified signature with a receipt.
  defp verified_output(log_id, log_index, integrated_time) do
    json =
      Jason.encode!([
        %{
          "optional" => %{
            "Bundle" => %{
              "Payload" => %{"logID" => log_id, "logIndex" => log_index, "integratedTime" => integrated_time}
            }
          }
        }
      ])

    "printf '\\n%s\\n' '#{json}'"
  end

  # A stand-in cosign that records its arguments and environment, then runs `body`.
  defp configure_cosign_script(body) do
    dir = temp_dir("serviceradar-cosign-test")
    path = Path.join(dir, "cosign")
    record = %{args: Path.join(dir, "args"), env: Path.join(dir, "env")}

    File.write!(path, """
    #!/usr/bin/env sh
    printf '%s\\n' "$@" > #{record.args}
    env > #{record.env}
    #{body}
    """)

    File.chmod!(path, 0o700)

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import,
      cosign_binary: path,
      cosign_public_key: "synthetic release public key"
    )

    record
  end

  defp read_record(record) do
    env =
      record.env
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [name, value] = String.split(line, "=", parts: 2)
        {name, value}
      end)

    %{args: record.args |> File.read!() |> String.split("\n", trim: true), env: env}
  end

  defp temp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # The cosign release the web-ng image ships (//docker/images:web_ng_cosign), a
  # declared runfile of the unit test target.
  defp pinned_cosign do
    srcdir = System.get_env("TEST_SRCDIR") || flunk("the pinned cosign is a Bazel runfile; run this test with Bazel")

    srcdir
    |> Path.join("**/downloaded")
    |> Path.wildcard()
    |> Enum.find(&String.contains?(&1, "cosign_linux"))
    |> case do
      nil -> flunk("the pinned cosign runfile is missing")
      path -> path
    end
  end

  defmodule Fixture do
    @moduledoc false
    # A synthetic release key, a stand-in transparency-log key and a loopback OCI registry.

    import ExUnit.Callbacks, only: [start_supervised!: 1, start_supervised!: 2]

    defmodule Registry do
      @moduledoc false
      @behaviour Plug

      import Plug.Conn

      @impl true
      def init(store), do: store

      @impl true
      def call(conn, store) do
        case Agent.get(store, &Map.get(&1, conn.request_path)) do
          nil when conn.request_path in ["/v2", "/v2/"] ->
            send_resp(conn, 200, "{}")

          nil ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, ~s({"errors":[{"code":"MANIFEST_UNKNOWN","message":"unknown"}]}))

          {content_type, body} ->
            conn
            |> put_resp_header("content-type", content_type)
            |> put_resp_header("docker-content-digest", "sha256:" <> sha256_hex(body))
            |> send_resp(200, body)
        end
      end

      def sha256_hex(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    end

    @manifest_type "application/vnd.oci.image.manifest.v1+json"
    @config ~s({"architecture":"","os":"","config":{}})

    # An HTTP proxy on loopback that records each request line and answers 502.
    def start_recording_proxy do
      requests = start_supervised!({Agent, fn -> [] end}, id: :recording_proxy_requests)
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      start_supervised!({Task, fn -> accept(listener, requests) end}, id: :recording_proxy)
      %{url: "http://127.0.0.1:#{port}", requests: requests}
    end

    def proxied_requests(proxy), do: proxy.requests |> Agent.get(& &1) |> Enum.reverse()

    defp accept(listener, requests) do
      {:ok, socket} = :gen_tcp.accept(listener)

      with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000) do
        Agent.update(requests, &[String.trim(line) | &1])
      end

      :gen_tcp.send(socket, "HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\n\r\n")
      :gen_tcp.close(socket)
      accept(listener, requests)
    end

    def start(trust_dir) do
      store = start_supervised!({Agent, fn -> %{} end})
      server = start_supervised!({Bandit, plug: {Registry, store}, ip: :loopback, port: 0, startup_log: false})
      {:ok, {_address, port}} = ThousandIsland.listener_info(server)

      {release_key, release_public_pem} = ec_key()
      {log_key, log_public_pem} = ec_key()
      log_id = log_public_pem |> spki_der() |> Registry.sha256_hex()
      File.write!(Path.join([trust_dir, "rekor-keys", log_id <> ".pub"]), log_public_pem)

      %{
        store: store,
        host: "localhost:#{port}",
        release_key: release_key,
        release_public_pem: release_public_pem,
        log_key: log_key,
        log_id: log_id
      }
    end

    # Push a fresh image and its classic `.sig`, with no receipt or with a receipt that
    # logs either this signature or a genuine entry for another artifact signed with the
    # same key.
    def publish(fixture, logged) do
      put(fixture, "/v2/example/blobs/" <> digest(@config), "application/octet-stream", @config)

      image =
        Jason.encode!(%{
          "schemaVersion" => 2,
          "mediaType" => @manifest_type,
          "config" => descriptor("application/vnd.oci.image.config.v1+json", @config),
          "layers" => [],
          "annotations" => %{"nonce" => Integer.to_string(System.unique_integer([:positive]))}
        })

      image_digest = digest(image)
      repository = "#{fixture.host}/example"
      put(fixture, "/v2/example/manifests/" <> image_digest, @manifest_type, image)

      payload = simple_signing(repository, image_digest)
      signature = sign(fixture.release_key, payload)
      put(fixture, "/v2/example/blobs/" <> digest(payload), "application/octet-stream", payload)

      annotations =
        case logged do
          :no_receipt ->
            %{"dev.cosignproject.cosign/signature" => signature}

          :own_entry ->
            %{
              "dev.cosignproject.cosign/signature" => signature,
              "dev.sigstore.cosign/bundle" => rekor_bundle(fixture, payload, signature)
            }

          :other_entry ->
            other = simple_signing(repository, "sha256:" <> String.duplicate("e", 64))

            %{
              "dev.cosignproject.cosign/signature" => signature,
              "dev.sigstore.cosign/bundle" => rekor_bundle(fixture, other, sign(fixture.release_key, other))
            }
        end

      layer =
        "application/vnd.dev.cosign.simplesigning.v1+json"
        |> descriptor(payload)
        |> Map.put("annotations", annotations)

      signature_manifest = %{
        "schemaVersion" => 2,
        "mediaType" => @manifest_type,
        "config" => descriptor("application/vnd.oci.image.config.v1+json", @config),
        "layers" => [layer]
      }

      signature_tag = String.replace(image_digest, ":", "-") <> ".sig"
      put(fixture, "/v2/example/manifests/" <> signature_tag, @manifest_type, Jason.encode!(signature_manifest))

      {repository <> ":v1", image_digest, signature_manifest}
    end

    # The legacy RekorBundle: a SignedEntryTimestamp the stand-in log signs over the
    # canonical JSON of a hashedrekord entry.
    defp rekor_bundle(fixture, payload, signature) do
      body =
        Jason.encode!(%{
          "apiVersion" => "0.0.1",
          "kind" => "hashedrekord",
          "spec" => %{
            "data" => %{"hash" => %{"algorithm" => "sha256", "value" => Registry.sha256_hex(payload)}},
            "signature" => %{
              "content" => signature,
              "publicKey" => %{"content" => Base.encode64(fixture.release_public_pem)}
            }
          }
        })

      entry = [
        {"body", Base.encode64(body)},
        {"integratedTime", 1_767_225_600},
        {"logID", fixture.log_id},
        {"logIndex", 4242}
      ]

      canonical = entry |> Jason.OrderedObject.new() |> Jason.encode!()

      Jason.encode!(%{"SignedEntryTimestamp" => sign(fixture.log_key, canonical), "Payload" => Map.new(entry)})
    end

    defp simple_signing(repository, image_digest) do
      Jason.encode!(%{
        "critical" => %{
          "identity" => %{"docker-reference" => repository},
          "image" => %{"docker-manifest-digest" => image_digest},
          "type" => "cosign container image signature"
        },
        "optional" => nil
      })
    end

    defp digest(body), do: "sha256:" <> Registry.sha256_hex(body)

    defp descriptor(media_type, body),
      do: %{"mediaType" => media_type, "size" => byte_size(body), "digest" => digest(body)}

    defp put(fixture, path, content_type, body), do: Agent.update(fixture.store, &Map.put(&1, path, {content_type, body}))

    defp sign(key, data), do: data |> :public_key.sign(:sha256, key) |> Base.encode64()

    defp ec_key do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      {:ECPrivateKey, _version, _private, parameters, public, _attributes} = key
      entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, public}, parameters})
      # One PEM block with one trailing newline, as cosign writes public keys.
      {key, String.trim_trailing(:public_key.pem_encode([entry])) <> "\n"}
    end

    defp spki_der(pem) do
      [{:SubjectPublicKeyInfo, der, :not_encrypted}] = :public_key.pem_decode(pem)
      der
    end
  end
end
