defmodule ServiceRadarCoreElx.CameraRecording.NVRTargetConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.CameraRecording.NVRCapture
  alias ServiceRadarCoreElx.CameraRecording.NVRTargetConfig
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor

  @moduletag :tmp_dir

  setup do
    prev_enabled = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    prev_cfg = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_config_file)
    prev_tok = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_token_file)

    Application.put_env(:serviceradar_core_elx, :camera_nvr_client_config_file, nil)
    Application.put_env(:serviceradar_core_elx, :camera_nvr_client_token_file, nil)

    on_exit(fn ->
      Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, prev_enabled)
      Application.put_env(:serviceradar_core_elx, :camera_nvr_client_config_file, prev_cfg)
      Application.put_env(:serviceradar_core_elx, :camera_nvr_client_token_file, prev_tok)
    end)

    :ok
  end

  test "resolves installed member credentials, enforces distinct storage IDs, and redacts tokens", ctx do
    assert {:error, :nvr_client_not_configured} = NVRTargetConfig.resolve("serviceradar-nvr-0")

    files = write_client_fixture(ctx.tmp_dir)

    assert {:ok, first} =
             NVRTargetConfig.resolve("serviceradar-nvr-0",
               config_file: files.config,
               token_file: files.token
             )

    assert first.member == "serviceradar-nvr-0"
    assert first.storage_id == "00000000-0000-4000-8000-000000000011"
    assert first.client_config.host == "serviceradar-nvr-0.serviceradar-nvr.example.svc.cluster.local"
    assert first.client_config.port == 8_443
    refute inspect(first) =~ "synthetic-nvr-client-token-0123456789"
    refute inspect(first.client_config) =~ "token:"
    assert inspect(first.client_config) =~ "#ServiceRadarNVRClient.Config<"

    assert {:ok, second} =
             NVRTargetConfig.resolve("serviceradar-nvr-1",
               config_file: files.config,
               token_file: files.token
             )

    assert second.storage_id == "00000000-0000-4000-8000-000000000012"
    assert second.client_config.port == 9_443

    assert {:error, :unknown_nvr_member} =
             NVRTargetConfig.resolve("serviceradar-nvr-2",
               config_file: files.config,
               token_file: files.token
             )

    assert {:error, :invalid_nvr_member} =
             NVRTargetConfig.resolve("../serviceradar-nvr-0",
               config_file: files.config,
               token_file: files.token
             )

    duplicate =
      Map.put(files.document, "members", %{
        "serviceradar-nvr-0" => %{
          "host" => "serviceradar-nvr-0.serviceradar-nvr.example.svc.cluster.local",
          "storage_id" => "00000000-0000-4000-8000-000000000011"
        },
        "serviceradar-nvr-1" => %{
          "host" => "serviceradar-nvr-1.serviceradar-nvr.example.svc.cluster.local",
          "storage_id" => "00000000-0000-4000-8000-000000000011"
        }
      })

    File.write!(files.config, Jason.encode!(duplicate))

    assert {:error, :duplicate_nvr_storage_id} =
             NVRTargetConfig.resolve("serviceradar-nvr-0",
               config_file: files.config,
               token_file: files.token
             )

    uppercase =
      put_in(
        files.document,
        ["members", "serviceradar-nvr-0", "storage_id"],
        "00000000-0000-4000-8000-0000000000AA"
      )

    File.write!(files.config, Jason.encode!(uppercase))

    assert {:error, :invalid_nvr_client_config} =
             NVRTargetConfig.resolve("serviceradar-nvr-0",
               config_file: files.config,
               token_file: files.token
             )

    File.write!(files.config, Jason.encode!(files.document))
    File.write!(files.token, "synthetic-nvr-client-token-0123456789\n")

    assert {:error, :invalid_nvr_client_config} =
             NVRTargetConfig.resolve("serviceradar-nvr-0",
               config_file: files.config,
               token_file: files.token
             )
  end

  test "coordinator and supervisor reject disabled or malformed capture requests before database work", ctx do
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    assert {:error, :recording_disabled} = RecordingSupervisor.start_nvr_recorder([])

    source_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()
    relay_id = Ecto.UUID.generate()

    assert {:error, :invalid_capture_timeout} =
             NVRCapture.once_relay(relay_id, "serviceradar-nvr-0", timeout_ms: 0)

    assert {:error, :invalid_camera_source_id} =
             NVRCapture.once_source("not-a-uuid", profile_id, "serviceradar-nvr-0")

    assert {:error, :invalid_stream_profile_id} =
             NVRCapture.once_source(source_id, "not-a-uuid", "serviceradar-nvr-0")

    assert {:error, :invalid_relay_id} =
             NVRCapture.once_relay("not-a-uuid", "serviceradar-nvr-0")

    assert {:error, :nvr_client_not_configured} =
             NVRCapture.once_source(source_id, profile_id, "serviceradar-nvr-0")

    files = write_client_fixture(ctx.tmp_dir)

    assert {:error, :unknown_nvr_member} =
             NVRCapture.once_relay(relay_id, "serviceradar-nvr-9",
               config_file: files.config,
               token_file: files.token
             )
  end

  defp write_client_fixture(dir) do
    abs_dir = Path.expand(dir)
    ca = Path.join(abs_dir, "ca.pem")
    cert = Path.join(abs_dir, "client.pem")
    key = Path.join(abs_dir, "client-key.pem")
    config = Path.join(abs_dir, "config.json")
    token = Path.join(abs_dir, "token")

    for path <- [ca, cert, key], do: File.write!(path, "synthetic-pem")
    File.write!(token, "synthetic-nvr-client-token-0123456789")

    document = %{
      "version" => 1,
      "port" => 8_443,
      "ca_file" => ca,
      "cert_file" => cert,
      "key_file" => key,
      "members" => %{
        "serviceradar-nvr-0" => %{
          "host" => "serviceradar-nvr-0.serviceradar-nvr.example.svc.cluster.local",
          "storage_id" => "00000000-0000-4000-8000-000000000011"
        },
        "serviceradar-nvr-1" => %{
          "host" => "serviceradar-nvr-1.serviceradar-nvr.example.svc.cluster.local",
          "port" => 9_443,
          "storage_id" => "00000000-0000-4000-8000-000000000012"
        }
      }
    }

    File.write!(config, Jason.encode!(document))
    %{config: config, token: token, document: document}
  end
end
