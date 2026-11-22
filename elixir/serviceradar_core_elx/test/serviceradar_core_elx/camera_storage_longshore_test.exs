ExUnit.start()

defmodule ServiceRadarCoreElx.CameraStorageLongshoreTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveStorageConfig, as: Config
  alias ServiceRadar.Camera.ArchiveStorageHTTP, as: HTTP
  alias ServiceRadarCoreElx.CameraStorage.ReadLongshorePool
  alias ServiceRadarCoreElx.CameraStorage.Service
  alias ServiceRadarCoreElx.CameraStorage.Session
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Fixture
  alias ServiceRadarObjectStorage.Session, as: ObjectStorageSession

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  @init_bytes "invented immutable initialization bytes"
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
    kind = context[:kind] || :init
    kinds = context[:purposes] || [kind]
    payloads = Map.new(kinds, &{&1, payload(&1)})
    bytes = payloads[kind]

    {:ok, store} =
      Agent.start_link(fn ->
        %{
          parent: parent,
          mode: context[:mode],
          version_header: Map.get(context, :version_header, "version-1"),
          kind: kind,
          bytes: bytes,
          payloads: payloads,
          core: [],
          provider: [],
          marked: MapSet.new(),
          object: nil
        }
      end)

    installation = %{deployment_ref: "aee2d1d4-1162-4029-a3d2-bc4d73636634", generation: 1}

    desired =
      Map.new(kinds, fn purpose ->
        {:ok, parsed} =
          ArchiveAuthorityConfig.parse(
            purpose,
            installation,
            put_in(
              desired(purpose),
              ["limits", "max_operation_ms"],
              context[:operation_ms] || if(purpose == :init, do: 5_000, else: 30_000)
            )
          )

        {purpose, parsed}
      end)

    provider_port =
      if context[:closed_provider] do
        free_port()
      else
        start_loopback_provider(fn request ->
          Agent.get_and_update(store, &provider(&1, request))
        end)
      end

    core_port =
      Fixture.start(certificates.server_config, fn request ->
        response = Agent.get_and_update(store, &core(&1, request, desired))
        if String.ends_with?(request.target, "-authorities/challenge"), do: send(parent, :challenged)
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
      "provider_transport" => "longshore",
      "desired" => desired[kind].document,
      "provider_credentials_file" => credentials_path,
      "listener" =>
        Map.merge(tls, %{
          "port" => port,
          "token_file" => recorder_path,
          "recorder_certificate_sha256" => digest(certificates.client_config[:cert])
        }),
      "runtime" => Map.merge(tls, %{"base_url" => "https://localhost:#{core_port}", "token_file" => runtime_path})
    }

    document =
      if context[:purposes] do
        document
        |> Map.delete("desired")
        |> Map.put("schema_version", 2)
        |> Map.put("purposes", Map.new(desired, fn {purpose, parsed} -> {Atom.to_string(purpose), parsed.document} end))
      else
        document
      end

    config_path = write_file(context.tmp_dir, "config.json", Jason.encode!(document))
    assert {:ok, config} = Config.load(config_path)
    assert config.provider.transport == :longshore

    config = put_in(config.provider[:longshore_loopback_peer], {"127.0.0.1", provider_port})

    service =
      if context[:skip_service] do
        nil
      else
        pid = start_supervised!(Supervisor.child_spec({Service, config}, restart: :temporary))
        for _ <- kinds, do: assert_receive(:challenged, 5_000)
        pid
      end

    %{
      client: client,
      service: service,
      config: config,
      bytes: bytes,
      payloads: payloads,
      kind: kind,
      url: "https://localhost:#{port}/v1/#{kind}-uploads",
      port: port,
      provider_port: provider_port,
      store: store,
      credential: credential,
      tls: tls,
      roots: roots
    }
  end

  @tag purposes: [:init, :media, :manifest]
  test "verifies init, multi-chunk >4 MiB media, and manifest via Longshore with canonical-v1 evidence and omitted provider SHA-256",
       ctx do
    for kind <- [:init, :media, :manifest] do
      assert {:ok, %{status: 200, body: body}} = upload_role(ctx, kind)
      assert Jason.decode!(body)["status"] == "#{kind}_verified"
      assert {:ok, %{status: 503}} = upload_role(ctx, kind)
    end

    state = Agent.get(ctx.store, & &1)
    requests = Enum.reverse(state.provider)
    puts = Enum.filter(requests, &(&1.method == "PUT"))
    gets = Enum.filter(requests, &(&1.method == "GET"))

    assert length(puts) == 3
    # :init (1 GET) + :media 4.84 MiB (2 GETs of 4 MiB + remainder) + :manifest (1 GET) = 4 ranged GETs
    assert length(gets) == 4

    for {kind, put} <- Enum.zip([:init, :media, :manifest], puts) do
      expected_bytes = Map.fetch!(ctx.payloads, kind)
      assert_longshore_canonical_evidence(kind, put, expected_bytes, state.core)
    end
  end

  @tag version_header: "null"
  test "normalizes literal null version header to nil across Longshore PUT, HEAD, and GET verification", ctx do
    assert {:ok, %{status: 200, body: body}} = upload(ctx)
    assert Jason.decode!(body)["status"] == "init_verified"

    state = Agent.get(ctx.store, & &1)

    assert [{"/v1/init-uploads/verify", %{"verification" => verification}}] =
             Enum.filter(state.core, fn {path, _} -> path == "/v1/init-uploads/verify" end)

    assert verification["version_id"] == nil
    assert verification["etag"] == ~s("synthetic-etag")

    heads = Enum.filter(state.provider, &(&1.method == "HEAD"))
    assert [%{target: head_target, headers: head_headers}] = heads
    refute String.contains?(head_target, "versionId=")
    assert head_headers["if-match"] == ~s("synthetic-etag")
  end

  test "ReadService serves verified ranges via Longshore and withholds XML error bodies on 412 refusal", ctx do
    reader = start_read_service(ctx)
    media_slice = "invented archived media fragment bytes"
    Agent.update(ctx.store, &%{&1 | object: media_slice})

    plan = %{
      "schema_version" => 1,
      "binding_id" => @binding,
      "destination_sha256" => reader.destination_sha256,
      "descriptor_sha256" => @descriptor,
      "manifest_verification_sha256" => String.duplicate("c", 64),
      "block_id" => @storage,
      "object_key" => object_key(:media),
      "first" => 9,
      "last" => 16,
      "size" => byte_size(media_slice),
      "etag" => ~s("synthetic-etag"),
      "version_id" => "version-1",
      "sha256" => digest(binary_part(media_slice, 9, 8))
    }

    assert {:ok, %{status: 200, body: "archived"}} = read_range(reader, plan)

    Agent.update(ctx.store, &%{&1 | mode: :read_precondition_failed})
    assert {:ok, %{status: 503, body: refused_body}} = read_range(reader, plan)
    assert Jason.decode!(refused_body) == %{"error" => "archive_read_unavailable"}
    refute refused_body =~ "PreconditionFailed"
    refute refused_body =~ "xml-error-sentinel"
  end

  for mode <- [:wrong_bytes, :wrong_identity, :wrong_encryption, :whole_object_fallback, :conflict, :lost_put] do
    @tag mode: mode
    test "#{mode} withholds verification and never replays a granted Longshore PUT", ctx do
      assert {:ok, %{status: 503}} = upload(ctx)
      assert {:ok, %{status: 503}} = upload(ctx)
      state = Agent.get(ctx.store, & &1)
      assert Enum.count(state.provider, &(&1.method == "PUT")) == 1
      refute Enum.any?(state.core, fn {path, _} -> path == "/v1/init-uploads/verify" end)
      assert_failure_observation(unquote(mode), state.core)
    end
  end

  defp assert_failure_observation(:lost_put, core_calls) do
    assert Enum.any?(core_calls, fn {path, value} ->
             path == "/v1/init-uploads/observe" and value["outcome"] == "unknown"
           end)
  end

  defp assert_failure_observation(:conflict, core_calls) do
    assert Enum.any?(core_calls, fn {path, value} ->
             path == "/v1/init-uploads/observe" and value["outcome"] == "response" and
               value["response"]["status"] == 412
           end)
  end

  defp assert_failure_observation(_mode, _core_calls), do: :ok

  @tag closed_provider: true
  test "unconnected NotSent Longshore failure withholds both unknown observation and verification", ctx do
    assert {:ok, %{status: 503, body: body}} = upload(ctx)
    assert Jason.decode!(body) == %{"error" => "init_upload_not_sent"}

    state = Agent.get(ctx.store, & &1)
    refute Enum.any?(state.core, fn {path, _} -> path == "/v1/init-uploads/observe" end)
    refute Enum.any?(state.core, fn {path, _} -> path == "/v1/init-uploads/verify" end)
  end

  @tag mode: :held_put
  test "caller disconnect holds Session admission until the in-flight Longshore PUT physically completes", ctx do
    body = Jason.encode!(%{"schema_version" => 1, "lease" => @lease, "init_base64" => Base.encode64(@init_bytes)})
    ingress_socket = open_ingress_post(ctx, "/v1/init-uploads", body)

    assert_receive {:held_response, peer_pid}, 5_000
    :ssl.close(ingress_socket)

    # Trigger cancellation while Longshore native PUT is still held on the socket.
    session_state = :sys.get_state(Session)

    if session_state.stage do
      send(Process.whereis(Session), {:stage_timeout, session_state.stage.token, session_state.stage.phase})
    end

    assert eventually(fn -> :sys.get_state(Session).draining_token != nil end)
    assert {:ok, %{status: 503, body: busy_body}} = upload(ctx)
    assert Jason.decode!(busy_body) == %{"error" => "storage_busy"}

    send(peer_pid, :release_response)
    assert eventually(fn -> :sys.get_state(Session).draining_token == nil end)
  end

  @tag :skip_service
  test "shutdown budgets outlast the 35 s ObjectStorage.Session drain", ctx do
    object_storage_shutdown =
      Supervisor.child_spec({ObjectStorageSession, config: %{}}, []).shutdown

    assert object_storage_shutdown > 30_000
    assert %{type: :supervisor, shutdown: :infinity} = Supervisor.child_spec({Service, ctx.config}, [])
    assert Supervisor.child_spec({Session, ctx.config}, []).shutdown > object_storage_shutdown

    assert Supervisor.child_spec({ServiceRadarCoreElx.CameraStorage.ReadSession, ctx.config}, []).shutdown >
             object_storage_shutdown
  end

  @tag skip_service: true
  test "Service refuses Longshore startup when an egress proxy or custom non-system CA bundle is configured", ctx do
    proxied =
      update_in(ctx.config, [:provider], fn provider ->
        provider
        |> Map.delete(:longshore_loopback_peer)
        |> Map.put(:proxy, %{scheme: :http, host: "127.0.0.1", port: 3128})
      end)

    assert {:error, :unsupported_provider_proxy} = Service.start_link(proxied)
    assert {:error, :unsupported_provider_proxy} = Service.start_read_link(proxied)

    custom_ca =
      update_in(ctx.config, [:provider], fn provider ->
        provider
        |> Map.delete(:longshore_loopback_peer)
        |> Map.put(:cacerts, ctx.roots)
      end)

    assert {:error, :unsupported_provider_cacerts} = Service.start_link(custom_ca)
    assert {:error, :unsupported_provider_cacerts} = Service.start_read_link(custom_ca)
  end

  @tag skip_service: true
  test "per-request ReadService serves verified ranges, rotates credentials across real Longshore NIF clients, and maps 404/412",
       ctx do
    reader = start_per_request_read_service(ctx)
    media_slice = "invented archived media fragment bytes for per-request longshore"
    Agent.update(ctx.store, &%{&1 | object: media_slice})
    block_key = String.duplicate("ab", 32)
    expected_slice = binary_part(media_slice, 9, 8)

    build_req = fn access_key, secret_key, session_token ->
      cred = %{"access_key_id" => access_key, "secret_access_key" => secret_key}
      cred = if session_token, do: Map.put(cred, "session_token", session_token), else: cred

      %{
        "schema_version" => 1,
        "destination" => ctx.config.provider.destination,
        "credential" => cred,
        "plan" => %{
          "storage_id" => @storage,
          "block_key" => block_key,
          "object_key" => "recordings/v1/#{@storage}/#{block_key}/media.m4s",
          "first" => 9,
          "last" => 16,
          "size" => byte_size(media_slice),
          "etag" => ~s("synthetic-etag"),
          "version_id" => "version-1",
          "sha256" => digest(expected_slice)
        }
      }
    end

    # First credential opens an active Longshore NIF client clamped to concurrency 4 and signs session token.
    req_a = build_req.("SYNTHETICREADERA01", "invented-longshore-secret-a", "invented-session-token-a")
    assert {:ok, %{status: 200, body: ^expected_slice}} = read_timeline_range(reader, req_a)

    active_pid = :sys.get_state(ReadLongshorePool).active.pid
    assert ObjectStorageSession.info(active_pid).workers == 4

    [first_get | _] = Agent.get(ctx.store, & &1.provider)
    assert first_get.headers["authorization"] =~ "Credential=SYNTHETICREADERA01/"
    assert first_get.headers["x-amz-security-token"] == "invented-session-token-a"

    # Second credential rotates active client to draining and retires it cleanly so a third rotation succeeds.
    req_b = build_req.("SYNTHETICREADERB02", "invented-longshore-secret-b", nil)
    assert {:ok, %{status: 200, body: ^expected_slice}} = read_timeline_range(reader, req_b)
    assert eventually(fn -> :sys.get_state(ReadLongshorePool).draining == nil end)

    req_c = build_req.("SYNTHETICREADERC03", "invented-longshore-secret-c", nil)
    assert {:ok, %{status: 200, body: ^expected_slice}} = read_timeline_range(reader, req_c)
    [third_get | _] = Agent.get(ctx.store, & &1.provider)
    assert third_get.headers["authorization"] =~ "Credential=SYNTHETICREADERC03/"

    # 412 -> 409 integrity mismatch and 404 -> 404 not found without leaking XML or credentials.
    Agent.update(ctx.store, &%{&1 | mode: :read_precondition_failed})
    assert {:ok, %{status: 409, body: mismatch_body}} = read_timeline_range(reader, req_c)
    assert Jason.decode!(mismatch_body) == %{"error" => "archive_integrity_mismatch"}
    refute mismatch_body =~ "xml-error-sentinel"
    refute mismatch_body =~ "invented-longshore-secret-c"

    Agent.update(ctx.store, &%{&1 | mode: :read_not_found})
    assert {:ok, %{status: 404, body: missing_body}} = read_timeline_range(reader, req_c)
    assert Jason.decode!(missing_body) == %{"error" => "archive_object_not_found"}
    refute missing_body =~ "NoSuchKey"
    refute missing_body =~ "invented-longshore-secret-c"
  end

  defp assert_longshore_canonical_evidence(kind, put, expected_bytes, core_calls) do
    object_sha = digest(expected_bytes)
    assert put.body == expected_bytes
    assert put.headers["if-none-match"] == "*"
    assert put.headers["x-amz-server-side-encryption"] == "AES256"
    assert put.headers["x-amz-checksum-sha256"] == Base.encode64(:crypto.hash(:sha256, expected_bytes))
    refute Map.has_key?(put.headers, "x-amz-checksum-crc64nvme")

    [_, signed_headers] = Regex.run(~r/SignedHeaders=([^,\s]+)/, put.headers["authorization"])
    canonical_headers = Enum.map_join(String.split(signed_headers, ";"), "\n", &"#{&1}:#{String.trim(put.headers[&1])}")

    canonical_request =
      Enum.join(
        [
          "PUT",
          put.target,
          "",
          canonical_headers <> "\n",
          signed_headers,
          put.headers["x-amz-content-sha256"]
        ],
        "\n"
      )

    canonical_hex = digest(canonical_request)

    expected_evidence =
      digest(
        Jason.encode!([
          "#{kind}-put-canonical-v1",
          "PUT",
          "https://objects.example.test" <> put.target,
          put.headers["x-amz-date"],
          signed_headers,
          canonical_hex,
          object_sha
        ])
      )

    assert [{_, %{"verification" => verification}}] =
             Enum.filter(core_calls, fn {path, _} -> path == "/v1/#{kind}-uploads/verify" end)

    assert verification["put_request_sha256"] == expected_evidence
    assert verification["object_sha256"] == object_sha
  end

  defp start_read_service(ctx) do
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    certificates =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    roots = Enum.uniq(ctx.roots ++ certificates.client_config[:cacerts] ++ certificates.server_config[:cacerts])
    ca = write_pem(ctx.tmp_dir, "reader-ca.crt", Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
    cert = write_pem(ctx.tmp_dir, "reader.crt", [{:Certificate, certificates.client_config[:cert], :not_encrypted}])
    {key_type, key_der} = certificates.client_config[:key]
    key = write_pem(ctx.tmp_dir, "reader.key", [{key_type, key_der, :not_encrypted}])
    token = String.duplicate("p", 40)
    tokenfile = write_file(ctx.tmp_dir, "reader-token", token)

    credentialfile =
      write_file(
        ctx.tmp_dir,
        "reader-credential.json",
        Jason.encode!(%{
          ctx.credential
          | "access_key_id" => "synthetic-reader",
            "secret_access_key" => "invented-reader-key"
        })
      )

    port = free_port()

    document = %{
      "schema_version" => 1,
      "binding_id" => @binding,
      "provider_transport" => "longshore",
      "destination" => ctx.config.provider.destination,
      "provider_credentials_file" => credentialfile,
      "listener" =>
        Map.merge(ctx.tls, %{
          "port" => port,
          "cacertfile" => ca,
          "reader_certificate_sha256" => digest(certificates.client_config[:cert]),
          "token_file" => tokenfile
        })
    }

    path = write_file(ctx.tmp_dir, "reader-storage.json", Jason.encode!(document))
    assert {:ok, config} = Config.load_read_storage(path)
    config = put_in(config.provider[:longshore_loopback_peer], {"127.0.0.1", ctx.provider_port})
    start_supervised!(%{id: :reader_service, start: {Service, :start_read_link, [config]}, restart: :temporary})

    client_doc = %{
      "schema_version" => 1,
      "binding_id" => @binding,
      "destination_sha256" => config.destination_sha256,
      "storage" => %{
        "base_url" => "https://localhost:#{port}",
        "certfile" => cert,
        "keyfile" => key,
        "cacertfile" => ca,
        "token_file" => tokenfile
      }
    }

    client_path = write_file(ctx.tmp_dir, "reader-client.json", Jason.encode!(client_doc))
    {:ok, installed} = Config.load_reader(client_path)
    installed
  end

  defp read_range(installed, plan) do
    body = Jason.encode!(plan)

    headers = [
      {"authorization", "Bearer " <> installed.client.token},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    HTTP.request(installed.client, :post, installed.client.base_url <> "/v1/archive-ranges", headers, body, 5_000, 65_536)
  end

  defp start_per_request_read_service(ctx) do
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    certificates =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    roots = Enum.uniq(ctx.roots ++ certificates.client_config[:cacerts] ++ certificates.server_config[:cacerts])
    ca = write_pem(ctx.tmp_dir, "per-req-ca.crt", Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
    cert = write_pem(ctx.tmp_dir, "per-req.crt", [{:Certificate, certificates.client_config[:cert], :not_encrypted}])
    {key_type, key_der} = certificates.client_config[:key]
    key = write_pem(ctx.tmp_dir, "per-req.key", [{key_type, key_der, :not_encrypted}])
    token = String.duplicate("q", 40)
    tokenfile = write_file(ctx.tmp_dir, "per-req-token", token)
    port = free_port()

    document = %{
      "schema_version" => 1,
      "mode" => "per_request",
      "listener" =>
        Map.merge(ctx.tls, %{
          "port" => port,
          "cacertfile" => ca,
          "reader_certificate_sha256" => digest(certificates.client_config[:cert]),
          "token_file" => tokenfile
        })
    }

    path = write_file(ctx.tmp_dir, "per-req-storage.json", Jason.encode!(document))

    env_vars = %{
      "SERVICERADAR_ARCHIVE_READER_PROVIDER_TRANSPORT" => "longshore",
      "SERVICERADAR_ARCHIVE_READER_MAX_CONCURRENCY" => "12",
      "SERVICERADAR_ARCHIVE_READER_PORTABLE" => "true"
    }

    previous = Map.new(env_vars, fn {k, _} -> {k, System.get_env(k)} end)

    config =
      try do
        Enum.each(env_vars, fn {k, v} -> System.put_env(k, v) end)
        assert {:ok, loaded} = Config.load_read_storage(path)
        loaded
      after
        Enum.each(previous, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end

    assert config.mode == :per_request
    assert config.max_concurrency == 12
    assert config.provider.transport == :longshore
    assert config.provider.portable == true

    config = put_in(config.provider[:longshore_loopback_peer], {"127.0.0.1", ctx.provider_port})

    start_supervised!(%{
      id: :per_request_longshore_reader_service,
      start: {Service, :start_read_link, [config]},
      restart: :temporary
    })

    client_doc = %{
      "schema_version" => 1,
      "storage" => %{
        "base_url" => "https://localhost:#{port}",
        "certfile" => cert,
        "keyfile" => key,
        "cacertfile" => ca,
        "token_file" => tokenfile
      }
    }

    client_path = write_file(ctx.tmp_dir, "per-req-client.json", Jason.encode!(client_doc))
    {:ok, installed} = Config.load_timeline_reader(client_path)
    installed
  end

  defp read_timeline_range(installed, payload) do
    body = Jason.encode!(payload)

    headers = [
      {"authorization", "Bearer " <> installed.client.token},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    HTTP.request(
      installed.client,
      :post,
      installed.client.base_url <> "/v1/timeline-archive-ranges",
      headers,
      body,
      5_000,
      65_536
    )
  end

  defp open_ingress_post(ctx, path, body) do
    options = [:binary, active: false, verify: :verify_peer, cacerts: ctx.client.cacerts] ++ ctx.client.client_tls
    {:ok, socket} = :ssl.connect(~c"localhost", ctx.port, options, 2_000)

    :ok =
      :ssl.send(socket, [
        "POST ",
        path,
        " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ",
        @recorder_token,
        "\r\nContent-Type: application/json\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])

    socket
  end

  defp upload_role(ctx, :init) do
    upload(%{ctx | kind: :init, bytes: ctx.payloads[:init], url: "https://localhost:#{ctx.port}/v1/init-uploads"})
  end

  defp upload_role(ctx, kind) when kind in [:media, :manifest] do
    bytes = Map.fetch!(ctx.payloads, kind)
    url = "https://localhost:#{ctx.port}/v1/#{kind}-uploads"

    headers = [
      {"authorization", "Bearer " <> @recorder_token},
      {"content-type", "application/octet-stream"},
      {"content-length", Integer.to_string(byte_size(bytes))},
      {"x-serviceradar-upload-lease", Jason.encode!(@lease)}
    ]

    HTTP.request(ctx.client, :post, url, headers, bytes, 15_000, 4096)
  end

  defp upload(ctx) do
    body = Jason.encode!(%{"schema_version" => 1, "lease" => @lease, "init_base64" => Base.encode64(@init_bytes)})

    headers = [
      {"authorization", "Bearer " <> @recorder_token},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    HTTP.request(ctx.client, :post, ctx.url, headers, body, 10_000, 4096)
  end

  defp start_loopback_provider(handler) do
    tasks = start_supervised!(Task.Supervisor, id: make_ref(), restart: :temporary)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, _} = Task.Supervisor.start_child(tasks, fn -> accept_loopback(listener, tasks, handler) end)
    on_exit(fn -> :gen_tcp.close(listener) end)
    port
  end

  defp accept_loopback(listener, tasks, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, child} =
          Task.Supervisor.start_child(tasks, fn ->
            receive do
              {:socket, sock} -> serve_loopback(sock, handler)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, child)
        send(child, {:socket, socket})
        accept_loopback(listener, tasks, handler)

      _ ->
        :ok
    end
  end

  defp serve_loopback(socket, handler) do
    :ok = :inet.setopts(socket, packet: :http_bin)

    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, {:http_request, method, {:abs_path, target}, _version}} ->
        headers = recv_http_headers(socket, %{})
        :ok = :inet.setopts(socket, packet: :raw)
        length = headers |> Map.get("content-length", "0") |> String.to_integer()
        body = if length == 0, do: "", else: elem(:gen_tcp.recv(socket, length, 10_000), 1)
        method_str = to_string(method)
        request = %{method: method_str, target: target, headers: headers, body: body}

        case dispatch_loopback_response(socket, handler.(request), method_str) do
          :continue -> serve_loopback(socket, handler)
          :closed -> :gen_tcp.close(socket)
        end

      _ ->
        :gen_tcp.close(socket)
    end
  end

  defp recv_http_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        recv_http_headers(socket, Map.put(acc, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        acc
    end
  end

  defp dispatch_loopback_response(_socket, :close, _method), do: :closed

  defp dispatch_loopback_response(socket, {:hold, parent, response}, method) do
    send(parent, {:held_response, self()})

    receive do
      :release_response -> dispatch_loopback_response(socket, response, method)
    after
      5_000 -> :closed
    end
  end

  defp dispatch_loopback_response(socket, {status, headers, bytes}, method) do
    headers = Map.put_new(headers, "content-length", Integer.to_string(byte_size(bytes)))
    header_lines = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)
    wire_body = if method == "HEAD", do: "", else: bytes
    :ok = :gen_tcp.send(socket, ["HTTP/1.1 #{status} OK\r\n", header_lines, "\r\n", wire_body])
    :continue
  end

  defp core(state, request, desired) do
    input = Jason.decode!(request.body)
    kind = Enum.find([:init, :media, :manifest], &String.starts_with?(request.target, "/v1/#{&1}-"))

    state = %{
      state
      | core: [{request.target, input} | state.core],
        kind: kind,
        bytes: Map.fetch!(state.payloads, kind)
    }

    case String.replace(request.target, "/#{kind}-", "/init-") do
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
        prepared = %{"schema_version" => 1, "dispatch_id" => @dispatch}

        prepared =
          if state.kind in [:media, :manifest],
            do: Map.merge(prepared, %{"byte_length" => byte_size(state.bytes), "object_sha256" => digest(state.bytes)}),
            else: prepared

        {json(200, prepared), state}

      "/v1/init-uploads/grant" ->
        grant_response(state, input, Map.fetch!(desired, kind))

      "/v1/init-uploads/observe" ->
        {json(200, %{"schema_version" => 1, "status" => "recorded"}), state}

      "/v1/init-uploads/verify" ->
        {json(200, %{"schema_version" => 1, "status" => "recorded", "dispatch_id" => @dispatch}), state}
    end
  end

  defp grant_response(state, input, desired) do
    if MapSet.member?(state.marked, state.kind) do
      {json(409, %{"error" => "already_marked"}), state}
    else
      body =
        input
        |> Map.take(~w(schema_version dispatch_id storage_boot_id desired_sha256 nonce))
        |> Map.merge(%{
          "status" => "granted",
          "binding_id" => @binding,
          "revision" => "1",
          "remaining_ms" => if(state.kind == :init, do: 5_000, else: 30_000),
          "request_sha256" => String.duplicate("d", 64),
          "object_key" => object_key(state.kind),
          "byte_length" => byte_size(state.bytes),
          "object_sha256" => digest(state.bytes),
          "descriptor_sha256" => @descriptor,
          "local_storage_id" => desired.local_storage_id
        })

      {json(200, body), %{state | marked: MapSet.put(state.marked, state.kind)}}
    end
  end

  defp provider(state, request) do
    provider_response(%{state | provider: [request | state.provider]}, request)
  end

  defp provider_response(state, %{method: "PUT"} = request) do
    stored = if state.mode == :wrong_bytes, do: String.duplicate("x", byte_size(request.body)), else: request.body

    response =
      case state.mode do
        :conflict ->
          {412, %{"content-type" => "application/xml"}, "<Error><Code>PreconditionFailed</Code></Error>"}

        :lost_put ->
          :close

        :held_put ->
          {:hold, state.parent, {200, identity_headers(state), ""}}

        _ ->
          {200, identity_headers(state), ""}
      end

    {response, %{state | object: stored}}
  end

  defp provider_response(state, %{method: "HEAD"}) do
    headers = Map.put(identity_headers(state), "content-length", Integer.to_string(byte_size(state.object)))
    headers = if state.mode == :wrong_identity, do: Map.put(headers, "etag", ~s("different-etag")), else: headers

    headers =
      if state.mode == :wrong_encryption, do: Map.put(headers, "x-amz-server-side-encryption", "other"), else: headers

    {{200, headers, ""}, state}
  end

  defp provider_response(%{mode: :read_precondition_failed} = state, %{method: "GET"}) do
    xml = "<Error><Code>PreconditionFailed</Code><Message>xml-error-sentinel</Message></Error>"
    {{412, %{"content-type" => "application/xml"}, xml}, state}
  end

  defp provider_response(%{mode: :read_not_found} = state, %{method: "GET"}) do
    xml = "<Error><Code>NoSuchKey</Code></Error>"
    {{404, %{"content-type" => "application/xml"}, xml}, state}
  end

  defp provider_response(state, %{method: "GET", headers: request_headers}) do
    size = byte_size(state.object)
    [_, first, last] = Regex.run(~r/\Abytes=(\d+)-(\d+)\z/, request_headers["range"])
    first = String.to_integer(first)
    last = String.to_integer(last)
    headers = Map.put(identity_headers(state), "content-range", "bytes #{first}-#{last}/#{size}")
    status = if state.mode == :whole_object_fallback, do: 200, else: 206
    {{status, headers, binary_part(state.object, first, last - first + 1)}, state}
  end

  # Deliberately omits x-amz-checksum-sha256 on responses to match Linode S3 (Context 452).
  defp identity_headers(state) do
    base = %{
      "etag" => ~s("synthetic-etag"),
      "x-amz-server-side-encryption" => "AES256",
      "x-amz-request-id" => "req-synthetic-1"
    }

    if is_binary(state.version_header) do
      Map.put(base, "x-amz-version-id", state.version_header)
    else
      base
    end
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp payload(:init), do: @init_bytes
  defp payload(:media), do: :binary.copy("synthetic media bytes;", 220_000)
  defp payload(:manifest), do: ~s({"synthetic":"bounded manifest bytes"})
  defp object_key(:init), do: @key
  defp object_key(:media), do: String.replace(@key, "init.mp4", "media.m4s")
  defp object_key(:manifest), do: String.replace(@key, "init.mp4", "manifest.json")

  defp desired(:manifest) do
    :init
    |> desired()
    |> Map.put("operation", "manifest_put_verified_v1")
    |> Map.put("limits", %{"max_manifest_bytes" => 2_097_152, "max_operation_ms" => 30_000, "max_in_flight" => 1})
  end

  defp desired(:media) do
    :init
    |> desired()
    |> Map.put("operation", "media_put_verified_v1")
    |> Map.put("limits", %{"max_media_bytes" => 16_777_216, "max_operation_ms" => 30_000, "max_in_flight" => 1})
  end

  defp desired(:init) do
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
