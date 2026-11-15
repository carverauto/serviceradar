ExUnit.start()

defmodule ServiceRadarCoreElx.CameraStorageBenchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import Bitwise

  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveStorageConfig, as: Config
  alias ServiceRadar.Camera.ArchiveStorageHTTP, as: HTTP
  alias ServiceRadarCoreElx.CameraStorage.Service
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Fixture

  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @binding "f23d5f63-1457-4f3d-ae05-80ba21d88f50"
  @storage "f68af8e1-6ecb-4856-a5ad-351a927cd038"
  @descriptor String.duplicate("b", 64)
  @recorder_token String.duplicate("r", 40)
  @runtime_token String.duplicate("s", 40)
  @reader_token String.duplicate("p", 40)
  @lease %{
    "id" => "c640db9f-09aa-45f0-8493-a8f464fc4ec2",
    "upload_token" => "00000000-0000-4000-8000-000000000002",
    "upload_epoch" => "1",
    "descriptor_sha256" => @descriptor
  }

  test "measures end-to-end CameraStorage archive authority upload, readback verification, and concurrent playback",
       %{tmp_dir: tmp_dir} do
    {:ok, _} = Application.ensure_all_started(:ssl)
    reps = env_int("LONGSHORE_PIPELINE_REPS", 5)

    payloads = %{
      init: deterministic_bytes(4_096),
      media: deterministic_bytes(4_194_304),
      manifest: ~s({"schema_version":1,"fragments":1,"duration_ms":4000,"synthetic":true})
    }

    longshore_samples = Enum.map(1..reps, &run_pipeline_iteration(:longshore, tmp_dir, payloads, &1))
    http_samples = Enum.map(1..reps, &run_pipeline_iteration(:http, tmp_dir, payloads, &1))

    longshore_summary = summarize_pipeline(:longshore, longshore_samples)
    http_summary = summarize_pipeline(:http, http_samples)

    IO.puts("CAMERA_PIPELINE_SUMMARY_JSON=" <> Jason.encode!(longshore_summary))
    IO.puts("CAMERA_PIPELINE_SUMMARY_JSON=" <> Jason.encode!(http_summary))

    assert longshore_summary.median_media_useful_mb_s > 0.0
    assert http_summary.median_media_useful_mb_s > 0.0
    assert longshore_summary.verified_blocks == reps
    assert http_summary.verified_blocks == reps
  end

  defp run_pipeline_iteration(transport, base_tmp_dir, payloads, rep) do
    iter_dir = Path.join(base_tmp_dir, "#{transport}-#{rep}")
    File.mkdir_p!(iter_dir)
    env = start_pipeline_fixture!(transport, iter_dir, payloads, rep)

    try do
      :erlang.garbage_collect()
      cpu_before = process_cpu_seconds()
      bin_before = :erlang.memory(:binary)

      init_ms = timed_ms(fn -> assert_verified_upload!(env, :init, payloads.init) end)
      media_ms = timed_ms(fn -> assert_verified_upload!(env, :media, payloads.media) end)
      manifest_ms = timed_ms(fn -> assert_verified_upload!(env, :manifest, payloads.manifest) end)

      playback_plan = build_playback_plan(env, payloads.media, 0, 1_048_575)

      playback_task =
        Task.async(fn ->
          timed_ms(fn ->
            assert {:ok, %{status: 200, body: body}} = post_playback(env.reader, playback_plan)
            assert byte_size(body) == 1_048_576
          end)
        end)

      concurrent_media_ms =
        timed_ms(fn -> assert_verified_upload!(env, :media, payloads.media) end)

      playback_1mib_ms = Task.await(playback_task, 30_000)

      cpu_s = max(process_cpu_seconds() - cpu_before, 0.0)
      bin_peak = :erlang.memory(:binary)
      state = Agent.get(env.store, & &1)

      useful_bytes =
        byte_size(payloads.init) + 2 * byte_size(payloads.media) + byte_size(payloads.manifest)

      provider_wire_bytes = state.provider_put_bytes + state.provider_get_bytes
      gib = useful_bytes / (1024.0 * 1024.0 * 1024.0)

      sample = %{
        transport: Atom.to_string(transport),
        rep: rep,
        init_4kib_ms: Float.round(init_ms, 3),
        media_4mib_ms: Float.round(media_ms, 3),
        concurrent_media_4mib_ms: Float.round(concurrent_media_ms, 3),
        manifest_ms: Float.round(manifest_ms, 3),
        concurrent_playback_1mib_ms: Float.round(playback_1mib_ms, 3),
        media_useful_mb_s:
          Float.round(byte_size(payloads.media) / (media_ms / 1_000.0) / 1_000_000.0, 3),
        provider_requests: state.provider_requests,
        byte_amplification: Float.round(provider_wire_bytes / max(useful_bytes, 1), 3),
        verified_commits: state.verified_commits,
        cpu_seconds: Float.round(cpu_s, 6),
        cpu_s_per_useful_gib: Float.round(cpu_s / gib, 6),
        bin_mem_before_bytes: bin_before,
        bin_mem_peak_bytes: bin_peak
      }

      IO.puts("CAMERA_PIPELINE_RUN_JSON=" <> Jason.encode!(sample))
      sample
    after
      stop_pipeline_fixture(env)
    end
  end

  defp summarize_pipeline(transport, samples) do
    media_rates = Enum.map(samples, & &1.media_useful_mb_s)
    media_lat = Enum.map(samples, & &1.media_4mib_ms)
    conc_media_lat = Enum.map(samples, & &1.concurrent_media_4mib_ms)
    init_lat = Enum.map(samples, & &1.init_4kib_ms)
    manifest_lat = Enum.map(samples, & &1.manifest_ms)
    play_lat = Enum.map(samples, & &1.concurrent_playback_1mib_ms)
    cpu_gib = Enum.map(samples, & &1.cpu_s_per_useful_gib)

    %{
      transport: Atom.to_string(transport),
      runs: length(samples),
      verified_blocks: Enum.count(samples, &(&1.verified_commits == 4)),
      median_media_useful_mb_s: Float.round(median(media_rates), 3),
      min_media_useful_mb_s: Float.round(Enum.min(media_rates), 3),
      max_media_useful_mb_s: Float.round(Enum.max(media_rates), 3),
      median_init_4kib_ms: Float.round(median(init_lat), 3),
      median_media_4mib_ms: Float.round(median(media_lat), 3),
      median_concurrent_media_4mib_ms: Float.round(median(conc_media_lat), 3),
      median_manifest_ms: Float.round(median(manifest_lat), 3),
      median_concurrent_playback_1mib_ms: Float.round(median(play_lat), 3),
      median_cpu_s_per_useful_gib: Float.round(median(cpu_gib), 6),
      byte_amplification: List.first(samples).byte_amplification,
      provider_requests_per_4_ops_plus_playback: List.first(samples).provider_requests,
      peak_bin_mem_bytes: Enum.max(Enum.map(samples, & &1.bin_mem_peak_bytes))
    }
  end

  defp start_pipeline_fixture!(transport, dir, payloads, rep) do
    File.rm_rf!(Path.join(System.tmp_dir!(), "vms-media-staging"))
    certs = generate_certs()
    roots = Enum.uniq(certs.server_config[:cacerts] ++ certs.client_config[:cacerts])
    parent = self()

    {:ok, store} =
      Agent.start_link(fn ->
        %{
          seq: 0,
          rep: rep,
          last_media_key: nil,
          objects: %{},
          provider_requests: 0,
          provider_put_bytes: 0,
          provider_get_bytes: 0,
          verified_commits: 0
        }
      end)

    installation = %{deployment_ref: "aee2d1d4-1162-4029-a3d2-bc4d73636634", generation: 1}
    purposes = [:init, :media, :manifest]

    desired =
      Map.new(purposes, fn kind ->
        {:ok, parsed} = ArchiveAuthorityConfig.parse(kind, installation, desired_doc(kind))
        {kind, parsed}
      end)

    {provider_port, provider_server} = start_provider!(transport, certs.server_config, store)

    core_port =
      Fixture.start(certs.server_config, fn request ->
        resp = Agent.get_and_update(store, &handle_core(&1, request, desired, payloads))
        if String.ends_with?(request.target, "-authorities/challenge"), do: send(parent, :challenged)
        resp
      end)

    tls_files = write_tls_files(dir, certs, roots)
    writer_port = free_port()
    reader_port = free_port()

    cred_path =
      write_file(
        dir,
        "cred.json",
        Jason.encode!(%{
          "reference" => "synthetic-custody",
          "generation" => 1,
          "access_key_id" => "synthetic-writer",
          "secret_access_key" => "invented-key-material"
        })
      )

    rec_tok_path = write_file(dir, "rec.tok", @recorder_token)
    run_tok_path = write_file(dir, "run.tok", @runtime_token)
    read_tok_path = write_file(dir, "read.tok", @reader_token)
    pin = sha256_hex(certs.client_config[:cert])

    writer_doc = %{
      "schema_version" => 2,
      "deployment_ref" => installation.deployment_ref,
      "generation" => "1",
      "provider_transport" => Atom.to_string(transport),
      "purposes" => Map.new(desired, fn {k, v} -> {Atom.to_string(k), v.document} end),
      "provider_credentials_file" => cred_path,
      "listener" =>
        Map.merge(tls_files, %{
          "port" => writer_port,
          "token_file" => rec_tok_path,
          "recorder_certificate_sha256" => pin
        }),
      "runtime" =>
        Map.merge(tls_files, %{
          "base_url" => "https://localhost:#{core_port}",
          "token_file" => run_tok_path
        })
    }

    {:ok, writer_cfg} = Config.load(write_file(dir, "writer.json", Jason.encode!(writer_doc)))
    writer_cfg = attach_provider_route(transport, writer_cfg, provider_port, roots)
    {:ok, writer_pid} = Service.start_link(writer_cfg)
    for _ <- purposes, do: assert_receive(:challenged, 5_000)

    reader_doc = %{
      "schema_version" => 1,
      "binding_id" => @binding,
      "provider_transport" => Atom.to_string(transport),
      "destination" => writer_cfg.provider.destination,
      "provider_credentials_file" => cred_path,
      "listener" =>
        Map.merge(tls_files, %{
          "port" => reader_port,
          "token_file" => read_tok_path,
          "reader_certificate_sha256" => pin
        })
    }

    {:ok, reader_cfg} =
      Config.load_read_storage(write_file(dir, "reader.json", Jason.encode!(reader_doc)))

    reader_cfg = attach_provider_route(transport, reader_cfg, provider_port, roots)
    {:ok, reader_pid} = Service.start_read_link(reader_cfg)

    reader_client_doc = %{
      "schema_version" => 1,
      "binding_id" => @binding,
      "destination_sha256" => reader_cfg.destination_sha256,
      "storage" =>
        Map.merge(write_client_tls_files(dir, certs, roots), %{
          "base_url" => "https://localhost:#{reader_port}",
          "token_file" => read_tok_path
        })
    }

    {:ok, reader_installed} =
      Config.load_reader(write_file(dir, "reader-client.json", Jason.encode!(reader_client_doc)))

    %{
      writer_pid: writer_pid,
      reader_pid: reader_pid,
      provider_server: provider_server,
      store: store,
      port: writer_port,
      destination_sha256: reader_cfg.destination_sha256,
      reader: reader_installed,
      client: %{
        proxy: nil,
        cacerts: roots,
        client_tls: Keyword.take(certs.client_config, [:cert, :key])
      }
    }
  end

  defp attach_provider_route(:longshore, cfg, port, _roots) do
    %{cfg | provider: Map.put(cfg.provider, :longshore_loopback_peer, {"127.0.0.1", port})}
  end

  defp attach_provider_route(:http, cfg, port, roots) do
    %{cfg | provider: %{cfg.provider | proxy: %{scheme: :http, host: "127.0.0.1", port: port}, cacerts: roots}}
  end

  defp stop_pipeline_fixture(env) do
    if Process.alive?(env.reader_pid), do: Supervisor.stop(env.reader_pid, :normal, 15_000)
    if Process.alive?(env.writer_pid), do: Supervisor.stop(env.writer_pid, :normal, 15_000)

    case env.provider_server do
      {pid, listen} ->
        :gen_tcp.close(listen)
        if Process.alive?(pid), do: Process.exit(pid, :kill)

      _ ->
        :ok
    end

    if Process.alive?(env.store), do: Agent.stop(env.store)
    File.rm_rf!(Path.join(System.tmp_dir!(), "vms-media-staging"))
  end

  defp start_provider!(:http, server_tls, store) do
    tls_port = Fixture.start(server_tls, fn req -> Agent.get_and_update(store, &handle_provider(&1, req)) end)
    proxy = Fixture.proxy(tls_port)
    {proxy.port, nil}
  end

  defp start_provider!(:longshore, _server_tls, store) do
    opts = [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}, nodelay: true]
    {:ok, listen} = :gen_tcp.listen(0, opts)
    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> accept_loop(listen, store) end)
    {port, {pid, listen}}
  end

  defp accept_loop(listen, store) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        :ok = :inet.setopts(sock, nodelay: true)
        spawn(fn -> serve_tcp(sock, store) end)
        accept_loop(listen, store)

      _ ->
        :ok
    end
  end

  defp serve_tcp(sock, store) do
    case read_http_req(sock) do
      {:ok, req} ->
        resp = Agent.get_and_update(store, &handle_provider(&1, req))
        send_http_resp(sock, req.method, resp)
        serve_tcp(sock, store)

      :closed ->
        :gen_tcp.close(sock)
    end
  end

  defp read_http_req(sock) do
    with :ok <- :inet.setopts(sock, packet: :http_bin),
         {:ok, {:http_request, method, {:abs_path, target}, _}} <- :gen_tcp.recv(sock, 0, 10_000),
         {:ok, headers} <- recv_headers(sock, %{}),
         :ok <- :inet.setopts(sock, packet: :raw),
         len = headers |> Map.get("content-length", "0") |> String.to_integer(),
         {:ok, body} <- if(len == 0, do: {:ok, ""}, else: :gen_tcp.recv(sock, len, 10_000)) do
      {:ok, %{method: to_string(method), target: target, headers: headers, body: body}}
    else
      _ -> :closed
    end
  end

  defp recv_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, {:http_header, _, k, _, v}} ->
        recv_headers(sock, Map.put(acc, k |> to_string() |> String.downcase(), v))

      _ ->
        :error
    end
  end

  defp send_http_resp(sock, method, {status, headers, body}) do
    wire_body = if method == "HEAD", do: "", else: body
    hdrs = Map.put(headers, "content-length", Integer.to_string(byte_size(body)))
    lines = Enum.map(hdrs, fn {k, v} -> [k, ": ", v, "\r\n"] end)
    :gen_tcp.send(sock, ["HTTP/1.1 #{status} OK\r\n", lines, "\r\n", wire_body])
  end

  defp handle_provider(state, req) do
    path = req.target |> String.split("?") |> hd() |> normalize_provider_path()
    state = %{state | provider_requests: state.provider_requests + 1}

    case req.method do
      "PUT" ->
        objects = Map.put(state.objects, path, req.body)
        put_bytes = state.provider_put_bytes + byte_size(req.body)
        headers = provider_identity_headers()
        {{200, headers, ""}, %{state | objects: objects, provider_put_bytes: put_bytes}}

      "HEAD" ->
        bytes = Map.fetch!(state.objects, path)
        {{200, provider_identity_headers(), bytes}, state}

      "GET" ->
        bytes = Map.fetch!(state.objects, path)
        [_, s_first, s_last] = Regex.run(~r/\Abytes=(\d+)-(\d+)\z/, req.headers["range"])
        {first, last} = {String.to_integer(s_first), String.to_integer(s_last)}
        slice = binary_part(bytes, first, last - first + 1)
        get_bytes = state.provider_get_bytes + byte_size(slice)
        content_range = "bytes #{first}-#{last}/#{byte_size(bytes)}"
        headers = Map.put(provider_identity_headers(), "content-range", content_range)
        {{206, headers, slice}, %{state | provider_get_bytes: get_bytes}}
    end
  end

  defp normalize_provider_path(path) do
    String.replace_prefix(path, "https://objects.example.test", "")
  end

  defp provider_identity_headers do
    %{
      "etag" => ~s("bench-etag"),
      "x-amz-version-id" => "version-1",
      "x-amz-server-side-encryption" => "AES256",
      "x-amz-request-id" => "req-bench-1"
    }
  end

  defp handle_core(state, req, desired_map, payloads) do
    input = Jason.decode!(req.body)
    kind = purpose_of(req.target)
    bytes = Map.fetch!(payloads, kind)

    case String.replace(req.target, "/#{kind}-", "/init-") do
      "/v1/init-authorities/challenge" ->
        reply =
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

        {json_resp(200, reply), state}

      "/v1/init-uploads/prepare" ->
        seq = state.seq + 1
        dispatch_id = dispatch_uuid(seq)
        prepared = prepare_body(kind, dispatch_id, bytes)
        {json_resp(200, prepared), %{state | seq: seq}}

      "/v1/init-uploads/grant" ->
        seq = state.seq + 1
        key = object_key_for(kind, state.rep, seq)
        grant = grant_body(kind, input, desired_map[kind], bytes, key)
        next = if kind == :media, do: %{state | seq: seq, last_media_key: key}, else: %{state | seq: seq}
        {json_resp(200, grant), next}

      "/v1/init-uploads/observe" ->
        {json_resp(200, %{"schema_version" => 1, "status" => "recorded"}), state}

      "/v1/init-uploads/verify" ->
        reply = %{"schema_version" => 1, "status" => "recorded", "dispatch_id" => input["dispatch_id"]}
        {json_resp(200, reply), %{state | verified_commits: state.verified_commits + 1}}
    end
  end

  defp prepare_body(:init, dispatch_id, _bytes),
    do: %{"schema_version" => 1, "dispatch_id" => dispatch_id}

  defp prepare_body(_kind, dispatch_id, bytes) do
    %{
      "schema_version" => 1,
      "dispatch_id" => dispatch_id,
      "byte_length" => byte_size(bytes),
      "object_sha256" => sha256_hex(bytes)
    }
  end

  defp grant_body(kind, input, desired, bytes, key) do
    input
    |> Map.take(~w(schema_version dispatch_id storage_boot_id desired_sha256 nonce))
    |> Map.merge(%{
      "status" => "granted",
      "binding_id" => @binding,
      "revision" => "1",
      "remaining_ms" => if(kind == :init, do: 5_000, else: 30_000),
      "request_sha256" => String.duplicate("d", 64),
      "object_key" => key,
      "byte_length" => byte_size(bytes),
      "object_sha256" => sha256_hex(bytes),
      "descriptor_sha256" => @descriptor,
      "local_storage_id" => desired.local_storage_id
    })
  end

  defp dispatch_uuid(seq) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(seq), 12, "0")
  end

  defp json_resp(status, map) do
    {status, %{"content-type" => "application/json"}, Jason.encode!(map)}
  end

  defp assert_verified_upload!(env, kind, bytes, retries \\ 25) do
    case perform_upload(env, kind, bytes) do
      {:ok, %{status: 200, body: body}} ->
        assert Jason.decode!(body)["status"] == "#{kind}_verified"

      {:ok, %{status: 503}} when retries > 0 ->
        Process.sleep(4)
        assert_verified_upload!(env, kind, bytes, retries - 1)

      other ->
        flunk("unexpected #{kind} upload response: #{inspect(other)}")
    end
  end

  defp perform_upload(env, :init, bytes) do
    body = Jason.encode!(%{"schema_version" => 1, "lease" => @lease, "init_base64" => Base.encode64(bytes)})

    headers = [
      {"authorization", "Bearer " <> @recorder_token},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    HTTP.request(env.client, :post, "https://localhost:#{env.port}/v1/init-uploads", headers, body, 15_000, 4096)
  end

  defp perform_upload(env, kind, bytes) when kind in [:media, :manifest] do
    headers = [
      {"authorization", "Bearer " <> @recorder_token},
      {"content-type", "application/octet-stream"},
      {"content-length", Integer.to_string(byte_size(bytes))},
      {"x-serviceradar-upload-lease", Jason.encode!(@lease)}
    ]

    HTTP.request(env.client, :post, "https://localhost:#{env.port}/v1/#{kind}-uploads", headers, bytes, 30_000, 4096)
  end

  defp post_playback(installed, plan) do
    body = Jason.encode!(plan)

    headers = [
      {"authorization", "Bearer " <> installed.client.token},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    HTTP.request(installed.client, :post, installed.client.base_url <> "/v1/archive-ranges", headers, body, 15_000, 2_097_152)
  end

  defp build_playback_plan(env, media_bytes, first, last) do
    state = Agent.get(env.store, & &1)
    slice = binary_part(media_bytes, first, last - first + 1)

    %{
      "schema_version" => 1,
      "binding_id" => @binding,
      "destination_sha256" => env.destination_sha256,
      "descriptor_sha256" => @descriptor,
      "manifest_verification_sha256" => String.duplicate("c", 64),
      "block_id" => @storage,
      "object_key" => state.last_media_key,
      "first" => first,
      "last" => last,
      "size" => byte_size(media_bytes),
      "etag" => ~s("bench-etag"),
      "version_id" => "version-1",
      "sha256" => sha256_hex(slice)
    }
  end

  defp desired_doc(:manifest) do
    :init
    |> desired_doc()
    |> Map.put("operation", "manifest_put_verified_v1")
    |> Map.put("limits", %{"max_manifest_bytes" => 2_097_152, "max_operation_ms" => 30_000, "max_in_flight" => 1})
  end

  defp desired_doc(:media) do
    :init
    |> desired_doc()
    |> Map.put("operation", "media_put_verified_v1")
    |> Map.put("limits", %{"max_media_bytes" => 16_777_216, "max_operation_ms" => 30_000, "max_in_flight" => 1})
  end

  defp desired_doc(:init) do
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

  defp object_key_for(:init, rep, seq), do: "recordings/v1/#{hex_slot(rep, seq)}/init.mp4"
  defp object_key_for(:media, rep, seq), do: "recordings/v1/#{hex_slot(rep, seq)}/media.m4s"
  defp object_key_for(:manifest, rep, seq), do: "recordings/v1/#{hex_slot(rep, seq)}/manifest.json"
  defp hex_slot(rep, seq), do: sha256_hex("#{rep}:#{seq}")

  defp purpose_of(target) do
    cond do
      String.contains?(target, "init-") -> :init
      String.contains?(target, "media-") -> :media
      String.contains?(target, "manifest-") -> :manifest
    end
  end

  defp generate_certs do
    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost", dNSName: ~c"objects.example.test"]}

    :public_key.pkix_test_data(%{
      server_chain: %{root: alg, intermediates: [], peer: alg ++ [extensions: [san]]},
      client_chain: %{root: alg, intermediates: [], peer: alg}
    })
  end

  defp write_tls_files(dir, certs, roots) do
    certfile = write_pem(dir, "server.crt", [{:Certificate, certs.server_config[:cert], :not_encrypted}])
    {kt, kd} = certs.server_config[:key]
    keyfile = write_pem(dir, "server.key", [{kt, kd, :not_encrypted}])
    cafile = write_pem(dir, "ca.crt", Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
    %{"certfile" => certfile, "keyfile" => keyfile, "cacertfile" => cafile}
  end

  defp write_client_tls_files(dir, certs, roots) do
    certfile = write_pem(dir, "client.crt", [{:Certificate, certs.client_config[:cert], :not_encrypted}])
    {kt, kd} = certs.client_config[:key]
    keyfile = write_pem(dir, "client.key", [{kt, kd, :not_encrypted}])
    cafile = write_pem(dir, "ca.crt", Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
    %{"certfile" => certfile, "keyfile" => keyfile, "cacertfile" => cafile}
  end

  defp write_pem(dir, name, entries), do: write_file(dir, name, :public_key.pem_encode(entries))

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o600)
    path
  end

  defp deterministic_bytes(len) when rem(len, 4096) == 0 do
    block =
      for idx <- 0..4095, into: <<>> do
        word = idx * 2_654_435_761 &&& 0xFFFFFFFF
        <<bxor(word >>> 16 &&& 0xFF, 0x5A)>>
      end

    :binary.copy(block, div(len, 4096))
  end

  defp timed_ms(fun) do
    t0 = System.monotonic_time(:microsecond)
    _ = fun.()
    (System.monotonic_time(:microsecond) - t0) / 1_000.0
  end

  defp process_cpu_seconds do
    case File.read("/proc/self/stat") do
      {:ok, stat} ->
        [_, rest] = String.split(stat, ")", parts: 2)
        cols = String.split(rest)
        (String.to_integer(Enum.at(cols, 11, "0")) + String.to_integer(Enum.at(cols, 12, "0"))) / 100.0

      _ ->
        0.0
    end
  end

  defp median(vals) do
    sorted = Enum.sort(vals)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      v -> String.to_integer(v)
    end
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
