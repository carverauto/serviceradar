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

  defmodule MemberStatusStub do
    @moduledoc false
    def fetch_all(_opts) do
      %{
        "00000000-0000-4000-8000-0000000005a1" => %{
          storage_id: "00000000-0000-4000-8000-0000000005a1",
          inventory: :ready,
          capacity: %{used_bytes: 1_048_576, max_spool_bytes: 10_485_760}
        }
      }
    end
  end

  setup do
    orig_gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)
    orig_sup = Application.get_env(:serviceradar_web_ng, :camera_recording_remote_supervisor)
    orig_member_status = Application.get_env(:serviceradar_web_ng, :camera_recording_remote_member_status)
    orig_nodes = Application.get_env(:serviceradar_web_ng, :camera_recording_rpc_nodes)
    orig_timeout = Application.get_env(:serviceradar_web_ng, :camera_recording_rpc_timeout_ms)
    orig_cfg = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_config_file)
    orig_tok = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_token_file)

    on_exit(fn ->
      restore_env(:serviceradar_core, :nvr_recovery_gate, orig_gate)
      restore_env(:serviceradar_web_ng, :camera_recording_remote_supervisor, orig_sup)
      restore_env(:serviceradar_web_ng, :camera_recording_remote_member_status, orig_member_status)
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
               nvr_installation: :unknown,
               members: []
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
               nvr_installation: :not_installed,
               members: []
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
               nvr_installation: :installed,
               members: []
             }
    end

    test "discovers sorted NVR members from bounded config_file without reading token_file", %{
      tmp_dir: tmp_dir
    } do
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

      config_path = Path.join(tmp_dir, "nvr-client.json")
      unreadable_token_path = Path.join(tmp_dir, "unreadable-nvr-token")
      File.write!(unreadable_token_path, "synthetic-never-read-token")
      File.chmod!(unreadable_token_path, 0o000)

      on_exit(fn ->
        File.chmod(unreadable_token_path, 0o600)
      end)

      File.write!(
        config_path,
        Jason.encode!(%{
          "members" => %{
            "nvr-1" => %{
              "host" => "nvr-1.example.com",
              "port" => 8443,
              "storage_id" => "00000000-0000-4000-8000-0000000005B2"
            },
            "nvr-0" => %{
              "host" => "nvr-0.example.com",
              "port" => 8443,
              "storage_id" => "00000000-0000-4000-8000-0000000005a1"
            },
            "INVALID_UPPER" => %{
              "storage_id" => "00000000-0000-4000-8000-0000000005c3"
            },
            "nvr-bad-uuid" => %{
              "storage_id" => "not-a-uuid"
            }
          }
        })
      )

      Application.put_env(:serviceradar_core_elx, :camera_nvr_client_config_file, config_path)

      Application.put_env(
        :serviceradar_core_elx,
        :camera_nvr_client_token_file,
        unreadable_token_path
      )

      assert CameraRecordingRuntime.core_elx_status() == %{
               reachability: :reachable,
               node: Node.self(),
               supervisor: :enabled,
               nvr_installation: :installed,
               members: [
                 %{member: "nvr-0", storage_id: "00000000-0000-4000-8000-0000000005a1"},
                 %{member: "nvr-1", storage_id: "00000000-0000-4000-8000-0000000005b2"}
               ]
             }

      # Oversized config file (> 32 KiB) returns empty members list safely
      oversized_path = Path.join(tmp_dir, "oversized-nvr-client.json")
      File.write!(oversized_path, String.duplicate(" ", 32_769))
      Application.put_env(:serviceradar_core_elx, :camera_nvr_client_config_file, oversized_path)

      assert CameraRecordingRuntime.core_elx_status().members == []
    end
  end

  describe "member_statuses/1" do
    test "fetches live member statuses via bounded RPC when core-elx is reachable and installed" do
      Application.put_env(
        :serviceradar_web_ng,
        :camera_recording_remote_member_status,
        MemberStatusStub
      )

      runtime = %{
        core_elx: %{
          reachability: :reachable,
          nvr_installation: :installed,
          node: Node.self()
        }
      }

      assert %{
               "00000000-0000-4000-8000-0000000005a1" => %{
                 inventory: :ready,
                 capacity: %{used_bytes: 1_048_576}
               }
             } = CameraRecordingRuntime.member_statuses(runtime)
    end

    test "returns empty map safely when core-elx is unreachable, not installed, or node is not connected" do
      assert CameraRecordingRuntime.member_statuses(%{
               core_elx: %{reachability: :unreachable, nvr_installation: :unknown, node: nil}
             }) == %{}

      assert CameraRecordingRuntime.member_statuses(%{
               core_elx: %{reachability: :reachable, nvr_installation: :not_installed, node: Node.self()}
             }) == %{}

      assert CameraRecordingRuntime.member_statuses(%{
               core_elx: %{
                 reachability: :reachable,
                 nvr_installation: :installed,
                 node: :"disconnected-core-elx@example.internal"
               }
             }) == %{}
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
