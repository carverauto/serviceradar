defmodule ServiceRadar.Software.TftpDispatchTest do
  @moduledoc """
  Integration tests for TFTP dispatch hooks (DispatchTftpStart, DispatchTftpStop,
  DispatchTftpStage) and the TftpStatusHandler GenServer.

  Requires a database. Run with: mix test --include integration
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Software.SoftwareImage
  alias ServiceRadar.Software.TftpSession
  alias ServiceRadar.Software.TftpStatusHandler
  alias ServiceRadar.TestSupport

  require Ash.Query

  defmodule TestControlSession do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end

    @impl true
    def init(opts) do
      {:ok, %{test_pid: opts[:test_pid]}}
    end

    @impl true
    def handle_call({:send_command, command, context}, _from, state) do
      send(state.test_pid, {:send_command, command, context})
      {:reply, {:ok, command.command_id}, state}
    end

    @impl true
    def handle_call({:push_config, response}, _from, state) do
      send(state.test_pid, {:push_config, response})
      {:reply, :ok, state}
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    agent_id = "agent-tftp-#{System.unique_integer([:positive])}"
    actor = SystemActor.system(:tftp_dispatch_test)
    {:ok, agent_id: agent_id, actor: actor}
  end

  describe "DispatchTftpStart" do
    test "dispatches tftp.start_receive for receive-mode session", %{
      agent_id: agent_id,
      actor: actor
    } do
      start_control_session(agent_id, self(), %{
        partition_id: "default",
        capabilities: ["tftp"]
      })

      session = create_session!(:receive, agent_id, actor)
      queued = transition!(session, :queue, %{}, actor)
      assert queued.status == :queued

      assert_receive {:send_command, command, _context}, 2_000
      assert command.command_type == "tftp.start_receive"

      payload = Jason.decode!(command.payload_json)
      assert payload["session_id"] == session.id
      assert payload["mode"] == "receive"
      assert payload["expected_filename"] == "running-config"
      assert payload["timeout_seconds"] == 300
      assert payload["port"] == 6969
    end

    test "dispatches tftp.start_serve for serve-mode session", %{
      agent_id: agent_id,
      actor: actor
    } do
      start_control_session(agent_id, self(), %{
        partition_id: "default",
        capabilities: ["tftp"]
      })

      session = create_session!(:serve, agent_id, actor, %{expected_filename: "firmware.bin"})
      queued = transition!(session, :queue, %{}, actor)
      assert queued.status == :queued

      assert_receive {:send_command, command, _context}, 2_000
      assert command.command_type == "tftp.start_serve"

      payload = Jason.decode!(command.payload_json)
      assert payload["session_id"] == session.id
      assert payload["mode"] == "serve"
      assert payload["expected_filename"] == "firmware.bin"
    end
  end

  describe "DispatchTftpStop" do
    test "dispatches tftp.stop_session on cancel", %{agent_id: agent_id, actor: actor} do
      start_control_session(agent_id, self(), %{
        partition_id: "default",
        capabilities: ["tftp"]
      })

      session = create_session!(:receive, agent_id, actor)
      queued = transition!(session, :queue, %{}, actor)

      # Consume the start_receive dispatch
      assert_receive {:send_command, _, _}, 2_000

      canceled = transition!(queued, :cancel, %{}, actor)
      assert canceled.status == :canceled

      assert_receive {:send_command, command, _context}, 2_000
      assert command.command_type == "tftp.stop_session"

      payload = Jason.decode!(command.payload_json)
      assert payload["session_id"] == session.id
    end
  end

  describe "DispatchTftpStage" do
    test "dispatches tftp.stage_image on staging transition", %{
      agent_id: agent_id,
      actor: actor
    } do
      start_control_session(agent_id, self(), %{
        partition_id: "default",
        capabilities: ["tftp"]
      })

      image = create_image!(actor)

      session =
        create_session!(:serve, agent_id, actor, %{
          expected_filename: "firmware.bin",
          image_id: image.id
        })

      queued = transition!(session, :queue, %{}, actor)

      # Consume the start_serve dispatch
      assert_receive {:send_command, _, _}, 2_000

      staging = transition!(queued, :start_staging, %{}, actor)
      assert staging.status == :staging

      assert_receive {:send_command, command, _context}, 2_000
      assert command.command_type == "tftp.stage_image"

      payload = Jason.decode!(command.payload_json)
      assert payload["session_id"] == session.id
      assert payload["image_id"] == image.id
      assert payload["expected_filename"] == "firmware.bin"
    end
  end

  describe "TftpStatusHandler — receive completion" do
    test "transitions session to completed on success result", %{
      agent_id: agent_id,
      actor: actor
    } do
      start_control_session(agent_id, self(), %{
        partition_id: "default",
        capabilities: ["tftp"]
      })

      ensure_tftp_status_handler_started()

      session = advance_to_receiving!(agent_id, actor)

      send(TftpStatusHandler, {
        :command_result,
        %{
          command_type: "tftp.start_receive",
          context: %{tftp_session_id: session.id},
          success: true,
          payload: %{"file_size" => 4096, "content_hash" => "sha256:abc123"},
          message: "transfer complete"
        }
      })

      updated = wait_for_session_status(session.id, :completed, actor)
      assert updated.file_size == 4096
      assert updated.content_hash == "sha256:abc123"
    end
  end

  describe "TftpStatusHandler — serve completion" do
    test "transitions session to completed on success result", %{
      agent_id: agent_id,
      actor: actor
    } do
      start_control_session(agent_id, self(), %{
        partition_id: "default",
        capabilities: ["tftp"]
      })

      ensure_tftp_status_handler_started()

      session = advance_to_serving!(agent_id, actor)

      send(TftpStatusHandler, {
        :command_result,
        %{
          command_type: "tftp.start_serve",
          context: %{tftp_session_id: session.id},
          success: true,
          payload: %{"file_size" => 8192},
          message: "serve complete"
        }
      })

      updated = wait_for_session_status(session.id, :completed, actor)
      assert updated.file_size == 8192
    end
  end

  describe "TftpStatusHandler — failure" do
    test "transitions session to failed on error result", %{
      agent_id: agent_id,
      actor: actor
    } do
      start_control_session(agent_id, self(), %{
        partition_id: "default",
        capabilities: ["tftp"]
      })

      ensure_tftp_status_handler_started()

      session = advance_to_receiving!(agent_id, actor)

      send(TftpStatusHandler, {
        :command_result,
        %{
          command_type: "tftp.start_receive",
          context: %{tftp_session_id: session.id},
          success: false,
          message: "connection timed out"
        }
      })

      updated = wait_for_session_status(session.id, :failed, actor)
      assert updated.error_message == "connection timed out"
    end
  end

  describe "TftpStatusHandler — progress" do
    test "updates progress fields on receiving session", %{
      agent_id: agent_id,
      actor: actor
    } do
      start_control_session(agent_id, self(), %{
        partition_id: "default",
        capabilities: ["tftp"]
      })

      ensure_tftp_status_handler_started()

      session = advance_to_receiving!(agent_id, actor)

      send(TftpStatusHandler, {
        :command_progress,
        %{
          command_type: "tftp.start_receive",
          context: %{tftp_session_id: session.id},
          message: "transferring",
          payload: %{"bytes_transferred" => 2048, "transfer_rate" => 512}
        }
      })

      updated = wait_for_session_progress(session.id, 2048, actor)
      assert updated.bytes_transferred == 2048
      assert updated.transfer_rate == 512
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp create_session!(mode, agent_id, actor, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          mode: mode,
          agent_id: agent_id,
          expected_filename: "running-config",
          timeout_seconds: 300
        },
        extra
      )

    TftpSession
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!()
  end

  defp create_image!(actor) do
    SoftwareImage
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "test-image-#{System.unique_integer([:positive])}",
        version: "1.0.0",
        filename: "test-image.bin",
        file_size: 8192,
        content_hash: "sha256:deadbeef"
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp transition!(session, action, params, actor) do
    session
    |> Ash.Changeset.for_update(action, params, actor: actor)
    |> Ash.update!()
  end

  defp advance_to_receiving!(agent_id, actor) do
    session = create_session!(:receive, agent_id, actor)
    session = transition!(session, :queue, %{}, actor)
    assert_receive {:send_command, _, _}, 2_000

    session = transition!(session, :start_waiting, %{}, actor)
    transition!(session, :start_receiving, %{}, actor)
  end

  defp advance_to_serving!(agent_id, actor) do
    image = create_image!(actor)

    session =
      create_session!(:serve, agent_id, actor, %{
        expected_filename: "firmware.bin",
        image_id: image.id
      })

    session = transition!(session, :queue, %{}, actor)
    # Consume start_serve dispatch
    assert_receive {:send_command, _, _}, 2_000

    session = transition!(session, :start_staging, %{}, actor)
    # Consume stage_image dispatch
    assert_receive {:send_command, _, _}, 2_000

    session = transition!(session, :mark_ready, %{}, actor)
    transition!(session, :start_serving, %{}, actor)
  end

  defp start_control_session(agent_id, test_pid, metadata) do
    name = ProcessRegistry.via({:agent_control, agent_id}, metadata)
    {:ok, pid} = TestControlSession.start_link(name: name, test_pid: test_pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {pid, metadata}
  end

  defp ensure_tftp_status_handler_started do
    case Process.whereis(TftpStatusHandler) do
      nil -> TftpStatusHandler.start_link([])
      _pid -> :ok
    end
  end

  defp wait_for_session_status(session_id, expected_status, actor) do
    Enum.reduce_while(1..40, nil, fn _, _ ->
      case load_session(session_id, actor) do
        {:ok, %{status: ^expected_status} = session} ->
          {:halt, session}

        _ ->
          Process.sleep(50)
          {:cont, nil}
      end
    end) ||
      flunk("Expected session #{session_id} to reach status #{inspect(expected_status)}")
  end

  defp wait_for_session_progress(session_id, expected_bytes, actor) do
    Enum.reduce_while(1..40, nil, fn _, _ ->
      case load_session(session_id, actor) do
        {:ok, %{bytes_transferred: ^expected_bytes} = session} ->
          {:halt, session}

        _ ->
          Process.sleep(50)
          {:cont, nil}
      end
    end) ||
      flunk(
        "Expected session #{session_id} to reach bytes_transferred #{inspect(expected_bytes)}"
      )
  end

  defp load_session(session_id, actor) do
    TftpSession
    |> Ash.Query.for_read(:by_id, %{id: session_id}, actor: actor)
    |> Ash.read_one()
  end
end
