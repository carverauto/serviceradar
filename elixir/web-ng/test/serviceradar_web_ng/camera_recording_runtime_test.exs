defmodule ServiceRadarWebNG.CameraRecordingRuntimeTest do
  use ExUnit.Case, async: false

  alias ServiceRadarRecordingMetadata.CanonicalJSON
  alias ServiceRadarWebNG.CameraRecordingRuntime

  @moduletag :db_free
  @moduletag :tmp_dir

  defmodule EnabledSupervisorStub do
    @moduledoc false
    def enabled?, do: true
  end

  defmodule DisabledSupervisorStub do
    @moduledoc false
    def enabled?, do: false
  end

  setup do
    orig_gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)
    orig_sup = Application.get_env(:serviceradar_web_ng, :camera_recording_remote_supervisor)
    orig_nodes = Application.get_env(:serviceradar_web_ng, :camera_recording_rpc_nodes)
    orig_timeout = Application.get_env(:serviceradar_web_ng, :camera_recording_rpc_timeout_ms)
    orig_cfg = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_config_file)
    orig_tok = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_token_file)

    on_exit(fn ->
      restore_env(:serviceradar_core, :nvr_recovery_gate, orig_gate)
      restore_env(:serviceradar_web_ng, :camera_recording_remote_supervisor, orig_sup)
      restore_env(:serviceradar_web_ng, :camera_recording_rpc_nodes, orig_nodes)
      restore_env(:serviceradar_web_ng, :camera_recording_rpc_timeout_ms, orig_timeout)
      restore_env(:serviceradar_core_elx, :camera_nvr_client_config_file, orig_cfg)
      restore_env(:serviceradar_core_elx, :camera_nvr_client_token_file, orig_tok)
    end)

    :ok
  end

  describe "recovery_gate_status/0" do
    test "distinguishes nil (:not_configured) from closed and open gates", %{tmp_dir: tmp_dir} do
      Application.put_env(:serviceradar_core, :nvr_recovery_gate, nil)
      assert CameraRecordingRuntime.recovery_gate_status() == %{state: :not_configured, generation: nil}

      generation = "00000000-0000-4000-8000-000000000011"
      gate_path = Path.join(tmp_dir, "recovery-state.json")

      Application.put_env(:serviceradar_core, :nvr_recovery_gate, %{
        generation: generation,
        path: gate_path
      })

      assert CameraRecordingRuntime.recovery_gate_status() == %{
               state: :closed,
               generation: generation
             }

      {:ok, ready_bytes} =
        CanonicalJSON.encode(%{"generation" => generation, "state" => "ready"})

      File.write!(gate_path, ready_bytes)

      assert CameraRecordingRuntime.recovery_gate_status() == %{
               state: :open,
               generation: generation
             }
    end
  end

  describe "core_elx_status/0" do
    test "reports unreachable core-elx as unknown and never as not_installed" do
      Application.put_env(:serviceradar_web_ng, :camera_recording_rpc_nodes, [
        :"unreachable-core-elx@127.0.0.1"
      ])

      Application.put_env(:serviceradar_web_ng, :camera_recording_rpc_timeout_ms, 200)

      assert CameraRecordingRuntime.core_elx_status() == %{
               reachability: :unreachable,
               node: nil,
               supervisor: :unknown,
               nvr_installation: :unknown
             }
    end

    test "reports not_installed when core-elx is reachable and NVR client files are unset" do
      start_supervised!(%{
        id: DisabledSupervisorStub,
        start: {Agent, :start_link, [fn -> :ok end, [name: DisabledSupervisorStub]]}
      })

      Application.put_env(
        :serviceradar_web_ng,
        :camera_recording_remote_supervisor,
        DisabledSupervisorStub
      )

      Application.put_env(:serviceradar_web_ng, :camera_recording_rpc_nodes, [Node.self()])
      Application.put_env(:serviceradar_core_elx, :camera_nvr_client_config_file, nil)
      Application.put_env(:serviceradar_core_elx, :camera_nvr_client_token_file, nil)

      assert CameraRecordingRuntime.core_elx_status() == %{
               reachability: :reachable,
               node: Node.self(),
               supervisor: :disabled,
               nvr_installation: :not_installed
             }
    end

    test "reports installed and enabled when core-elx supervisor and absolute client paths exist" do
      start_supervised!(%{
        id: EnabledSupervisorStub,
        start: {Agent, :start_link, [fn -> :ok end, [name: EnabledSupervisorStub]]}
      })

      Application.put_env(
        :serviceradar_web_ng,
        :camera_recording_remote_supervisor,
        EnabledSupervisorStub
      )

      Application.put_env(:serviceradar_web_ng, :camera_recording_rpc_nodes, [Node.self()])

      Application.put_env(
        :serviceradar_core_elx,
        :camera_nvr_client_config_file,
        "/etc/serviceradar/nvr-client.json"
      )

      Application.put_env(
        :serviceradar_core_elx,
        :camera_nvr_client_token_file,
        "/etc/serviceradar/nvr-token"
      )

      assert CameraRecordingRuntime.core_elx_status() == %{
               reachability: :reachable,
               node: Node.self(),
               supervisor: :enabled,
               nvr_installation: :installed
             }
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
