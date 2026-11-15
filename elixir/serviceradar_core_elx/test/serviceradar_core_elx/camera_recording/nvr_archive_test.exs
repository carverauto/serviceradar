defmodule ServiceRadarCoreElx.CameraRecording.NVRArchiveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadarCoreElx.CameraRecording.NVRArchive
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Fixture

  @moduletag :tmp_dir

  @member "serviceradar-nvr-0"
  @storage_id "00000000-0000-4000-8000-000000000011"
  @recovery_generation "00000000-0000-4000-8000-000000000021"
  @binding_id "00000000-0000-4000-8000-000000000031"
  @secret_id "00000000-0000-4000-8000-000000000041"
  @block_id String.duplicate("0123456789abcdef", 4)
  @token "synthetic-nvr-archive-token-0123456789"
  @access_key_id "EXAMPLEARCHIVEWRITER01"
  @secret_access_key "invented-archive-writer-secret-material"
  @destination %{
    "host" => "objects.example.com",
    "region" => "example-region-1",
    "bucket" => "example-archive",
    "object_prefix" => "recordings/v1"
  }

  setup ctx do
    {:ok, _} = Application.ensure_all_started(:ssl)
    previous_enabled = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled)
    previous_gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

    on_exit(fn ->
      Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, previous_enabled)
      Application.put_env(:serviceradar_core, :nvr_recovery_gate, previous_gate)
    end)

    dir = Path.expand(ctx.tmp_dir)
    gate_path = Path.join(dir, "recovery-state.json")
    write_gate(gate_path, "ready")
    Application.put_env(:serviceradar_core, :nvr_recovery_gate, %{generation: @recovery_generation, path: gate_path})
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)

    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    certs =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    %{dir: dir, gate_path: gate_path, certs: certs, binding: archive_binding()}
  end

  test "sends the member storage, recovery generation, binding destination and writer credential to the NVR", ctx do
    port = start_nvr(ctx, {200, %{"content-type" => "application/json"}, Jason.encode!(receipt())})
    opts = nvr_opts(ctx, port, secret())

    {result, log} = with_log(fn -> NVRArchive.archive_block(@member, @block_id, ctx.binding, @secret_id, opts) end)

    assert {:ok, receipt} = result
    assert receipt == receipt()
    assert_receive {:nvr_request, request}
    assert request.method == "POST"
    assert request.target == "/v1/blocks/#{@block_id}/archive"
    assert request.headers["authorization"] == "Bearer " <> @token
    assert request.headers["content-type"] == "application/vnd.serviceradar.nvr-archive.v1+json"

    assert Jason.decode!(request.body) == %{
             "version" => 1,
             "storage_id" => @storage_id,
             "recovery_generation" => @recovery_generation,
             "destination" => @destination,
             "credential" => %{"access_key_id" => @access_key_id, "secret_access_key" => @secret_access_key}
           }

    refute_credential({result, log, Process.get()})
  end

  test "returns the NVR's refusal reason without the credential", ctx do
    reason = %{"error" => "archive_failed", "stage" => "put", "object" => "media.m4s"}
    port = start_nvr(ctx, {502, %{"content-type" => "application/json"}, Jason.encode!(reason)})
    opts = nvr_opts(ctx, port, secret())

    {result, log} = with_log(fn -> NVRArchive.archive_block(@member, @block_id, ctx.binding, @secret_id, opts) end)

    assert {:error, {:archive_status, 502, ^reason}} = result
    assert_receive {:nvr_request, _request}
    refute_credential({result, log, Process.get()})
  end

  test "sends nothing to the NVR unless recording, recovery and the writer credential are ready", ctx do
    port = start_nvr(ctx, {200, %{"content-type" => "application/json"}, Jason.encode!(receipt())})
    opts = nvr_opts(ctx, port, secret())

    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, false)

    assert {:error, :recording_disabled} =
             NVRArchive.archive_block(@member, @block_id, ctx.binding, @secret_id, opts)

    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)
    write_gate(ctx.gate_path, "closed")

    assert {:error, :nvr_recovery_closed} =
             NVRArchive.archive_block(@member, @block_id, ctx.binding, @secret_id, opts)

    refute_received :credential_loaded

    write_gate(ctx.gate_path, "ready")
    unresolvable = nvr_opts(ctx, port, Map.put(secret(), :provider, "snmp"))

    assert {:error, {:archive_credential_unavailable, :credential_provider_mismatch}} =
             NVRArchive.archive_block(@member, @block_id, ctx.binding, @secret_id, unresolvable)

    assert_received :credential_loaded
    refute_received {:nvr_request, _request}
  end

  defp start_nvr(ctx, response) do
    parent = self()

    Fixture.start(ctx.certs.server_config, fn request ->
      send(parent, {:nvr_request, request})
      response
    end)
  end

  defp nvr_opts(ctx, port, secret) do
    client = ctx.certs.client_config
    {key_type, key_der} = client[:key]
    roots = Enum.map(client[:cacerts], &{:Certificate, &1, :not_encrypted})
    ca = write(ctx.dir, "ca.pem", :public_key.pem_encode(roots))
    cert = write(ctx.dir, "client.pem", :public_key.pem_encode([{:Certificate, client[:cert], :not_encrypted}]))
    key = write(ctx.dir, "client-key.pem", :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))
    token = write(ctx.dir, "nvr-token", @token)

    config =
      write(
        ctx.dir,
        "nvr-client.json",
        Jason.encode!(%{
          "version" => 1,
          "port" => port,
          "ca_file" => ca,
          "cert_file" => cert,
          "key_file" => key,
          "members" => %{@member => %{"host" => "localhost", "storage_id" => @storage_id}}
        })
      )

    parent = self()
    payload = Jason.encode!(%{"access_key_id" => @access_key_id, "secret_access_key" => @secret_access_key})

    [
      config_file: config,
      token_file: token,
      secret_loader: fn @secret_id, _opts ->
        send(parent, :credential_loaded)
        {:ok, secret}
      end,
      grant_issuer: fn attrs, _opts -> {:ok, attrs} end,
      broker: fn _grant, _opts -> {:ok, %{secret: secret, value: payload}} end
    ]
  end

  defp archive_binding do
    {:ok, attributes} =
      ArchiveDestination.attributes(%{
        "schema_version" => 1,
        "provisioning_ref" => "example-archive-binding",
        "generation" => 1,
        "purpose" => "recording",
        "provider" => "s3_compatible",
        "endpoint" => "https://objects.example.com",
        "region" => "example-region-1",
        "bucket" => "example-archive",
        "namespace" => "recordings/v1",
        "archive_format_version" => 1,
        "required_encryption" => "sse_s3_aes256"
      })

    Map.put(attributes, :id, @binding_id)
  end

  defp secret do
    %{id: @secret_id, provider: "s3_compatible", credential_kind: :opaque, enabled: true, deleted_at: nil}
  end

  defp receipt do
    prefix = "recordings/v1/#{@storage_id}/#{@block_id}/"

    %{
      "version" => 1,
      "storage_id" => @storage_id,
      "block_id" => @block_id,
      "destination" => @destination,
      "objects" =>
        Enum.map(["init.mp4", "media.m4s", "descriptor.json"], fn name ->
          %{
            "name" => name,
            "key" => prefix <> name,
            "length" => 4_096,
            "sha256" => String.duplicate("ab", 32),
            "etag" => ~s("example-etag")
          }
        end),
      "verified_at_ms" => 1_763_164_800_000
    }
  end

  defp write_gate(path, state), do: File.write!(path, ~s({"generation":"#{@recovery_generation}","state":"#{state}"}))

  defp write(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  defp refute_credential(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)
    refute text =~ @access_key_id
    refute text =~ @secret_access_key
  end
end
