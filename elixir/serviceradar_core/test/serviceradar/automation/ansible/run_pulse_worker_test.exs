defmodule ServiceRadar.Automation.Ansible.RunPulseWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.RunPulseWorker

  defmodule FakeAwxClient do
    @moduledoc false
    def fetch_events_for_jobs(controller, pairs, opts) do
      send(opts[:test_pid] || self(), {:fetch_events_for_jobs, controller.id, pairs, opts})
      {:ok, %{id: "command-1"}}
    end

    def fetch_events_for_jobs_failing(_controller, _pairs, _opts), do: {:error, :boom}
  end

  defmodule FailingAwxClient do
    @moduledoc false
    def fetch_events_for_jobs(_controller, _pairs, _opts), do: {:error, :boom}
  end

  defmodule FailSecondBatchAwxClient do
    @moduledoc false

    def fetch_events_for_jobs(controller, pairs, opts) do
      send(self(), {:fetch_events_for_jobs, controller.id, pairs, opts})

      if opts[:context]["batch_index"] == 2,
        do: {:error, :boom},
        else: {:ok, %{id: "command-1"}}
    end
  end

  defp controller(overrides \\ %{}) do
    Map.merge(
      %Controller{
        id: "ctrl-uuid-1",
        name: "Production AWX",
        base_url: "https://awx.example.com",
        agent_id: "agent-a",
        credential_secret_id: "secret-1",
        run_pulse_interval_ms: 2000
      },
      Map.new(overrides)
    )
  end

  describe "build_pairs (via tick_controller)" do
    test "no active runs → no dispatch" do
      assert :ok = RunPulseWorker.tick_controller(controller(), [], awx_client: FakeAwxClient)
      refute_received {:fetch_events_for_jobs, _, _, _}
    end

    test "active runs without awx_job_id (still :pending) are skipped" do
      runs = [
        %{id: "r-1", awx_job_id: nil, last_event_id: 0, state: :pending}
      ]

      assert :ok =
               RunPulseWorker.tick_controller(controller(), runs,
                 awx_client: FakeAwxClient,
                 test_pid: self()
               )

      refute_received {:fetch_events_for_jobs, _, _, _}
    end

    test "dispatches one bulk command with (job_id, since_id) pairs" do
      runs = [
        %{id: "r-1", awx_job_id: 7331, last_event_id: 0, state: :running},
        %{id: "r-2", awx_job_id: 7332, last_event_id: 142, state: :running},
        %{id: "r-3", awx_job_id: nil, last_event_id: 0, state: :pending}
      ]

      assert :ok =
               RunPulseWorker.tick_controller(controller(), runs,
                 awx_client: FakeAwxClient,
                 test_pid: self()
               )

      assert_received {:fetch_events_for_jobs, "ctrl-uuid-1", pairs, _opts}
      assert pairs == [%{job_id: 7331, since_id: 0}, %{job_id: 7332, since_id: 142}]
    end

    test "carries source and controller_id in opts.context" do
      runs = [%{id: "r-1", awx_job_id: 1, last_event_id: 0, state: :running}]

      assert :ok =
               RunPulseWorker.tick_controller(controller(), runs,
                 awx_client: FakeAwxClient,
                 test_pid: self()
               )

      assert_received {:fetch_events_for_jobs, "ctrl-uuid-1", _pairs, opts}
      assert opts[:source] == :automation
      assert opts[:context]["controller_id"] == "ctrl-uuid-1"
      assert opts[:context]["verb"] == "awx.fetch_events_for_jobs"
      assert opts[:context]["active_run_count"] == 1
      assert opts[:context]["batch_count"] == 1
      assert opts[:context]["batch_index"] == 1
      assert opts[:context]["batch_run_count"] == 1
    end

    test "treats nil last_event_id as 0" do
      runs = [%{id: "r-1", awx_job_id: 1, last_event_id: nil, state: :launching}]

      assert :ok =
               RunPulseWorker.tick_controller(controller(), runs,
                 awx_client: FakeAwxClient,
                 test_pid: self()
               )

      assert_received {:fetch_events_for_jobs, _, [%{job_id: 1, since_id: 0}], _}
    end

    test "chunks more than ten active runs without dropping or duplicating pairs" do
      runs =
        Enum.map(1..23, fn job_id ->
          %{
            id: "r-#{job_id}",
            awx_job_id: job_id,
            last_event_id: job_id * 10,
            state: :running
          }
        end)

      assert :ok =
               RunPulseWorker.tick_controller(controller(), runs,
                 awx_client: FakeAwxClient,
                 test_pid: self()
               )

      assert_received {:fetch_events_for_jobs, "ctrl-uuid-1", first_batch, first_opts}
      assert_received {:fetch_events_for_jobs, "ctrl-uuid-1", second_batch, second_opts}
      assert_received {:fetch_events_for_jobs, "ctrl-uuid-1", third_batch, third_opts}

      assert Enum.map([first_batch, second_batch, third_batch], &length/1) == [10, 10, 3]

      assert Enum.concat([first_batch, second_batch, third_batch]) ==
               Enum.map(1..23, &%{job_id: &1, since_id: &1 * 10})

      for {opts, batch_index, batch_run_count} <- [
            {first_opts, 1, 10},
            {second_opts, 2, 10},
            {third_opts, 3, 3}
          ] do
        assert opts[:source] == :automation
        assert opts[:context]["active_run_count"] == 23
        assert opts[:context]["batch_count"] == 3
        assert opts[:context]["batch_index"] == batch_index
        assert opts[:context]["batch_run_count"] == batch_run_count
        assert map_size(opts[:context]) == 6
      end
    end
  end

  describe "dispatch failure handling" do
    test "returns the error and logs (no crash)" do
      runs = [%{id: "r-1", awx_job_id: 1, last_event_id: 0, state: :running}]

      assert {:error, :boom} =
               RunPulseWorker.tick_controller(controller(), runs, awx_client: FailingAwxClient)
    end

    test "halts after the first failed batch and reports that error" do
      runs =
        Enum.map(1..23, fn job_id ->
          %{id: "r-#{job_id}", awx_job_id: job_id, last_event_id: 0, state: :running}
        end)

      assert {:error, :boom} =
               RunPulseWorker.tick_controller(controller(), runs,
                 awx_client: FailSecondBatchAwxClient
               )

      assert_received {:fetch_events_for_jobs, _, first_batch, first_opts}
      assert_received {:fetch_events_for_jobs, _, second_batch, second_opts}
      refute_received {:fetch_events_for_jobs, _, _third_batch, _third_opts}

      assert length(first_batch) == 10
      assert first_opts[:context]["batch_index"] == 1
      assert length(second_batch) == 10
      assert second_opts[:context]["batch_index"] == 2
    end
  end

  describe "perform/1 invalid args" do
    test "returns {:error, :invalid_args} when controller_id is missing" do
      assert {:error, :invalid_args} = RunPulseWorker.perform(%Oban.Job{args: %{}})
    end
  end
end
