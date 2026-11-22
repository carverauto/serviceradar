ExUnit.start()

defmodule ServiceRadarCoreElx.CameraStoragePerRequestReadTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Camera.ArchiveStorageConfig, as: Config
  alias ServiceRadar.Camera.ArchiveStorageHTTP, as: HTTP
  alias ServiceRadarCoreElx.CameraStorage.Read
  alias ServiceRadarCoreElx.CameraStorage.ReadLongshorePool
  alias ServiceRadarCoreElx.CameraStorage.ReadSession
  alias ServiceRadarCoreElx.CameraStorage.Service
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Fixture

  @moduletag :tmp_dir

  @storage_id "00000000-0000-4000-8000-000000000077"
  @block_key String.duplicate("ab", 32)
  @reader_token String.duplicate("t", 40)
  @access_key_id "SYNTHETICREADERKEY01"
  @secret_access_key "invented-per-request-reader-secret-material"
  @session_token "invented-per-request-session-token-material"

  setup ctx do
    {:ok, _} = Application.ensure_all_started(:ssl)
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost", dNSName: ~c"objects.example.test"]}

    certificates =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    parent = self()
    media_bytes = "0123456789abcdef-invented-archived-fragment-payload"
    init_bytes = "invented-archived-init-segment-bytes"

    {:ok, store} =
      Agent.start_link(fn ->
        %{
          parent: parent,
          mode: nil,
          objects: %{
            "/synthetic-bucket/recordings/v1/#{@storage_id}/#{@block_key}/init.mp4" => init_bytes,
            "/synthetic-bucket/recordings/v1/#{@storage_id}/#{@block_key}/media.m4s" => media_bytes
          },
          requests: []
        }
      end)

    provider_port =
      Fixture.start(certificates.server_config, fn request ->
        handle_provider(store, request)
      end)

    roots = Enum.uniq(certificates.server_config[:cacerts] ++ certificates.client_config[:cacerts])

    certfile =
      write_pem(ctx.tmp_dir, "server.crt", [{:Certificate, certificates.server_config[:cert], :not_encrypted}])

    {key_type, key_der} = certificates.server_config[:key]
    keyfile = write_pem(ctx.tmp_dir, "server.key", [{key_type, key_der, :not_encrypted}])
    cacertfile = write_pem(ctx.tmp_dir, "ca.crt", Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
    token_path = write_file(ctx.tmp_dir, "reader-token", @reader_token)
    port = free_port()

    listener_doc = %{
      "port" => port,
      "certfile" => certfile,
      "keyfile" => keyfile,
      "cacertfile" => cacertfile,
      "token_file" => token_path,
      "reader_certificate_sha256" => digest(certificates.client_config[:cert])
    }

    config_doc = %{
      "schema_version" => 1,
      "mode" => "per_request",
      "listener" => listener_doc
    }

    config_path = write_file(ctx.tmp_dir, "per-request-read.json", Jason.encode!(config_doc))
    expected_concurrency = ctx[:max_concurrency] || 2

    config =
      with_env(
        %{
          "SERVICERADAR_ARCHIVE_READER_MAX_CONCURRENCY" => Integer.to_string(expected_concurrency),
          "SERVICERADAR_ARCHIVE_READER_PROVIDER_TRANSPORT" => "http",
          "SERVICERADAR_ARCHIVE_READER_PORTABLE" => nil
        },
        fn ->
          assert {:ok, loaded} = Config.load_read_storage(config_path)
          loaded
        end
      )

    assert config.mode == :per_request
    assert config.max_concurrency == expected_concurrency

    config =
      put_in(config.provider, Map.merge(config.provider, %{proxy: Fixture.proxy(provider_port), cacerts: roots}))

    service =
      if ctx[:skip_service] do
        nil
      else
        start_supervised!(%{
          id: :per_request_reader_service,
          start: {Service, :start_read_link, [config]},
          restart: :temporary
        })
      end

    client = %{
      proxy: nil,
      cacerts: roots,
      client_tls: Keyword.take(certificates.client_config, [:cert, :key])
    }

    %{
      service: service,
      config: config,
      client: client,
      port: port,
      url: "https://localhost:#{port}/v1/timeline-archive-ranges",
      store: store,
      init_bytes: init_bytes,
      media_bytes: media_bytes
    }
  end

  test "serves verified init and media ranges via per-request credentials with cache-control: no-store", ctx do
    init_req = build_request("init.mp4", 0, byte_size(ctx.init_bytes) - 1, ctx.init_bytes)
    assert {:ok, %{status: 200, body: body, headers: headers}} = post_range(ctx, init_req)
    assert body == ctx.init_bytes
    assert header(headers, "cache-control") == "no-store"

    slice = binary_part(ctx.media_bytes, 10, 16)
    media_req = build_request("media.m4s", 10, 25, ctx.media_bytes, slice)
    assert {:ok, %{status: 200, body: ^slice, headers: media_headers}} = post_range(ctx, media_req)
    assert header(media_headers, "cache-control") == "no-store"

    requests = Agent.get(ctx.store, &Enum.reverse(&1.requests))
    assert length(requests) == 2
    assert Enum.all?(requests, &(&1.headers["x-amz-security-token"] == @session_token))
  end

  test "rejects invalid key families, oversized ranges, and malformed credentials with 400", ctx do
    valid = build_request("media.m4s", 0, 15, ctx.media_bytes, binary_part(ctx.media_bytes, 0, 16))

    bad_cases = [
      put_in(valid, ["plan", "object_key"], "recordings/v1/#{@storage_id}/#{@block_key}/descriptor.json"),
      put_in(valid, ["plan", "object_key"], "other/prefix/#{@storage_id}/#{@block_key}/media.m4s"),
      put_in(valid, ["plan", "object_key"], "recordings/v1/#{@storage_id}/#{@block_key}/../media.m4s"),
      put_in(valid, ["plan", "object_key"], "recordings/v1/#{@storage_id}/#{String.duplicate("cd", 32)}/media.m4s"),
      valid
      |> put_in(["plan", "size"], 1_048_577)
      |> put_in(["plan", "object_key"], "recordings/v1/#{@storage_id}/#{@block_key}/init.mp4")
      |> put_in(["plan", "last"], 1_048_576),
      valid |> put_in(["plan", "size"], 5_000_000) |> put_in(["plan", "last"], 4_194_304),
      put_in(valid, ["destination", "endpoint"], "http://objects.example.test"),
      put_in(valid, ["credential", "access_key_id"], "")
    ]

    for bad <- bad_cases do
      assert {:ok, %{status: 400, body: body, headers: headers}} = post_range(ctx, bad)
      assert Jason.decode!(body) == %{"error" => "invalid_archive_range"}
      assert header(headers, "cache-control") == "no-store"
      refute body =~ @access_key_id
      refute body =~ @secret_access_key
      refute body =~ @session_token
    end

    assert Agent.get(ctx.store, & &1.requests) == []
  end

  test "returns 404 on missing object and 409 on SHA-256 mismatch without leaking credentials", ctx do
    req = build_request("media.m4s", 0, 15, ctx.media_bytes, binary_part(ctx.media_bytes, 0, 16))

    Agent.update(ctx.store, &%{&1 | mode: :not_found})

    {res_404, log_404} = with_log(fn -> post_range(ctx, req) end)
    assert {:ok, %{status: 404, body: body_404}} = res_404
    assert Jason.decode!(body_404) == %{"error" => "archive_object_not_found"}
    refute_leaked_secrets(body_404 <> log_404)

    Agent.update(ctx.store, &%{&1 | mode: :corrupt})

    {res_409, log_409} = with_log(fn -> post_range(ctx, req) end)
    assert {:ok, %{status: 409, body: body_409}} = res_409
    assert Jason.decode!(body_409) == %{"error" => "archive_integrity_mismatch"}
    refute_leaked_secrets(body_409 <> log_409)
  end

  @tag max_concurrency: 2
  test "ReadSession enforces bounded max_slots and returns 503 archive_read_busy when full", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :held})
    req = build_request("media.m4s", 0, 15, ctx.media_bytes, binary_part(ctx.media_bytes, 0, 16))

    t1 = Task.async(fn -> post_range(ctx, req) end)
    t2 = Task.async(fn -> post_range(ctx, req) end)

    assert_receive {:held_provider, p1}, 3_000
    assert_receive {:held_provider, p2}, 3_000

    assert {:ok, %{status: 503, body: busy_body}} = post_range(ctx, req)
    assert Jason.decode!(busy_body) == %{"error" => "archive_read_busy"}

    send(p1, :release)

    [{finished, {:ok, {:ok, %{status: 200}}}}, {still_running, nil}] =
      [t1, t2]
      |> Task.yield_many(3_000)
      |> Enum.sort_by(fn {_task, res} -> if is_nil(res), do: 1, else: 0 end)

    assert finished in [t1, t2]

    # Once one slot frees up, a new request is admitted even while the second is still held.
    t3 = Task.async(fn -> post_range(ctx, req) end)
    assert_receive {:held_provider, p3}, 3_000
    send(p2, :release)
    send(p3, :release)
    assert {:ok, %{status: 200}} = Task.await(still_running, 3_000)
    assert {:ok, %{status: 200}} = Task.await(t3, 3_000)
  end

  @tag skip_service: true
  test "ReadLongshorePool enforces at most 1 active + 1 draining client and redacts state" do
    test_pid = self()

    starter = fn [config: ls_config] ->
      pid =
        spawn_link(fn ->
          Process.flag(:trap_exit, true)
          send(test_pid, {:fake_session_started, self(), ls_config})

          receive do
            {:EXIT, _from, :shutdown} ->
              send(test_pid, {:fake_session_stopping, self()})

              receive do
                :finish_drain -> :ok
              end
          end
        end)

      {:ok, pid}
    end

    pool = start_supervised!({ReadLongshorePool, name: :test_read_longshore_pool, session_starter: starter})
    ls_cfg = %{host: "objects.example.test", access_key: @access_key_id, secret_key: @secret_access_key}

    # Same key reuses active session.
    assert {:ok, s1, l1} = ReadLongshorePool.acquire(pool, {"dest1", "cred1"}, ls_cfg)
    assert_receive {:fake_session_started, ^s1, _}
    assert {:ok, ^s1, l2} = ReadLongshorePool.acquire(pool, {"dest1", "cred1"}, ls_cfg)
    refute_receive {:fake_session_started, _, _}

    # Rotating to a second key moves s1 to draining and starts s2 as active.
    assert {:ok, s2, l3} = ReadLongshorePool.acquire(pool, {"dest2", "cred2"}, ls_cfg)
    assert_receive {:fake_session_started, ^s2, _}
    refute s1 == s2

    # Alternating back to dest1 while s1 is still alive (not stopping) reuses s1 instead of returning busy.
    assert {:ok, ^s1, l2b} = ReadLongshorePool.acquire(pool, {"dest1", "cred1"}, ls_cfg)
    refute_receive {:fake_session_started, _, _}

    # A third distinct key while s1 is still draining is refused with :archive_read_busy (max 2 live clients!).
    assert {:error, :archive_read_busy} = ReadLongshorePool.acquire(pool, {"dest3", "cred3"}, ls_cfg)

    # Releasing s1's leases triggers shutdown of s1.
    ReadLongshorePool.release(pool, l1)
    ReadLongshorePool.release(pool, l2)
    refute_receive {:fake_session_stopping, ^s1}, 50
    ReadLongshorePool.release(pool, l2b)
    assert_receive {:fake_session_stopping, ^s1}, 1_000

    # Once s1 finishes draining and exits, a third key can rotate s2 to draining and start s3.
    send(s1, :finish_drain)
    mon = Process.monitor(s1)
    assert_receive {:DOWN, ^mon, :process, ^s1, _}, 1_000
    _ = :sys.get_state(pool)

    assert {:ok, s3, l4} = ReadLongshorePool.acquire(pool, {"dest3", "cred3"}, ls_cfg)
    assert_receive {:fake_session_started, ^s3, _}

    status_text = inspect(:sys.get_status(pool))
    assert status_text =~ ":redacted"
    refute_leaked_secrets(status_text)
    refute status_text =~ "dest3"

    ReadLongshorePool.release(pool, l3)
    assert_receive {:fake_session_stopping, ^s2}, 1_000
    send(s2, :finish_drain)
    ReadLongshorePool.release(pool, l4)
    send(s3, :finish_drain)
  end

  @tag skip_service: true
  test "Read.run_per_request executes Longshore pool path, verifies answers, maps 404/412/busy, and releases leases",
       ctx do
    test_pid = self()
    slice = binary_part(ctx.media_bytes, 10, 16)
    req = build_request("media.m4s", 10, 25, ctx.media_bytes, slice)
    {:ok, response_agent} = Agent.start_link(fn -> :ok end)

    starter = fn [config: ls_config] ->
      send(test_pid, {:ls_started, ls_config})

      pid =
        spawn_link(fn ->
          Process.flag(:trap_exit, true)
          fake_object_storage_session_loop(test_pid, response_agent, %{}, %{})
        end)

      {:ok, pid}
    end

    pool = start_supervised!({ReadLongshorePool, name: :test_ls_exec_pool, session_starter: starter})

    config = %{
      mode: :per_request,
      max_concurrency: 12,
      provider: %{
        transport: :longshore,
        portable: true,
        longshore_pool: pool
      }
    }

    deadline = System.monotonic_time(:millisecond) + 5_000

    # 206 verified range succeeds and clamps Longshore client concurrency to 4.
    valid_answer = %{
      status: 206,
      malformed: false,
      etag: ~s("synthetic-etag"),
      version: "v1",
      content_range: %{first: 10, last: 25, size: byte_size(ctx.media_bytes)},
      body: slice,
      body_len: byte_size(slice)
    }

    Agent.update(response_agent, fn _ -> {:ok, %{end: {:answered, valid_answer}}, {1, 2}} end)
    assert {:ok, ^slice} = Read.run_per_request(config, req, deadline)
    assert_receive {:ls_started, ls_cfg}, 1_000
    assert ls_cfg.concurrency == 4
    assert ls_cfg.portable == true
    assert map_size(:sys.get_state(pool).active.callers) == 0

    # 404 maps to :not_found and releases lease.
    Agent.update(response_agent, fn _ -> {:ok, %{end: {:answered, %{status: 404}}}, {1, 2}} end)
    assert {:error, :not_found} = Read.run_per_request(config, req, deadline)
    assert map_size(:sys.get_state(pool).active.callers) == 0

    # 412 maps to :integrity_mismatch and releases lease.
    Agent.update(response_agent, fn _ -> {:ok, %{end: {:answered, %{status: 412}}}, {1, 2}} end)
    assert {:error, :integrity_mismatch} = Read.run_per_request(config, req, deadline)
    assert map_size(:sys.get_state(pool).active.callers) == 0

    # Mismatched body/etag/version/content_range all map to :integrity_mismatch via verify_longshore_answer.
    for tampered <- [
          %{valid_answer | body: String.duplicate("Z", byte_size(slice))},
          %{valid_answer | etag: ~s("wrong-etag")},
          %{valid_answer | version: "v2"},
          %{valid_answer | content_range: %{first: 10, last: 24, size: byte_size(ctx.media_bytes)}}
        ] do
      Agent.update(response_agent, fn _ -> {:ok, %{end: {:answered, tampered}}, {1, 2}} end)
      assert {:error, :integrity_mismatch} = Read.run_per_request(config, req, deadline)
      assert map_size(:sys.get_state(pool).active.callers) == 0
    end

    # Longshore NIF :busy maps to :archive_read_busy and releases lease.
    Agent.update(response_agent, fn _ -> {:error, :busy} end)
    assert {:error, :archive_read_busy} = Read.run_per_request(config, req, deadline)
    assert map_size(:sys.get_state(pool).active.callers) == 0

    # Pool session_starter returning {:error, :busy} also maps to :archive_read_busy.
    busy_pool =
      start_supervised!(
        {ReadLongshorePool, name: :test_ls_busy_pool, session_starter: fn _ -> {:error, :busy} end},
        id: :test_ls_busy_pool
      )

    busy_config = put_in(config.provider.longshore_pool, busy_pool)
    assert {:error, :archive_read_busy} = Read.run_per_request(busy_config, req, deadline)
  end

  @tag skip_service: true
  test "ReadSession clamps per-request Longshore slots to 4 and holds drain until native completion on owner kill",
       ctx do
    test_pid = self()
    slice = binary_part(ctx.media_bytes, 10, 16)
    req = build_request("media.m4s", 10, 25, ctx.media_bytes, slice)
    {:ok, response_agent} = Agent.start_link(fn -> :hold end)

    starter = fn [config: _ls_config] ->
      pid =
        spawn_link(fn ->
          Process.flag(:trap_exit, true)
          fake_object_storage_session_loop(test_pid, response_agent, %{}, %{})
        end)

      {:ok, pid}
    end

    pool = start_supervised!({ReadLongshorePool, name: :test_ls_drain_pool, session_starter: starter})

    session =
      start_supervised!(
        {ReadSession,
         %{
           session_name: :test_ls_clamped_session,
           mode: :per_request,
           max_concurrency: 12,
           provider: %{transport: :longshore, longshore_pool: pool}
         }}
      )

    assert :sys.get_state(session).max_slots == 4

    deadline = System.monotonic_time(:millisecond) + 5_000

    # Reserve 4 slots: 5th must be rejected with :archive_read_busy despite max_concurrency: 12.
    holders =
      for i <- 1..4 do
        spawn(fn ->
          send(test_pid, {:reserved, i, ReadSession.reserve(deadline, session)})
          Process.sleep(:infinity)
        end)
      end

    for i <- 1..4, do: assert_receive({:reserved, ^i, {:ok, _}}, 1_000)
    assert {:error, :archive_read_busy} = ReadSession.reserve(deadline, session)

    Enum.each(holders, fn pid ->
      mon = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mon, :process, ^pid, _}, 1_000
    end)

    _ = :sys.get_state(session)

    # Single-slot session to observe hold_longshore_drain blocking admission while native I/O drains.
    drain_session =
      start_supervised!(
        {ReadSession,
         %{
           session_name: :test_ls_single_drain_session,
           mode: :per_request,
           max_concurrency: 1,
           provider: %{transport: :longshore, longshore_pool: pool}
         }},
        id: :test_ls_single_drain_session
      )

    worker =
      spawn(fn ->
        {:ok, admitted} = ReadSession.reserve(System.monotonic_time(:millisecond) + 5_000, drain_session)
        send(test_pid, {:admitted, admitted.provider.owner_token})
        Read.run_per_request(admitted, req, System.monotonic_time(:millisecond) + 5_000)
      end)

    assert_receive {:admitted, owner_token}, 1_000
    assert_receive {:held_longshore_get, ls_pid, ^owner_token}, 1_000

    # Kill the worker mid-flight (simulating deadline expiry).
    worker_mon = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 1_000
    _ = :sys.get_state(drain_session)
    _ = :sys.get_state(pool)

    # Both ReadSession and ReadLongshorePool must hold capacity until native drain completes.
    assert {:error, :archive_read_busy} =
             ReadSession.reserve(System.monotonic_time(:millisecond) + 5_000, drain_session)

    assert map_size(:sys.get_state(pool).active.callers) == 1

    # Complete the native in-flight request; both ReadSession and ReadLongshorePool release capacity.
    send(ls_pid, {:complete_inflight, owner_token, {:error, :closed}, test_pid})
    assert_receive :inflight_completed, 1_000
    _ = :sys.get_state(drain_session)
    _ = :sys.get_state(pool)

    assert map_size(:sys.get_state(pool).active.callers) == 0
    assert {:ok, _} = ReadSession.reserve(System.monotonic_time(:millisecond) + 5_000, drain_session)
  end

  @tag skip_service: true
  test "ReadSession.reserve enforces max_slots and per-slot deadline cleanup" do
    session =
      start_supervised!(
        {ReadSession,
         %{
           session_name: :test_bounded_read_session,
           mode: :per_request,
           max_concurrency: 2,
           provider: %{transport: :http}
         }}
      )

    deadline = System.monotonic_time(:millisecond) + 2_000
    parent = self()

    h1 =
      spawn(fn ->
        send(parent, {:r1, ReadSession.reserve(deadline, session)})
        Process.sleep(:infinity)
      end)

    h2 =
      spawn(fn ->
        send(parent, {:r2, ReadSession.reserve(deadline, session)})
        Process.sleep(:infinity)
      end)

    assert_receive {:r1, {:ok, _}}, 1_000
    assert_receive {:r2, {:ok, _}}, 1_000
    assert {:error, :archive_read_busy} = ReadSession.reserve(deadline, session)

    Process.exit(h1, :kill)
    mon1 = Process.monitor(h1)
    assert_receive {:DOWN, ^mon1, :process, ^h1, _}, 1_000
    _ = :sys.get_state(session)

    assert {:ok, _} = ReadSession.reserve(deadline, session)
    Process.exit(h2, :kill)
  end

  @tag skip_service: true
  test "Read.run_per_request rejects fixed-mode config and expired deadlines" do
    fixed = %{mode: :fixed, provider: %{transport: :http}}
    req = build_request("init.mp4", 0, 3, "abcd")

    assert {:error, :invalid_archive_range} =
             Read.run_per_request(fixed, req, System.monotonic_time(:millisecond) + 5_000)

    per_req = %{mode: :per_request, provider: %{transport: :http}}

    assert {:error, :archive_read_unavailable} =
             Read.run_per_request(per_req, req, System.monotonic_time(:millisecond) - 10)
  end

  defp post_range(ctx, payload) do
    body = Jason.encode!(payload)

    headers = [
      {"authorization", "Bearer " <> @reader_token},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    HTTP.request(ctx.client, :post, ctx.url, headers, body, 5_000, 1_048_576)
  end

  defp build_request(object_name, first, last, full_bytes, expected_slice \\ nil) do
    slice = expected_slice || binary_part(full_bytes, first, last - first + 1)

    destination = %{
      "schema_version" => 1,
      "provisioning_ref" => "operator:primary",
      "generation" => 1,
      "purpose" => "recording",
      "provider" => "s3_compatible",
      "endpoint" => "https://objects.example.test",
      "region" => "example-1",
      "bucket" => "synthetic-bucket",
      "namespace" => "recordings/v1",
      "archive_format_version" => 1,
      "required_encryption" => "sse_s3_aes256"
    }

    assert {:ok, _} = ArchiveDestination.attributes(destination)

    %{
      "schema_version" => 1,
      "destination" => destination,
      "credential" => %{
        "access_key_id" => @access_key_id,
        "secret_access_key" => @secret_access_key,
        "session_token" => @session_token
      },
      "plan" => %{
        "storage_id" => @storage_id,
        "block_key" => @block_key,
        "object_key" => "recordings/v1/#{@storage_id}/#{@block_key}/#{object_name}",
        "first" => first,
        "last" => last,
        "size" => byte_size(full_bytes),
        "etag" => ~s("synthetic-etag"),
        "version_id" => "v1",
        "sha256" => digest(slice)
      }
    }
  end

  defp handle_provider(store, request) do
    {mode, parent, objects} =
      Agent.get_and_update(store, fn state ->
        {{state.mode, state.parent, state.objects}, %{state | requests: [request | state.requests]}}
      end)

    if mode == :held do
      send(parent, {:held_provider, self()})

      receive do
        :release -> :ok
      end
    end

    path = request.target |> String.split("?") |> hd()

    case {mode, Map.get(objects, path)} do
      {:not_found, _} ->
        {404, %{"content-type" => "application/xml"}, "<Error><Code>NoSuchKey</Code></Error>"}

      {_, nil} ->
        {404, %{"content-type" => "application/xml"}, "<Error><Code>NoSuchKey</Code></Error>"}

      {:corrupt, bytes} ->
        {first, last} = parse_range(request.headers["range"])
        len = last - first + 1
        corrupted = String.duplicate("X", len)

        {206,
         %{
           "etag" => ~s("synthetic-etag"),
           "x-amz-version-id" => "v1",
           "content-range" => "bytes #{first}-#{last}/#{byte_size(bytes)}"
         }, corrupted}

      {_, bytes} ->
        {first, last} = parse_range(request.headers["range"])
        slice = binary_part(bytes, first, last - first + 1)

        {206,
         %{
           "etag" => ~s("synthetic-etag"),
           "x-amz-version-id" => "v1",
           "content-range" => "bytes #{first}-#{last}/#{byte_size(bytes)}"
         }, slice}
    end
  end

  defp parse_range("bytes=" <> spec) do
    [first, last] = String.split(spec, "-")
    {String.to_integer(first), String.to_integer(last)}
  end

  defp refute_leaked_secrets(text) do
    refute text =~ @access_key_id
    refute text =~ @secret_access_key
    refute text =~ @session_token
    refute text =~ @reader_token
  end

  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp write_pem(dir, name, entries), do: write_file(dir, name, :public_key.pem_encode(entries))

  defp fake_object_storage_session_loop(test_pid, response_agent, in_flight, waiters) do
    receive do
      {:"$gen_call", from, {:submit, {:get, _key, _range, _expect}, _budget, owner_token}} ->
        case Agent.get(response_agent, & &1) do
          :hold ->
            send(test_pid, {:held_longshore_get, self(), owner_token})
            in_flight = Map.put(in_flight, owner_token, from)
            fake_object_storage_session_loop(test_pid, response_agent, in_flight, waiters)

          reply ->
            GenServer.reply(from, reply)
            fake_object_storage_session_loop(test_pid, response_agent, in_flight, waiters)
        end

      {:await_token_drain, token, reply_to} ->
        if Map.has_key?(in_flight, token) do
          waiters = Map.update(waiters, token, [reply_to], &[reply_to | &1])
          fake_object_storage_session_loop(test_pid, response_agent, in_flight, waiters)
        else
          send(reply_to, {:token_drained, token})
          fake_object_storage_session_loop(test_pid, response_agent, in_flight, waiters)
        end

      {:complete_inflight, token, reply, ack_to} ->
        {from, in_flight} = Map.pop(in_flight, token)
        if from, do: GenServer.reply(from, reply)
        {recipients, waiters} = Map.pop(waiters, token, [])
        Enum.each(recipients, &send(&1, {:token_drained, token}))
        send(ack_to, :inflight_completed)
        fake_object_storage_session_loop(test_pid, response_agent, in_flight, waiters)

      {:EXIT, _from, :shutdown} ->
        :ok
    end
  end

  defp with_env(vars, fun) when is_map(vars) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(vars, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
