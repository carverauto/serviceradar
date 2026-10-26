ExUnit.start()

defmodule ServiceRadarCoreElx.CameraStorageTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadarCoreElx.CameraStorage.Config
  alias ServiceRadarCoreElx.CameraStorage.HTTP
  alias ServiceRadarCoreElx.CameraStorage.Service
  alias ServiceRadarCoreElx.CameraStorage.Session
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
    kind = context[:kind] || :init
    kinds = context[:purposes] || [kind]
    payloads = Map.new(kinds, &{&1, payload(&1)})
    bytes = payloads[kind]

    {:ok, store} =
      Agent.start_link(fn ->
        %{
          parent: parent,
          mode: context[:mode],
          kind: kind,
          bytes: bytes,
          payloads: payloads,
          modes: context[:modes] || %{},
          default_mode: context[:mode],
          expired_role: context[:expired_role],
          provider: [],
          core: [],
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
      Fixture.start(certificates.server_config, fn request ->
        Agent.get_and_update(store, &provider(&1, request))
      end)

    core_port =
      Fixture.start(certificates.server_config, fn request ->
        response = Agent.get_and_update(store, &core(&1, request, desired))
        if String.ends_with?(request.target, "-authorities/challenge"), do: send(parent, :challenged)
        if String.ends_with?(request.target, "-uploads/prepare"), do: send(parent, :prepared)
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
      "desired" => desired[kind].document,
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
    # Synthetic provider trust and CONNECT routing exist only in this fixture.
    config = put_in(config.provider, Map.merge(config.provider, %{proxy: Fixture.proxy(provider_port), cacerts: roots}))

    service = start_supervised!(Supervisor.child_spec({Service, config}, restart: :temporary))
    for _ <- kinds, do: assert_receive(:challenged, 5_000)

    %{
      client: client,
      service: service,
      config: config,
      bytes: bytes,
      payloads: payloads,
      kind: kind,
      url: "https://localhost:#{port}/v1/#{kind}-uploads",
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

  @tag mode: :slow_observe
  test "exact verification spends the operation budget before evidence callbacks", ctx do
    assert {:ok, %{status: 200, body: body}} = upload(ctx)
    assert %{"status" => "init_verified", "recording_readiness" => "unavailable"} = Jason.decode!(body)
    state = Agent.get(ctx.store, & &1)
    assert ["PUT", "HEAD", "GET"] = Enum.map(Enum.reverse(state.provider), & &1.method)

    assert ["/v1/init-uploads/observe", "/v1/init-uploads/verify"] =
             state.core
             |> Enum.reverse()
             |> Enum.map(&elem(&1, 0))
             |> Enum.filter(&(&1 in ["/v1/init-uploads/observe", "/v1/init-uploads/verify"]))

    assert {:ok, %{status: 503}} = upload(ctx)
    assert Enum.count(Agent.get(ctx.store, & &1.provider), &(&1.method == "PUT")) == 1
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

  @tag operation_ms: 1_000
  test "time queued for admission cannot renew the installed operation budget", ctx do
    session = Process.whereis(Session)
    _ = :sys.get_state(session)
    assert :erlang.suspend_process(session)

    try do
      body = Jason.encode!(%{"schema_version" => 1, "lease" => @lease, "init_base64" => Base.encode64(@bytes)})
      socket = upload_socket(ctx, byte_size(body), body)
      assert eventually(fn -> elem(Process.info(session, :message_queue_len), 1) > 0 end)
      Process.sleep(1_200)
      assert :erlang.resume_process(session)
      assert {:ok, response} = :ssl.recv(socket, 0, 2_000)
      assert response =~ "503"
      state = Agent.get(ctx.store, & &1)
      assert state.provider == []
      refute Enum.any?(state.core, fn {path, _} -> path == "/v1/init-uploads/prepare" end)
    after
      if Process.info(session, :status) == {:status, :suspended}, do: :erlang.resume_process(session)
    end
  end

  test "mounted provider identity and separate purpose tokens are enforced", ctx do
    File.write!(ctx.credentials_path, Jason.encode!(Map.put(ctx.credential, "generation", 2)))
    assert {:error, :invalid_storage_configuration} = Config.load(ctx.config_path)
    File.write!(ctx.credentials_path, Jason.encode!(ctx.credential))
    File.write!(ctx.runtime_path, @recorder_token)
    assert {:error, :invalid_storage_configuration} = Config.load(ctx.config_path)
    assert Agent.get(ctx.store, & &1.provider) == []
  end

  @tag purposes: [:init, :media, :manifest]
  test "installed purposes reject unknown roles and disagreeing workload identities", ctx do
    document = ctx.config_path |> File.read!() |> Jason.decode!()

    invalid = [
      put_in(document, ["purposes"], %{}),
      update_in(document, ["purposes"], &Map.put(&1, "other", &1["init"])),
      put_in(document, ["purposes", "manifest", "operation"], "init_put_verified_v1"),
      put_in(document, ["purposes", "manifest", "local_storage_id"], "01577fa2-16ec-41cb-bd30-a396d6fb3c12"),
      put_in(document, ["purposes", "manifest", "qualification_report", "destination", "bucket"], "different-bucket"),
      put_in(document, ["purposes", "manifest", "qualification_report", "provider_resource_id"], "different-resource"),
      put_in(document, ["purposes", "manifest", "qualification_report", "endpoint_type"], "different-endpoint"),
      put_in(
        document,
        ["purposes", "manifest", "qualification_report", "credential", "storage_service_id"],
        "different-service"
      )
    ]

    for value <- invalid do
      File.write!(ctx.config_path, Jason.encode!(value))
      assert {:error, :invalid_storage_configuration} = Config.load(ctx.config_path)
    end

    assert Agent.get(ctx.store, & &1.provider) == []
  end

  @tag purposes: [:init, :media, :manifest]
  test "one installed workload verifies all three purpose-specific objects without widening a receipt", ctx do
    for kind <- [:init, :media, :manifest] do
      assert {:ok, %{status: 200, body: body}} = upload_role(ctx, kind)
      assert Jason.decode!(body)["status"] == "#{kind}_verified"
      assert Jason.decode!(body)["archive_readiness"] == "unavailable"
      assert {:ok, %{status: 503}} = upload_role(ctx, kind)
    end

    state = Agent.get(ctx.store, & &1)
    puts = state.provider |> Enum.reverse() |> Enum.filter(&(&1.method == "PUT"))
    assert Enum.map(puts, & &1.target) == Enum.map([:init, :media, :manifest], &("/synthetic-media/" <> object_key(&1)))
    assert Enum.map(puts, & &1.body) == Enum.map([:init, :media, :manifest], &Map.fetch!(ctx.payloads, &1))

    for {kind, put} <- Enum.zip([:init, :media, :manifest], puts) do
      assert put.headers["if-none-match"] == "*"
      assert put.headers["x-amz-server-side-encryption"] == "AES256"

      assert [{_, verification}] =
               for(
                 {path, %{"verification" => verification}} <- state.core,
                 path == "/v1/#{kind}-uploads/verify",
                 do: {path, verification}
               )

      assert verification["object_sha256"] == digest(Map.fetch!(ctx.payloads, kind))
      pairs = put.headers |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end)

      wire = [
        "#{kind}-put-wire-v1",
        "PUT",
        "https://objects.example.test" <> put.target,
        pairs,
        verification["object_sha256"]
      ]

      assert verification["put_request_sha256"] == digest(Jason.encode!(wire))
    end
  end

  for kind <- [:init, :manifest] do
    @tag purposes: [:init, :media, :manifest], partial_kind: kind
    test "a partial #{kind} body holds the one slot before another purpose reads any body", ctx do
      kind = ctx.partial_kind
      current = as_role(ctx, kind)
      length = if kind == :init, do: 1000, else: byte_size(current.bytes)
      _socket = upload_socket(current, length, "{")
      assert eventually(fn -> :sys.get_state(Session).stage != nil end)

      for other <- [:init, :media, :manifest] -- [kind] do
        other_ctx = as_role(ctx, other)
        length = if other == :init, do: 1000, else: byte_size(other_ctx.bytes)
        refused = upload_socket(other_ctx, length)
        assert {:ok, response} = :ssl.recv(refused, 0, 1_000)
        assert response =~ "503"
        assert response =~ "storage_busy"
        assert {:error, :closed} = :ssl.recv(refused, 0, 1_000)
      end

      stage = :sys.get_state(Session).stage
      monitor = Process.monitor(stage.owner)
      Process.exit(stage.owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2_000
      assert eventually(fn -> :sys.get_state(Session).stage == nil end)
      assert {:ok, %{status: 200}} = upload_role(ctx, :media)
      state = Agent.get(ctx.store, & &1)
      assert Enum.count(state.provider, &(&1.method == "PUT")) == 1
      refute Enum.any?(state.core, fn {path, _} -> path == "/v1/#{kind}-uploads/grant" end)
    end
  end

  @tag purposes: [:init, :media, :manifest], expired_role: :manifest
  test "an expired purpose challenge cannot borrow another purpose's window", ctx do
    Process.sleep(20)
    assert {:ok, %{status: 503}} = upload_role(ctx, :manifest)
    assert {:ok, %{status: 200}} = upload_role(ctx, :init)
    state = Agent.get(ctx.store, & &1)
    refute Enum.any?(state.core, fn {path, _} -> path == "/v1/manifest-uploads/prepare" end)
    assert Enum.count(state.provider, &(&1.method == "PUT")) == 1
  end

  @tag purposes: [:init, :media, :manifest], modes: %{manifest: :denied_grant}
  test "a denied purpose grant cannot consume an independent purpose's authority", ctx do
    assert {:ok, %{status: 503}} = upload_role(ctx, :manifest)
    assert {:ok, %{status: 200}} = upload_role(ctx, :init)
    state = Agent.get(ctx.store, & &1)
    assert [%{target: target}] = Enum.filter(state.provider, &(&1.method == "PUT"))
    assert target == "/synthetic-media/" <> @key
    refute Enum.any?(state.core, fn {path, _} -> path == "/v1/manifest-uploads/verify" end)
  end

  @tag purposes: [:init, :media, :manifest]
  test "normal shared restart cleans scratch and creates fresh independent purpose challenges", ctx do
    assert :ok = Supervisor.stop(ctx.service)
    refute File.exists?(Path.join(System.tmp_dir!(), "vms-media-staging"))
    start_supervised!(Supervisor.child_spec({Service, ctx.config}, id: :restarted_storage, restart: :temporary))
    for _ <- 1..3, do: assert_receive(:challenged, 5_000)
    challenges = for {path, value} <- Agent.get(ctx.store, & &1.core), String.ends_with?(path, "/challenge"), do: value
    assert length(challenges) == 6
    assert challenges |> Enum.map(& &1["nonce"]) |> Enum.uniq() |> length() == 6
    assert challenges |> Enum.map(& &1["storage_boot_id"]) |> Enum.frequencies() |> Map.values() |> Enum.sort() == [3, 3]

    assert challenges |> Enum.map(& &1["desired_sha256"]) |> Enum.frequencies() |> Map.values() |> Enum.sort() == [
             2,
             2,
             2
           ]

    assert {:ok, %{status: 200}} = upload_role(ctx, :manifest)
  end

  @tag kind: :manifest
  test "manifest staging rejects wrong bytes and its own size cap before consuming a grant", ctx do
    assert {:ok, %{status: 503, body: body}} = raw_upload(ctx, bytes: :binary.copy("x", byte_size(ctx.bytes)))
    assert Jason.decode!(body) == %{"error" => "manifest_upload_unavailable"}
    socket = upload_socket(ctx, 2_097_153)
    assert {:ok, response} = :ssl.recv(socket, 0, 1_000)
    assert response =~ "413"
    assert {:error, :closed} = :ssl.recv(socket, 0, 1_000)
    state = Agent.get(ctx.store, & &1)
    assert state.provider == []
    refute Enum.any?(state.core, fn {path, _} -> path == "/v1/manifest-uploads/grant" end)
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

      if state.mode == :conflict do
        assert Enum.any?(state.core, fn {path, value} ->
                 path == "/v1/init-uploads/observe" and value["outcome"] == "response" and
                   value["response"]["status"] == 412
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

  @tag kind: :media
  test "raw media stages before grant, streams one signed PUT and verifies separate exact ranges", ctx do
    assert {:ok, %{status: 200, body: body}} = raw_upload(ctx)
    assert %{"status" => "media_verified", "archive_readiness" => "unavailable"} = Jason.decode!(body)
    state = Agent.get(ctx.store, & &1)

    assert [%{method: "PUT"} = put, %{method: "HEAD"}, %{method: "GET"} = first, %{method: "GET"} = last] =
             Enum.reverse(state.provider)

    assert put.body == ctx.bytes
    assert put.headers["x-amz-content-sha256"] == digest(ctx.bytes)
    assert put.headers["content-length"] == Integer.to_string(byte_size(ctx.bytes))
    assert put.headers["if-none-match"] == "*"
    assert first.headers["range"] == "bytes=0-4194303"
    assert last.headers["range"] == "bytes=4194304-#{byte_size(ctx.bytes) - 1}"
    assert first.target == last.target
    assert [verification] = for({"/v1/media-uploads/verify", value} <- state.core, do: value["verification"])
    assert verification["object_sha256"] == digest(ctx.bytes)
    assert verification["byte_length"] == byte_size(ctx.bytes)
    assert verification["version_id"] == "version-1"
    pairs = put.headers |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end)

    assert verification["put_request_sha256"] ==
             digest(
               Jason.encode!([
                 "media-put-wire-v1",
                 "PUT",
                 "https://objects.example.test" <> put.target,
                 pairs,
                 digest(ctx.bytes)
               ])
             )

    assert {:ok, %{status: 503}} = raw_upload(ctx)
    assert Enum.count(Agent.get(ctx.store, & &1.provider), &(&1.method == "PUT")) == 1
  end

  @tag kind: :media
  test "wrong staged bytes and duplicate lease fields cannot consume a provider grant", ctx do
    assert {:ok, %{status: 503}} = raw_upload(ctx, bytes: :binary.copy("x", byte_size(ctx.bytes)))
    duplicate = @lease |> Jason.encode!() |> String.replace("{", ~s({"id":"duplicate",), global: false)
    assert {:ok, %{status: 400}} = raw_upload(ctx, lease: duplicate)

    assert {:ok, %{status: 400}} =
             raw_upload(ctx, extra_headers: [{"x-serviceradar-upload-lease", Jason.encode!(@lease)}])

    assert Agent.get(ctx.store, & &1.provider) == []
    refute Enum.any?(Agent.get(ctx.store, & &1.core), fn {path, _} -> path == "/v1/media-uploads/grant" end)
  end

  @tag kind: :media
  test "the ingress slot is reserved before body completion and a killed owner releases its scratch", ctx do
    _socket = upload_socket(ctx, byte_size(ctx.bytes), "x")

    assert_receive :prepared, 5_000
    assert {:ok, %{status: 503, body: body}} = raw_upload(ctx)
    assert Jason.decode!(body) == %{"error" => "storage_busy"}
    # Fault injection identifies the real request process; cleanup is asserted
    # through filesystem and subsequent HTTP behavior, not private state shape.
    stage = :sys.get_state(Session).stage
    monitor = Process.monitor(stage.owner)
    Process.exit(stage.owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2_000
    assert eventually(fn -> not File.exists?(stage.directory) end)
    refute File.exists?(stage.path)
    refute File.exists?(stage.directory)
    assert {:ok, %{status: 200}} = raw_upload(ctx)
  end

  @tag kind: :media, mode: :await_close
  test "canceling a live provider PUT closes its socket before another admission", ctx do
    request = Task.async(fn -> raw_upload(ctx) end)
    assert_receive {:provider_waiting, _}, 5_000
    stage = :sys.get_state(Session).stage
    Process.exit(stage.owner, :kill)
    assert_receive {:provider_closed, {:error, :closed}}, 1_000
    assert eventually(fn -> not File.exists?(stage.directory) end)
    assert {:error, _} = Task.await(request, 2_000)
    assert {:ok, %{status: 503}} = raw_upload(ctx)
    state = Agent.get(ctx.store, & &1)
    assert Enum.count(state.core, fn {path, _} -> path == "/v1/media-uploads/prepare" end) == 2
    assert Enum.count(state.provider, &(&1.method == "PUT")) == 1
  end

  @tag kind: :media, purposes: [:init, :media, :manifest]
  test "a real scratch unlink failure prevents reuse of the staging budget", ctx do
    _socket = upload_socket(ctx, byte_size(ctx.bytes), "x")

    assert_receive :prepared, 5_000
    stage = :sys.get_state(Session).stage
    assert eventually(fn -> File.exists?(stage.path) end)
    assert :ok = File.rm(stage.path)
    assert :ok = File.mkdir(stage.path)
    on_exit(fn -> File.rm_rf!(Path.dirname(stage.directory)) end)
    # Unlinking a directory fails even when the executor runs as root.
    assert {:error, reason} = File.rm(stage.path)
    assert reason in [:eperm, :eisdir]
    Process.exit(stage.owner, :kill)
    assert eventually(fn -> not Process.alive?(stage.owner) end)
    assert {:ok, %{status: 503, body: body}} = raw_upload(ctx)
    assert Jason.decode!(body) == %{"error" => "storage_scratch_reconciliation_required"}
    assert File.dir?(stage.path)
    assert Agent.get(ctx.store, & &1.provider) == []
    assert Enum.count(Agent.get(ctx.store, & &1.core), fn {path, _} -> path == "/v1/media-uploads/prepare" end) == 1

    for kind <- [:init, :manifest] do
      assert {:ok, %{status: 503, body: body}} = upload_role(ctx, kind)
      assert Jason.decode!(body) == %{"error" => "storage_scratch_reconciliation_required"}
    end

    assert Agent.get(ctx.store, & &1.provider) == []
  end

  @tag kind: :media, mode: :await_close, purposes: [:init, :media, :manifest]
  test "a killed Session stops supervised provider sockets and refuses its abandoned scratch root", ctx do
    request = Task.async(fn -> raw_upload(ctx) end)
    assert_receive {:provider_waiting, _}, 5_000
    stage = :sys.get_state(Session).stage
    scratch_root = Path.dirname(stage.directory)
    on_exit(fn -> File.rm_rf!(scratch_root) end)
    monitor = Process.monitor(ctx.service)
    Process.exit(Process.whereis(Session), :kill)
    assert_receive {:provider_closed, {:error, :closed}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    outcome = Task.await(request, 2_000)
    assert match?({:error, _}, outcome) or match?({:ok, %{status: 503}}, outcome)
    assert File.dir?(scratch_root)

    assert {:error, _} =
             start_supervised(
               Supervisor.child_spec({Service, ctx.config}, id: :abandoned_root_probe, restart: :temporary)
             )

    assert File.dir?(scratch_root)
    assert Enum.count(Agent.get(ctx.store, & &1.provider), &(&1.method == "PUT")) == 1
  end

  @tag kind: :media
  test "oversize ingress closes without draining an unadmitted body", ctx do
    socket = upload_socket(ctx, 16_777_217)

    assert {:ok, response} = :ssl.recv(socket, 0, 1_000)
    assert response =~ "413"
    assert {:error, :closed} = :ssl.recv(socket, 0, 1_000)
    assert Agent.get(ctx.store, & &1.provider) == []
    refute Enum.any?(Agent.get(ctx.store, & &1.core), fn {path, _} -> path == "/v1/media-uploads/prepare" end)
  end

  @tag kind: :media, operation_ms: 1_000
  test "the private listener refuses HTTP/2 negotiation and prior-knowledge framing", ctx do
    options = [:binary, active: false, verify: :verify_peer, cacerts: ctx.client.cacerts] ++ ctx.client.client_tls

    assert {:ok, negotiated} =
             :ssl.connect(~c"localhost", ctx.port, [alpn_advertised_protocols: ["h2", "http/1.1"]] ++ options, 2_000)

    on_exit(fn -> :ssl.close(negotiated) end)
    assert {:ok, "http/1.1"} = :ssl.negotiated_protocol(negotiated)
    assert {:ok, prior} = :ssl.connect(~c"localhost", ctx.port, options, 2_000)
    on_exit(fn -> :ssl.close(prior) end)
    assert :ok = :ssl.send(prior, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    assert {:error, :closed} = :ssl.recv(prior, 0, 1_000)
    assert Agent.get(ctx.store, & &1.provider) == []
    refute Enum.any?(Agent.get(ctx.store, & &1.core), fn {path, _} -> String.ends_with?(path, "/prepare") end)
  end

  @tag kind: :media, operation_ms: 1_000
  test "the ingress deadline stops a stalled file owner before its staging budget is released", ctx do
    socket = upload_socket(ctx, byte_size(ctx.bytes), "x")
    assert_receive :prepared, 5_000
    stage = :sys.get_state(Session).stage
    assert eventually(fn -> File.exists?(stage.path) end)
    monitor = Process.monitor(stage.owner)
    :erlang.suspend_process(stage.owner)
    on_exit(fn -> if Process.alive?(stage.owner), do: :erlang.resume_process(stage.owner) end)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2_000
    assert {:error, :closed} = :ssl.recv(socket, 0, 1_000)
    assert eventually(fn -> not File.exists?(stage.directory) end)
    assert Agent.get(ctx.store, & &1.provider) == []
    refute Enum.any?(Agent.get(ctx.store, & &1.core), fn {path, _} -> path == "/v1/media-uploads/grant" end)
  end

  @tag kind: :media, mode: :slow_grant, operation_ms: 1_000
  test "raw staging time remains inside the original provider deadline", ctx do
    socket = upload_socket(ctx, byte_size(ctx.bytes), binary_part(ctx.bytes, 0, 1))
    assert_receive :prepared, 5_000
    Process.sleep(600)
    assert :ok = :ssl.send(socket, binary_part(ctx.bytes, 1, byte_size(ctx.bytes) - 1))
    assert {:ok, response} = :ssl.recv(socket, 0, 2_000)
    assert response =~ "503"
    assert Agent.get(ctx.store, & &1.provider) == []
    assert Enum.any?(Agent.get(ctx.store, & &1.core), fn {path, _} -> path == "/v1/media-uploads/grant" end)
  end

  test "a denied CONNECT cannot fall back to a directly reachable provider for a streamed file", ctx do
    parent = self()

    port =
      Fixture.start(ctx.config.listener.tls, fn _ ->
        send(parent, :direct_provider_request)
        {200, %{}, ""}
      end)

    path = write_file(ctx.tmp_dir, "streamed-media", "synthetic bounded media")
    config = %{ctx.client | proxy: Fixture.proxy(port, deny: self())}

    assert {:error, _} =
             HTTP.request(
               config,
               :put,
               "https://localhost:#{port}/media",
               [{"content-length", "23"}],
               {:file, path, 23},
               2_000,
               64
             )

    assert_receive :connect_denied, 1_000
    refute_receive :direct_provider_request, 200
  end

  defp upload_socket(ctx, length, bytes \\ "") do
    options = [:binary, active: false, verify: :verify_peer, cacerts: ctx.client.cacerts] ++ ctx.client.client_tls
    assert {:ok, socket} = :ssl.connect(~c"localhost", ctx.port, options, 2_000)
    on_exit(fn -> :ssl.close(socket) end)

    content_type = if ctx.kind == :init, do: "application/json", else: "application/octet-stream"
    lease_header = if ctx.kind == :init, do: [], else: ["\r\nX-ServiceRadar-Upload-Lease: ", Jason.encode!(@lease)]

    assert :ok =
             :ssl.send(socket, [
               "POST /v1/#{ctx.kind}-uploads HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ",
               @recorder_token,
               "\r\nContent-Type: ",
               content_type,
               "\r\nContent-Length: ",
               Integer.to_string(length),
               lease_header,
               "\r\n\r\n",
               bytes
             ])

    socket
  end

  defp as_role(ctx, kind) do
    %{ctx | kind: kind, bytes: Map.fetch!(ctx.payloads, kind), url: "https://localhost:#{ctx.port}/v1/#{kind}-uploads"}
  end

  defp upload_role(ctx, :init), do: upload(as_role(ctx, :init))
  defp upload_role(ctx, kind), do: raw_upload(as_role(ctx, kind))

  defp eventually(fun, attempts \\ 100) do
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

  for mode <- [:wrong_bytes, :wrong_identity, :wrong_encryption, :whole_object_fallback, :conflict, :lost_put] do
    @tag kind: :media, mode: mode
    test "media #{mode} retains one attempt without verification or another PUT", ctx do
      assert {:ok, %{status: 503}} = raw_upload(ctx)
      assert {:ok, %{status: 503}} = raw_upload(ctx)
      state = Agent.get(ctx.store, & &1)
      assert Enum.count(state.provider, &(&1.method == "PUT")) == 1
      refute Enum.any?(state.core, fn {path, _} -> path == "/v1/media-uploads/verify" end)
    end
  end

  defp raw_upload(ctx, opts \\ []) do
    bytes = opts[:bytes] || ctx.bytes

    headers =
      [
        {"authorization", "Bearer " <> @recorder_token},
        {"content-type", "application/octet-stream"},
        {"content-length", Integer.to_string(byte_size(bytes))},
        {"x-serviceradar-upload-lease", opts[:lease] || Jason.encode!(@lease)}
      ] ++ (opts[:extra_headers] || [])

    HTTP.request(ctx.client, :post, ctx.url, headers, bytes, 10_000, 4096)
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

    kind =
      Enum.find([:init, :media, :manifest], &String.starts_with?(request.target, "/v1/#{&1}-"))

    state = %{
      state
      | core: [{request.target, input} | state.core],
        kind: kind,
        bytes: Map.fetch!(state.payloads, kind),
        mode: Map.get(state.modes, kind, state.default_mode)
    }

    case String.replace(request.target, "/#{kind}-", "/init-") do
      "/v1/init-authorities/challenge" ->
        body =
          Map.merge(input, %{
            "state" => "pending",
            "issued_at_ms" => "1800000000000",
            "expires_at_ms" => "1800000030000",
            "remaining_ms" => if(state.expired_role == kind, do: 1, else: 30_000),
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
        grant(state, input, Map.fetch!(desired, kind))

      "/v1/init-uploads/observe" ->
        response = json(200, %{"schema_version" => 1, "status" => "recorded"})
        response = if state.mode == :slow_observe, do: {:delay, 900, response}, else: response
        {response, state}

      "/v1/init-uploads/verify" ->
        {json(200, %{"schema_version" => 1, "status" => "recorded", "dispatch_id" => @dispatch}), state}
    end
  end

  defp grant(state, input, desired) do
    cond do
      MapSet.member?(state.marked, state.kind) -> {json(409, %{"error" => "already_marked"}), state}
      state.mode == :denied_grant -> {json(409, %{"error" => "authority_unavailable"}), state}
      true -> granted(state, input, desired)
    end
  end

  defp granted(state, input, desired) do
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

    response =
      case state.mode do
        :wrong_nonce -> json(200, Map.put(body, "nonce", String.duplicate("0", 64)))
        :late_grant -> {:delay, 100, json(200, Map.put(body, "remaining_ms", 10))}
        :slow_grant -> {:delay, 600, json(200, body)}
        :slow_observe -> json(200, Map.put(body, "remaining_ms", 700))
        _ -> json(200, body)
      end

    {response, %{state | marked: MapSet.put(state.marked, state.kind)}}
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
        :await_close -> {:await_close, state.parent}
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

  defp provider_response(state, %{method: "GET", headers: request_headers}) do
    size = byte_size(state.object)
    [_, first, last] = Regex.run(~r/\Abytes=(\d+)-(\d+)\z/, request_headers["range"])
    first = String.to_integer(first)
    last = String.to_integer(last)
    headers = Map.put(identity_headers(), "content-range", "bytes #{first}-#{last}/#{size}")
    status = if state.mode == :whole_object_fallback, do: 200, else: 206
    {{status, headers, binary_part(state.object, first, last - first + 1)}, state}
  end

  defp identity_headers,
    do: %{"etag" => ~s("synthetic-etag"), "x-amz-version-id" => "version-1", "x-amz-server-side-encryption" => "AES256"}

  defp payload(:init), do: @bytes
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
