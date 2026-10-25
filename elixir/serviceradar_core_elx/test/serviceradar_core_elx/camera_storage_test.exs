ExUnit.start()

defmodule ServiceRadarCoreElx.CameraStorageTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.ArchiveInitConfig
  alias ServiceRadarCoreElx.CameraStorage.Config
  alias ServiceRadarCoreElx.CameraStorage.HTTP
  alias ServiceRadarCoreElx.CameraStorage.Service
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Fixture

  @moduletag :tmp_dir
  @bytes "invented immutable initialization bytes"
  @binding "f23d5f63-1457-4f3d-ae05-80ba21d88f50"
  @storage "f68af8e1-6ecb-4856-a5ad-351a927cd038"
  @dispatch "671e8153-643d-42ce-9df8-a6ac2ec30557"
  @descriptor String.duplicate("b", 64)
  @key "recordings/v1/" <> String.duplicate("a", 64) <> "/init.mp4"
  @recorder_token String.duplicate("r", 40)
  @runtime_token String.duplicate("s", 40)
  @lease %{
    "id" => "c640db9f-09aa-45f0-8493-a8f464fc4ec2",
    "upload_token" => "00000000-0000-4000-8000-000000000002",
    "upload_epoch" => "1",
    "descriptor_sha256" => @descriptor
  }

  setup context do
    {:ok, _} = Application.ensure_all_started(:ssl)
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost", dNSName: ~c"objects.example.test"]}

    certificates =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    parent = self()

    {:ok, store} =
      Agent.start_link(fn ->
        %{parent: parent, mode: context[:mode], provider: [], core: [], marked: false, object: nil}
      end)

    installation = %{deployment_ref: "aee2d1d4-1162-4029-a3d2-bc4d73636634", generation: 1}

    {:ok, desired} =
      ArchiveInitConfig.parse(
        installation,
        put_in(desired(), ["limits", "max_operation_ms"], context[:operation_ms] || 5_000)
      )

    provider_port =
      Fixture.start(certificates.server_config, fn request ->
        Agent.get_and_update(store, &provider(&1, request))
      end)

    core_port =
      Fixture.start(certificates.server_config, fn request ->
        response = Agent.get_and_update(store, &core(&1, request, desired))
        if request.target == "/v1/init-authorities/challenge", do: send(parent, :challenged)
        response
      end)

    roots = Enum.uniq(certificates.server_config[:cacerts] ++ certificates.client_config[:cacerts])

    certfile =
      write_pem(context.tmp_dir, "server.crt", [{:Certificate, certificates.server_config[:cert], :not_encrypted}])

    {key_type, key_der} = certificates.server_config[:key]
    keyfile = write_pem(context.tmp_dir, "server.key", [{key_type, key_der, :not_encrypted}])
    cacertfile = write_pem(context.tmp_dir, "ca.crt", Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
    port = free_port()

    client = %{
      proxy: nil,
      cacerts: roots,
      client_tls: Keyword.take(certificates.client_config, [:cert, :key])
    }

    credential = %{
      "reference" => "synthetic-custody",
      "generation" => 1,
      "access_key_id" => "synthetic-writer",
      "secret_access_key" => "invented-key-material"
    }

    credentials_path = write_file(context.tmp_dir, "credentials.json", Jason.encode!(credential))
    recorder_path = write_file(context.tmp_dir, "recorder-token", @recorder_token)
    runtime_path = write_file(context.tmp_dir, "runtime-token", @runtime_token)
    tls = %{"certfile" => certfile, "keyfile" => keyfile, "cacertfile" => cacertfile}

    document = %{
      "schema_version" => 1,
      "deployment_ref" => installation.deployment_ref,
      "generation" => "1",
      "desired" => desired.document,
      "provider_credentials_file" => credentials_path,
      "listener" =>
        Map.merge(tls, %{
          "port" => port,
          "token_file" => recorder_path,
          "recorder_certificate_sha256" =>
            if(context[:wrong_pin], do: String.duplicate("0", 64), else: digest(certificates.client_config[:cert]))
        }),
      "runtime" => Map.merge(tls, %{"base_url" => "https://localhost:#{core_port}", "token_file" => runtime_path})
    }

    config_path = write_file(context.tmp_dir, "config.json", Jason.encode!(document))
    assert {:ok, config} = Config.load(config_path)
    # Synthetic provider trust and CONNECT routing exist only in this fixture.
    config = put_in(config.provider, Map.merge(config.provider, %{proxy: Fixture.proxy(provider_port), cacerts: roots}))

    start_supervised!({Service, config})
    assert_receive :challenged, 5_000

    %{
      client: client,
      url: "https://localhost:#{port}/v1/init-uploads",
      port: port,
      store: store,
      config_path: config_path,
      credentials_path: credentials_path,
      credential: credential,
      runtime_path: runtime_path
    }
  end

  test "isolated HTTPS ingress performs one signed conditional PUT and verifies exact versioned bytes", ctx do
    assert {:ok, %{status: 200, body: body}} = upload(ctx)
    assert %{"status" => "init_verified", "archive_readiness" => "unavailable"} = Jason.decode!(body)
    state = Agent.get(ctx.store, & &1)
    assert [%{method: "PUT"} = put, %{method: "HEAD"} = head, %{method: "GET"} = get] = Enum.reverse(state.provider)

    assert head.target == "/synthetic-media/" <> @key <> "?versionId=version-1"
    assert get.target == head.target
    assert head.headers["if-match"] == ~s("synthetic-etag")
    assert get.headers["range"] == "bytes=0-#{byte_size(@bytes) - 1}"

    assert [verification] = for({"/v1/init-uploads/verify", value} <- state.core, do: value["verification"])
    assert verification["object_sha256"] == digest(@bytes)
    assert verification["byte_length"] == byte_size(@bytes)
    assert verification["version_id"] == "version-1"
    assert_put_wire(put, verification)

    assert {:ok, %{status: 503}} = upload(ctx)
    assert length(Agent.get(ctx.store, & &1.provider)) == 3
  end

  @tag mode: :held_put
  test "one in-flight request retains its slot until provider work finishes", ctx do
    first = Task.async(fn -> upload(ctx) end)
    assert_receive {:held_response, provider}, 5_000
    assert {:ok, %{status: 503, body: body}} = upload(ctx)
    assert Jason.decode!(body) == %{"error" => "storage_busy"}
    assert Enum.count(Agent.get(ctx.store, & &1.core), fn {path, _} -> path == "/v1/init-uploads/prepare" end) == 1
    send(provider, :release_response)
    assert {:ok, %{status: 200}} = Task.await(first, 5_000)
  end

  @tag mode: :slow_grant, operation_ms: 1_000
  test "time spent receiving the body cannot renew the provider deadline", ctx do
    body = Jason.encode!(%{"schema_version" => 1, "lease" => @lease, "init_base64" => Base.encode64(@bytes)})
    options = [:binary, active: false, verify: :verify_peer, cacerts: ctx.client.cacerts] ++ ctx.client.client_tls
    assert {:ok, socket} = :ssl.connect(~c"localhost", ctx.port, options, 2_000)
    on_exit(fn -> :ssl.close(socket) end)

    assert :ok =
             :ssl.send(socket, [
               "POST /v1/init-uploads HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ",
               @recorder_token,
               "\r\nContent-Type: application/json\r\nContent-Length: ",
               Integer.to_string(byte_size(body)),
               "\r\n\r\n",
               binary_part(body, 0, 1)
             ])

    Process.sleep(600)
    assert :ok = :ssl.send(socket, binary_part(body, 1, byte_size(body) - 1))
    assert {:ok, response} = :ssl.recv(socket, 0, 2_000)
    assert response =~ "503"
    assert Agent.get(ctx.store, & &1.provider) == []
    assert Enum.any?(Agent.get(ctx.store, & &1.core), fn {path, _} -> path == "/v1/init-uploads/grant" end)
  end

  test "mounted provider identity and separate purpose tokens are enforced", ctx do
    File.write!(ctx.credentials_path, Jason.encode!(Map.put(ctx.credential, "generation", 2)))
    assert {:error, :invalid_storage_configuration} = Config.load(ctx.config_path)
    File.write!(ctx.credentials_path, Jason.encode!(ctx.credential))
    File.write!(ctx.runtime_path, @recorder_token)
    assert {:error, :invalid_storage_configuration} = Config.load(ctx.config_path)
    assert Agent.get(ctx.store, & &1.provider) == []
  end

  for mode <- [:denied_grant, :wrong_nonce, :late_grant] do
    @tag mode: mode
    test "#{mode} makes no provider request", ctx do
      assert {:ok, %{status: 503}} = upload(ctx)
      assert Agent.get(ctx.store, & &1.provider) == []
      refute Enum.any?(Agent.get(ctx.store, & &1.core), fn {path, _} -> path == "/v1/init-uploads/verify" end)
    end
  end

  for mode <- [:wrong_bytes, :wrong_identity, :wrong_encryption, :whole_object_fallback, :conflict, :lost_put] do
    @tag mode: mode
    test "#{mode} withholds verification and cannot cause another PUT", ctx do
      assert {:ok, %{status: 503}} = upload(ctx)
      assert {:ok, %{status: 503}} = upload(ctx)
      state = Agent.get(ctx.store, & &1)
      assert Enum.count(state.provider, &(&1.method == "PUT")) == 1
      refute Enum.any?(state.core, fn {path, _} -> path == "/v1/init-uploads/verify" end)

      if state.mode == :lost_put do
        assert Enum.any?(state.core, fn {path, value} ->
                 path == "/v1/init-uploads/observe" and value["outcome"] == "unknown"
               end)
      end
    end
  end

  @tag wrong_pin: true
  test "a trusted but unpinned client certificate cannot prepare an upload", ctx do
    assert {:ok, %{status: 401}} = upload(ctx)
    assert Agent.get(ctx.store, & &1.provider) == []
    assert [{"/v1/init-authorities/challenge", _}] = Agent.get(ctx.store, & &1.core)
  end

  test "authentication and duplicate JSON are rejected before preparation", ctx do
    assert {:ok, %{status: 401}} = upload(ctx, token: String.duplicate("x", 40))
    assert {:ok, %{status: 401}} = upload(ctx, extra_headers: [{"authorization", "Bearer " <> @recorder_token}])
    duplicate = ~S({"schema_version":1,"schema_versi\u006fn":1,"lease":{},"init_base64":"eA=="})
    assert {:ok, %{status: 400}} = upload(ctx, body: duplicate)
    assert {:ok, %{status: 413}} = upload(ctx, body: String.duplicate("x", 1_400_001))
    assert Agent.get(ctx.store, & &1.provider) == []
    assert [{"/v1/init-authorities/challenge", _}] = Agent.get(ctx.store, & &1.core)
  end

  defp assert_put_wire(put, verification) do
    assert put.body == @bytes
    assert put.headers["if-none-match"] == "*"
    assert put.headers["x-amz-server-side-encryption"] == "AES256"
    assert put.headers["x-amz-checksum-sha256"] == Base.encode64(:crypto.hash(:sha256, @bytes))
    assert [_, signed] = Regex.run(~r/SignedHeaders=([^,]+)/, put.headers["authorization"])

    assert Enum.all?(
             ~w(if-none-match x-amz-server-side-encryption x-amz-checksum-sha256),
             &(&1 in String.split(signed, ";"))
           )

    pairs = put.headers |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end)
    expected = ["init-put-wire-v1", "PUT", "https://objects.example.test" <> put.target, pairs, digest(@bytes)]
    assert verification["put_request_sha256"] == digest(Jason.encode!(expected))
  end

  defp upload(ctx, opts \\ []) do
    body =
      opts[:body] || Jason.encode!(%{"schema_version" => 1, "lease" => @lease, "init_base64" => Base.encode64(@bytes)})

    headers =
      [
        {"authorization", "Bearer " <> (opts[:token] || @recorder_token)},
        {"content-type", "application/json"},
        {"content-length", Integer.to_string(byte_size(body))}
      ] ++ (opts[:extra_headers] || [])

    HTTP.request(ctx.client, :post, ctx.url, headers, body, 10_000, 4096)
  end

  defp core(state, request, desired) do
    input = Jason.decode!(request.body)
    state = %{state | core: [{request.target, input} | state.core]}

    case request.target do
      "/v1/init-authorities/challenge" ->
        body =
          Map.merge(input, %{
            "state" => "pending",
            "issued_at_ms" => "1800000000000",
            "expires_at_ms" => "1800000030000",
            "remaining_ms" => 30_000,
            "applied_revision" => nil,
            "recording_readiness" => "unavailable",
            "archive_readiness" => "unavailable",
            "reason" => "init_authority_only"
          })

        {json(200, body), state}

      "/v1/init-uploads/prepare" ->
        {json(200, %{"schema_version" => 1, "dispatch_id" => @dispatch}), state}

      "/v1/init-uploads/grant" ->
        grant(state, input, desired)

      "/v1/init-uploads/observe" ->
        {json(200, %{"schema_version" => 1, "status" => "recorded"}), state}

      "/v1/init-uploads/verify" ->
        {json(200, %{"schema_version" => 1, "status" => "recorded", "dispatch_id" => @dispatch}), state}
    end
  end

  defp grant(%{marked: true} = state, _, _), do: {json(409, %{"error" => "already_marked"}), state}
  defp grant(%{mode: :denied_grant} = state, _, _), do: {json(409, %{"error" => "authority_unavailable"}), state}

  defp grant(state, input, desired) do
    body =
      input
      |> Map.take(~w(schema_version dispatch_id storage_boot_id desired_sha256 nonce))
      |> Map.merge(%{
        "status" => "granted",
        "binding_id" => @binding,
        "revision" => "1",
        "remaining_ms" => 5_000,
        "request_sha256" => String.duplicate("d", 64),
        "object_key" => @key,
        "byte_length" => byte_size(@bytes),
        "object_sha256" => digest(@bytes),
        "descriptor_sha256" => @descriptor,
        "local_storage_id" => desired.local_storage_id
      })

    response =
      case state.mode do
        :wrong_nonce -> json(200, Map.put(body, "nonce", String.duplicate("0", 64)))
        :late_grant -> {:delay, 100, json(200, Map.put(body, "remaining_ms", 10))}
        :slow_grant -> {:delay, 600, json(200, body)}
        _ -> json(200, body)
      end

    {response, %{state | marked: true}}
  end

  defp provider(state, request) do
    provider_response(%{state | provider: [request | state.provider]}, request)
  end

  defp provider_response(state, %{method: "PUT"} = request) do
    stored = if state.mode == :wrong_bytes, do: String.duplicate("x", byte_size(request.body)), else: request.body

    response =
      case state.mode do
        :conflict -> {412, %{}, ""}
        :lost_put -> :close
        :held_put -> {:hold, state.parent, {200, identity_headers(), ""}}
        _ -> {200, identity_headers(), ""}
      end

    {response, %{state | object: stored}}
  end

  defp provider_response(state, %{method: "HEAD"}) do
    headers = Map.put(identity_headers(), "content-length", Integer.to_string(byte_size(state.object)))
    headers = if state.mode == :wrong_identity, do: Map.put(headers, "etag", ~s("different-etag")), else: headers

    headers =
      if state.mode == :wrong_encryption, do: Map.put(headers, "x-amz-server-side-encryption", "other"), else: headers

    {{200, headers, ""}, state}
  end

  defp provider_response(state, %{method: "GET"}) do
    size = byte_size(state.object)
    headers = Map.put(identity_headers(), "content-range", "bytes 0-#{size - 1}/#{size}")
    status = if state.mode == :whole_object_fallback, do: 200, else: 206
    {{status, headers, state.object}, state}
  end

  defp identity_headers,
    do: %{"etag" => ~s("synthetic-etag"), "x-amz-version-id" => "version-1", "x-amz-server-side-encryption" => "AES256"}

  defp desired do
    checks =
      ~w(intended_operations anonymous_access_denied foreign_environment_access_denied recorder_privilege_boundary reader_privilege_boundary private_acl_policy endpoint_tls_redirect_boundary browser_cors put_aes256_attestation multipart_aes256_attestation put_missing_aes256_denied put_noncompliant_aes256_denied multipart_missing_aes256_denied multipart_noncompliant_aes256_denied atomic_put_no_overwrite atomic_completion_no_overwrite integrity_object_identity conditional_ranges multipart_recovery)

    %{
      "schema_version" => 1,
      "revision" => "1",
      "binding_id" => @binding,
      "local_storage_id" => @storage,
      "operation" => "init_put_verified_v1",
      "protection_mode" => "sse_s3_aes256",
      "limits" => %{"max_init_bytes" => 1_048_576, "max_operation_ms" => 5_000, "max_in_flight" => 1},
      "qualification_report" => %{
        "schema_version" => 1,
        "binding_id" => @binding,
        "destination" => %{
          "schema_version" => 1,
          "provisioning_ref" => "synthetic-storage",
          "generation" => 1,
          "purpose" => "recording",
          "provider" => "s3_compatible",
          "endpoint" => "https://objects.example.test",
          "region" => "test-region",
          "bucket" => "synthetic-media",
          "namespace" => "recordings/v1",
          "archive_format_version" => 1,
          "required_encryption" => "sse_s3_aes256"
        },
        "provider_resource_id" => "synthetic-resource",
        "endpoint_type" => "synthetic-s3",
        "credential" => %{
          "reference" => "synthetic-custody",
          "generation" => 1,
          "storage_service_id" => "synthetic-storage-service"
        },
        "policy_revision" => "synthetic-policy",
        "operation_mode" => "mediated_immutable_archive_v1",
        "issued_at_ms" => 1_800_000_000_000,
        "expires_at_ms" => 1_800_000_030_000,
        "result_ref" => "synthetic-evidence",
        "checks" => Map.new(checks, &{&1, "passed"})
      }
    }
  end

  defp json(status, body), do: {status, %{"content-type" => "application/json"}, Jason.encode!(body)}
  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp write_pem(directory, name, entries), do: write_file(directory, name, :public_key.pem_encode(entries))

  defp write_file(directory, name, bytes) do
    path = Path.join(directory, name)
    File.write!(path, bytes)
    path
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end
end
