defmodule ServiceRadar.Automation.Ansible.EventIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.EventIngestor
  alias ServiceRadar.Automation.Ansible.IngestorActions

  defmodule FakeActions do
    @moduledoc false
    @behaviour IngestorActions

    def state, do: Process.get(:fake_actions_state, default_state())
    def reset, do: Process.delete(:fake_actions_state)

    def configure(opts) do
      Process.put(:fake_actions_state, Map.merge(state(), Map.new(opts)))
      :ok
    end

    @impl true
    def get_run_by_awx_job_id(awx_job_id) do
      put_call({:get_run_by_awx_job_id, awx_job_id})
      Map.get(state().runs_by_job_id, awx_job_id, {:error, :run_not_found})
    end

    @impl true
    def upsert_play(args) do
      put_call({:upsert_play, args})
      {:ok, %{id: "play-" <> args.awx_play_uuid, awx_play_uuid: args.awx_play_uuid}}
    end

    @impl true
    def upsert_task(args) do
      put_call({:upsert_task, args})
      {:ok, %{id: "task-" <> args.awx_task_uuid, awx_task_uuid: args.awx_task_uuid}}
    end

    @impl true
    def upsert_task_result(args) do
      put_call({:upsert_task_result, args})
      {:ok, args}
    end

    @impl true
    def get_run_target(run_id, awx_host_name) do
      put_call({:get_run_target, run_id, awx_host_name})
      Map.get(state().targets_by_host, awx_host_name, {:error, :run_target_not_found})
    end

    @impl true
    def record_target_outcome(target, args) do
      put_call({:record_target_outcome, target.id, args})
      {:ok, target}
    end

    @impl true
    def advance_watermark(run, last_event_id) do
      put_call({:advance_watermark, run.id, last_event_id})
      {:ok, %{run | last_event_id: last_event_id}}
    end

    @impl true
    def transition_run(run, transition, args) do
      put_call({:transition_run, run.id, transition, args})
      {:ok, %{run | state: terminal_state_for(transition)}}
    end

    @impl true
    def get_command_context(command_id) do
      put_call({:get_command_context, command_id})
      Map.get(state().contexts, command_id, {:error, :command_not_found})
    end

    @impl true
    def get_run_by_id(run_id) do
      put_call({:get_run_by_id, run_id})
      Map.get(state().runs_by_id, run_id, {:error, :run_not_found})
    end

    @impl true
    def get_controller_by_id(controller_id) do
      put_call({:get_controller_by_id, controller_id})
      Map.get(state().controllers_by_id, controller_id, {:error, :controller_not_found})
    end

    @impl true
    def record_controller_health(controller, args) do
      put_call({:record_controller_health, controller.id, args})
      {:ok, controller}
    end

    @impl true
    def upsert_awx_playbook(controller_id, args) do
      put_call({:upsert_awx_playbook, controller_id, args})
      {:ok, %{id: "pb-" <> to_string(args.awx_job_template_id)}}
    end

    @impl true
    def emit_ocsf_event(event) do
      put_call({:emit_ocsf_event, event})
      :ok
    end

    defp terminal_state_for(:record_launching), do: :launching
    defp terminal_state_for(:record_running), do: :running
    defp terminal_state_for(:record_succeeded), do: :succeeded
    defp terminal_state_for(:record_partial), do: :partial
    defp terminal_state_for(:record_failed), do: :failed
    defp terminal_state_for(:record_unreachable), do: :unreachable
    defp terminal_state_for(:record_canceled), do: :canceled

    defp put_call(call) do
      st = state()
      Process.put(:fake_actions_state, %{st | calls: st.calls ++ [call]})
    end

    defp default_state,
      do: %{
        calls: [],
        runs_by_job_id: %{},
        targets_by_host: %{},
        contexts: %{},
        runs_by_id: %{},
        controllers_by_id: %{}
      }
  end

  setup do
    FakeActions.reset()
    :ok
  end

  defp opts, do: [actions: FakeActions]

  defp run_fixture(overrides) do
    base = %{id: "run-1", state: :launching, last_event_id: 0}

    case overrides do
      kw when is_list(kw) -> Enum.into(kw, base)
      %{} = m -> Map.merge(base, m)
    end
  end

  defp event(type, attrs) do
    Map.merge(%{"type" => type, "counter" => 0}, attrs)
  end

  describe "non-AWX command_types are no-ops" do
    test "unknown command type does nothing and returns :ok" do
      assert :ok = EventIngestor.handle_command_result(%{command_type: "mtr.run"}, opts())
      assert FakeActions.state().calls == []
    end

    test "missing command_type returns :ok" do
      assert :ok = EventIngestor.handle_command_result(%{}, opts())
      assert FakeActions.state().calls == []
    end
  end

  describe "awx.launch_job" do
    test "happy path: extracts awx_job_id, transitions :pending → :launching" do
      run = run_fixture(id: "run-99", state: :pending)

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
        runs_by_id: %{"run-99" => {:ok, run}}
      )

      result = %{
        command_type: "awx.launch_job",
        command_id: "cmd-1",
        result_payload: %{
          "verb" => "awx.launch_job",
          "ok" => true,
          "template_id" => 42,
          "job" => %{"id" => 7331, "status" => "pending"}
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      calls = FakeActions.state().calls

      assert Enum.any?(
               calls,
               &match?({:transition_run, "run-99", :record_launching, %{awx_job_id: 7331}}, &1)
             )
    end

    test "ok=false logs and does nothing else" do
      result = %{
        command_type: "awx.launch_job",
        command_id: "cmd-1",
        result_payload: %{"verb" => "awx.launch_job", "ok" => false, "error" => "AWX HTTP 401"}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())
      assert FakeActions.state().calls == []
    end

    test "skips when run is already :launching (no double-transition)" do
      run = run_fixture(id: "run-99", state: :launching)

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
        runs_by_id: %{"run-99" => {:ok, run}}
      )

      result = %{
        command_type: "awx.launch_job",
        command_id: "cmd-1",
        result_payload: %{
          "verb" => "awx.launch_job",
          "ok" => true,
          "job" => %{"id" => 7331}
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, _, _, _}, &1)
             )
    end

    test "no-op when context is missing playbook_run_id" do
      FakeActions.configure(contexts: %{"cmd-1" => {:ok, %{"controller_id" => "ctrl-1"}}})

      result = %{
        command_type: "awx.launch_job",
        command_id: "cmd-1",
        result_payload: %{"ok" => true, "job" => %{"id" => 7331}}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, _, _, _}, &1)
             )
    end
  end

  describe "awx.fetch_job (terminal-status backstop)" do
    test "AWX status 'successful' on a still-running run → record_succeeded" do
      run = run_fixture(id: "run-99", state: :running)

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
        runs_by_id: %{"run-99" => {:ok, run}}
      )

      result = %{
        command_type: "awx.fetch_job",
        command_id: "cmd-1",
        result_payload: %{
          "verb" => "awx.fetch_job",
          "ok" => true,
          "job_id" => 7331,
          "job" => %{"id" => 7331, "status" => "successful"}
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      assert Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, "run-99", :record_succeeded, _}, &1)
             )
    end

    test "AWX status 'canceled' → record_canceled" do
      run = run_fixture(id: "run-99", state: :running)

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
        runs_by_id: %{"run-99" => {:ok, run}}
      )

      result = %{
        command_type: "awx.fetch_job",
        command_id: "cmd-1",
        result_payload: %{
          "ok" => true,
          "job" => %{"status" => "canceled"}
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      assert Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, "run-99", :record_canceled, _}, &1)
             )
    end

    test "AWX status 'failed' or 'error' → record_failed" do
      for awx_status <- ~w(failed error) do
        FakeActions.reset()
        run = run_fixture(id: "run-99", state: :running)

        FakeActions.configure(
          contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
          runs_by_id: %{"run-99" => {:ok, run}}
        )

        result = %{
          command_type: "awx.fetch_job",
          command_id: "cmd-1",
          result_payload: %{
            "ok" => true,
            "job" => %{"status" => awx_status}
          }
        }

        assert :ok = EventIngestor.handle_command_result(result, opts())

        assert Enum.any?(
                 FakeActions.state().calls,
                 &match?({:transition_run, "run-99", :record_failed, _}, &1)
               ),
               "expected record_failed for AWX status #{awx_status}"
      end
    end

    test "non-terminal AWX status (running/pending/waiting) is a no-op" do
      run = run_fixture(id: "run-99", state: :running)

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
        runs_by_id: %{"run-99" => {:ok, run}}
      )

      result = %{
        command_type: "awx.fetch_job",
        command_id: "cmd-1",
        result_payload: %{"ok" => true, "job" => %{"status" => "running"}}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, _, _, _}, &1)
             )
    end

    test "skips when run is already terminal" do
      run = run_fixture(id: "run-99", state: :succeeded)

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
        runs_by_id: %{"run-99" => {:ok, run}}
      )

      result = %{
        command_type: "awx.fetch_job",
        command_id: "cmd-1",
        result_payload: %{"ok" => true, "job" => %{"status" => "successful"}}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, _, _, _}, &1)
             )
    end
  end

  describe "awx.cancel_job" do
    test "ok=true on a running run → record_canceled" do
      run = run_fixture(id: "run-99", state: :running)

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
        runs_by_id: %{"run-99" => {:ok, run}}
      )

      result = %{
        command_type: "awx.cancel_job",
        command_id: "cmd-1",
        result_payload: %{"ok" => true, "job_id" => 7331, "status" => 202}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      assert Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, "run-99", :record_canceled, _}, &1)
             )
    end

    test "ok=true on a non-running run is a no-op" do
      run = run_fixture(id: "run-99", state: :succeeded)

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"playbook_run_id" => "run-99"}}},
        runs_by_id: %{"run-99" => {:ok, run}}
      )

      result = %{
        command_type: "awx.cancel_job",
        command_id: "cmd-1",
        result_payload: %{"ok" => true}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, _, _, _}, &1)
             )
    end

    test "ok=false logs and skips" do
      result = %{
        command_type: "awx.cancel_job",
        command_id: "cmd-1",
        result_payload: %{"ok" => false, "error" => "AWX HTTP 405"}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())
      assert FakeActions.state().calls == []
    end
  end

  describe "awx.ping" do
    test "ok=true updates controller status :ok with version + summary" do
      controller = %{id: "ctrl-1", name: "Production AWX"}

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"controller_id" => "ctrl-1"}}},
        controllers_by_id: %{"ctrl-1" => {:ok, controller}}
      )

      result = %{
        command_type: "awx.ping",
        command_id: "cmd-1",
        result_payload: %{
          "ok" => true,
          "version" => "23.5.1",
          "active_node" => "awx-1"
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      health_calls =
        Enum.filter(FakeActions.state().calls, &match?({:record_controller_health, _, _}, &1))

      assert [{:record_controller_health, "ctrl-1", args}] = health_calls
      assert args.status == :ok
      assert args.awx_version == "23.5.1"
      assert args.last_health_summary =~ "23.5.1"
      assert args.last_health_summary =~ "awx-1"
    end

    test "ok=false sets status :unreachable" do
      controller = %{id: "ctrl-1", name: "Production AWX"}

      FakeActions.configure(
        contexts: %{"cmd-1" => {:ok, %{"controller_id" => "ctrl-1"}}},
        controllers_by_id: %{"ctrl-1" => {:ok, controller}}
      )

      result = %{
        command_type: "awx.ping",
        command_id: "cmd-1",
        result_payload: %{
          "ok" => false,
          "error" => "AWX HTTP 401: authentication failed"
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      assert {:record_controller_health, "ctrl-1",
              %{status: :unreachable, awx_version: nil, last_health_summary: summary}} =
               Enum.find(
                 FakeActions.state().calls,
                 &match?({:record_controller_health, _, _}, &1)
               )

      assert summary =~ "401"
    end

    test "no-op when context is missing controller_id" do
      FakeActions.configure(contexts: %{"cmd-1" => {:ok, %{}}})

      result = %{
        command_type: "awx.ping",
        command_id: "cmd-1",
        result_payload: %{"ok" => true, "version" => "23.5.1"}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:record_controller_health, _, _}, &1)
             )
    end
  end

  describe "awx.list_templates" do
    test "upserts one Playbook per template with source_type :awx" do
      FakeActions.configure(contexts: %{"cmd-1" => {:ok, %{"controller_id" => "ctrl-1"}}})

      result = %{
        command_type: "awx.list_templates",
        command_id: "cmd-1",
        result_payload: %{
          "verb" => "awx.list_templates",
          "ok" => true,
          "count" => 2,
          "results" => [
            %{
              "id" => 42,
              "name" => "Deploy Web",
              "description" => "Deploys the web tier",
              "job_type" => "run",
              "playbook" => "deploy.yml",
              "project" => 7,
              "inventory" => 5,
              "limit" => "tag:web",
              "job_tags" => "deploy, web",
              "survey_enabled" => true,
              "ask_variables_on_launch" => true,
              "ask_credential_on_launch" => true
            },
            %{
              "id" => 43,
              "name" => "Restart DB",
              "description" => "",
              "job_type" => "run",
              "playbook" => "restart_db.yml",
              "project" => 7,
              "inventory" => 5,
              "limit" => "",
              "survey_enabled" => false
            }
          ]
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      upserts =
        Enum.filter(FakeActions.state().calls, &match?({:upsert_awx_playbook, _, _}, &1))

      assert length(upserts) == 2

      [{:upsert_awx_playbook, "ctrl-1", a1}, {:upsert_awx_playbook, "ctrl-1", a2}] = upserts

      assert a1.awx_job_template_id == 42
      assert a1.name == "Deploy Web"
      assert a1.description == "Deploys the web tier"
      assert a1.tags == ["deploy", "web"]
      assert a1.hosts_pattern == "tag:web"
      assert a1.parse_status == :ok
      assert a1.metadata["playbook"] == "deploy.yml"
      assert a1.metadata["project"] == 7
      assert a1.metadata["survey_enabled"] == true
      assert a1.metadata["ask_variables_on_launch"] == true
      assert a1.metadata["ask_credential_on_launch"] == true

      assert a2.awx_job_template_id == 43
      assert a2.name == "Restart DB"
      assert a2.tags == []
      # `limit: ""` becomes the literal empty string -- the launch UI / spec
      # validation can decide whether to coerce to nil. We don't drop it
      # here because that would lose AWX's intent.
      assert a2.hosts_pattern == ""
      assert a2.metadata["survey_enabled"] == false
      assert a2.metadata["ask_credential_on_launch"] == false
    end

    test "ok=false logs and skips" do
      FakeActions.configure(contexts: %{"cmd-1" => {:ok, %{"controller_id" => "ctrl-1"}}})

      result = %{
        command_type: "awx.list_templates",
        command_id: "cmd-1",
        result_payload: %{"ok" => false, "error" => "AWX HTTP 401"}
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:upsert_awx_playbook, _, _}, &1)
             )
    end

    test "no-op when context is missing controller_id" do
      FakeActions.configure(contexts: %{"cmd-1" => {:ok, %{}}})

      result = %{
        command_type: "awx.list_templates",
        command_id: "cmd-1",
        result_payload: %{
          "ok" => true,
          "results" => [%{"id" => 42, "name" => "x"}]
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:upsert_awx_playbook, _, _}, &1)
             )
    end

    test "skips templates with non-integer id (malformed)" do
      FakeActions.configure(contexts: %{"cmd-1" => {:ok, %{"controller_id" => "ctrl-1"}}})

      result = %{
        command_type: "awx.list_templates",
        command_id: "cmd-1",
        result_payload: %{
          "ok" => true,
          "results" => [
            %{"id" => "not-an-int", "name" => "garbage"},
            %{"id" => 99, "name" => "good"}
          ]
        }
      }

      assert :ok = EventIngestor.handle_command_result(result, opts())

      upserts =
        Enum.filter(FakeActions.state().calls, &match?({:upsert_awx_playbook, _, _}, &1))

      assert [{:upsert_awx_playbook, "ctrl-1", args}] = upserts
      assert args.awx_job_template_id == 99
    end
  end

  describe "awx.fetch_events_for_jobs: unknown run" do
    test "skips events for a run we don't recognize" do
      payload = %{
        "verb" => "awx.fetch_events_for_jobs",
        "ok" => true,
        "jobs" => [
          %{
            "job_id" => 9999,
            "ok" => true,
            "events" => [event("playbook_on_play_start", %{"counter" => 1})],
            "max_counter" => 1
          }
        ]
      }

      assert :ok =
               EventIngestor.handle_command_result(
                 %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
                 opts()
               )

      calls = FakeActions.state().calls
      assert {:get_run_by_awx_job_id, 9999} in calls
      refute Enum.any?(calls, &match?({:upsert_play, _}, &1))
    end
  end

  describe "awx.fetch_events_for_jobs: per-job failures" do
    test "logs and skips entries with ok=false" do
      payload = %{
        "jobs" => [%{"job_id" => 7331, "ok" => false, "error" => "AWX HTTP 503"}]
      }

      assert :ok =
               EventIngestor.handle_command_result(
                 %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
                 opts()
               )

      assert FakeActions.state().calls == []
    end
  end

  describe "awx.fetch_events_for_jobs: state machine transitions" do
    test "first event on a launching run drives record_running" do
      run = run_fixture(state: :launching)
      FakeActions.configure(runs_by_job_id: %{7331 => {:ok, run}})

      payload = %{
        "jobs" => [
          %{
            "job_id" => 7331,
            "ok" => true,
            "events" => [
              event("playbook_on_play_start", %{
                "counter" => 1,
                "event_data" => %{"play_uuid" => "p-1", "play" => "Deploy"}
              })
            ],
            "max_counter" => 1
          }
        ]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      calls = FakeActions.state().calls
      assert Enum.any?(calls, &match?({:transition_run, _, :record_running, _}, &1))
      assert Enum.any?(calls, &match?({:upsert_play, _}, &1))
      assert Enum.any?(calls, &match?({:advance_watermark, _, 1}, &1))
    end

    test "running run does NOT re-trigger record_running" do
      run = run_fixture(state: :running)
      FakeActions.configure(runs_by_job_id: %{7331 => {:ok, run}})

      payload = %{
        "jobs" => [
          %{
            "job_id" => 7331,
            "ok" => true,
            "events" => [
              event("playbook_on_play_start", %{
                "counter" => 5,
                "event_data" => %{"play_uuid" => "p-1"}
              })
            ],
            "max_counter" => 5
          }
        ]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      calls = FakeActions.state().calls
      refute Enum.any?(calls, &match?({:transition_run, _, :record_running, _}, &1))
    end

    test "playbook_on_stats with all hosts succeeded → record_succeeded" do
      run = run_fixture(state: :running)

      FakeActions.configure(
        runs_by_job_id: %{7331 => {:ok, run}},
        targets_by_host: %{
          "web01" => {:ok, %{id: "tgt-1", awx_host_name: "web01"}},
          "web02" => {:ok, %{id: "tgt-2", awx_host_name: "web02"}}
        }
      )

      stats_event =
        event("playbook_on_stats", %{
          "counter" => 200,
          "event_data" => %{
            "ok" => %{"web01" => 5, "web02" => 5},
            "failures" => %{},
            "dark" => %{},
            "skipped" => %{},
            "changed" => %{"web01" => 1}
          }
        })

      payload = %{
        "jobs" => [
          %{"job_id" => 7331, "ok" => true, "events" => [stats_event], "max_counter" => 200}
        ]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      assert Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, _, :record_succeeded, _}, &1)
             )

      assert Enum.count(
               FakeActions.state().calls,
               &match?({:record_target_outcome, _, _}, &1)
             ) == 2
    end

    test "playbook_on_stats with mixed outcomes → record_partial" do
      run = run_fixture(state: :running)

      FakeActions.configure(
        runs_by_job_id: %{7331 => {:ok, run}},
        targets_by_host: %{
          "web01" => {:ok, %{id: "tgt-1", awx_host_name: "web01"}},
          "web02" => {:ok, %{id: "tgt-2", awx_host_name: "web02"}}
        }
      )

      stats_event =
        event("playbook_on_stats", %{
          "counter" => 200,
          "event_data" => %{
            "ok" => %{"web01" => 5},
            "failures" => %{"web02" => 1},
            "dark" => %{},
            "skipped" => %{},
            "changed" => %{}
          }
        })

      payload = %{
        "jobs" => [
          %{"job_id" => 7331, "ok" => true, "events" => [stats_event], "max_counter" => 200}
        ]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      assert Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, _, :record_partial, _}, &1)
             )
    end

    test "playbook_on_stats with all hosts failed → record_failed" do
      run = run_fixture(state: :running)

      FakeActions.configure(
        runs_by_job_id: %{7331 => {:ok, run}},
        targets_by_host: %{
          "web01" => {:ok, %{id: "tgt-1", awx_host_name: "web01"}}
        }
      )

      stats_event =
        event("playbook_on_stats", %{
          "counter" => 200,
          "event_data" => %{
            "ok" => %{},
            "failures" => %{"web01" => 1},
            "dark" => %{},
            "skipped" => %{},
            "changed" => %{}
          }
        })

      payload = %{
        "jobs" => [
          %{"job_id" => 7331, "ok" => true, "events" => [stats_event], "max_counter" => 200}
        ]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      assert Enum.any?(
               FakeActions.state().calls,
               &match?({:transition_run, _, :record_failed, _}, &1)
             )
    end
  end

  describe "awx.fetch_events_for_jobs: runner outcomes" do
    test "runner_on_ok upserts play, task, then result attributed to the right target" do
      run = run_fixture(state: :running)
      target = %{id: "tgt-1", awx_host_name: "web01"}

      FakeActions.configure(
        runs_by_job_id: %{7331 => {:ok, run}},
        targets_by_host: %{"web01" => {:ok, target}}
      )

      ev =
        event("runner_on_ok", %{
          "counter" => 42,
          "changed" => true,
          "event_data" => %{
            "play_uuid" => "p-1",
            "task_uuid" => "t-1",
            "task" => "Install package",
            "task_action" => "ansible.builtin.apt",
            "host" => "web01",
            "play" => "Deploy",
            "res" => %{"changed" => true, "msg" => "Installed"}
          }
        })

      payload = %{
        "jobs" => [%{"job_id" => 7331, "ok" => true, "events" => [ev], "max_counter" => 42}]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      calls = FakeActions.state().calls

      assert Enum.any?(
               calls,
               &match?({:upsert_play, %{run_id: "run-1", awx_play_uuid: "p-1"}}, &1)
             )

      assert Enum.any?(
               calls,
               &match?(
                 {:upsert_task,
                  %{play_id: "play-p-1", awx_task_uuid: "t-1", action: "ansible.builtin.apt"}},
                 &1
               )
             )

      assert Enum.any?(
               calls,
               &match?(
                 {:upsert_task_result,
                  %{
                    task_id: "task-t-1",
                    run_target_id: "tgt-1",
                    awx_event_id: 42,
                    status: :ok,
                    changed: true
                  }},
                 &1
               )
             )
    end

    test "runner_on_failed maps to status :failed" do
      run = run_fixture(state: :running)

      FakeActions.configure(
        runs_by_job_id: %{7331 => {:ok, run}},
        targets_by_host: %{"web01" => {:ok, %{id: "tgt-1"}}}
      )

      ev =
        event("runner_on_failed", %{
          "counter" => 5,
          "event_data" => %{
            "play_uuid" => "p-1",
            "task_uuid" => "t-1",
            "host" => "web01"
          }
        })

      payload = %{
        "jobs" => [%{"job_id" => 7331, "ok" => true, "events" => [ev], "max_counter" => 5}]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      assert Enum.any?(
               FakeActions.state().calls,
               &match?({:upsert_task_result, %{status: :failed}}, &1)
             )
    end

    test "task-result payload keeps only numeric rc from module output" do
      run = run_fixture(state: :running)

      FakeActions.configure(
        runs_by_job_id: %{7331 => {:ok, run}},
        targets_by_host: %{"web01" => {:ok, %{id: "tgt-1"}}}
      )

      secret = "Bearer module-output-secret"

      ev =
        event("runner_on_ok", %{
          "counter" => 6,
          "event_data" => %{
            "play_uuid" => "p-1",
            "task_uuid" => "t-1",
            "host" => "web01",
            "res" => %{
              "rc" => 7,
              "msg" => secret,
              "cmd" => secret,
              "stdout" => secret,
              "stdout_lines" => [secret],
              "stderr" => secret,
              "stderr_lines" => [secret],
              "warnings" => [secret]
            }
          }
        })

      payload = %{
        "jobs" => [%{"job_id" => 7331, "ok" => true, "events" => [ev], "max_counter" => 6}]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      assert {:upsert_task_result, result} =
               Enum.find(FakeActions.state().calls, &match?({:upsert_task_result, _}, &1))

      assert result.result_payload == %{"rc" => 7}
      refute inspect(result.result_payload) =~ secret
    end

    test "runner_on_unreachable maps to status :unreachable" do
      run = run_fixture(state: :running)

      FakeActions.configure(
        runs_by_job_id: %{7331 => {:ok, run}},
        targets_by_host: %{"web01" => {:ok, %{id: "tgt-1"}}}
      )

      ev =
        event("runner_on_unreachable", %{
          "counter" => 5,
          "event_data" => %{"play_uuid" => "p-1", "task_uuid" => "t-1", "host" => "web01"}
        })

      payload = %{
        "jobs" => [%{"job_id" => 7331, "ok" => true, "events" => [ev], "max_counter" => 5}]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      assert Enum.any?(
               FakeActions.state().calls,
               &match?({:upsert_task_result, %{status: :unreachable}}, &1)
             )
    end

    test "runner result for unknown host is skipped (target lookup fails)" do
      run = run_fixture(state: :running)
      FakeActions.configure(runs_by_job_id: %{7331 => {:ok, run}})

      ev =
        event("runner_on_ok", %{
          "counter" => 5,
          "event_data" => %{
            "play_uuid" => "p-1",
            "task_uuid" => "t-1",
            "host" => "ghost-host"
          }
        })

      payload = %{
        "jobs" => [%{"job_id" => 7331, "ok" => true, "events" => [ev], "max_counter" => 5}]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:upsert_task_result, _}, &1)
             )
    end
  end

  describe "watermark advancement" do
    test "advances when max_counter exceeds run's last_event_id" do
      run = run_fixture(state: :running, last_event_id: 10)
      FakeActions.configure(runs_by_job_id: %{7331 => {:ok, run}})

      payload = %{
        "jobs" => [%{"job_id" => 7331, "ok" => true, "events" => [], "max_counter" => 25}]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      assert {:advance_watermark, "run-1", 25} in FakeActions.state().calls
    end

    test "does not advance when max_counter ≤ last_event_id (replayed batch)" do
      run = run_fixture(state: :running, last_event_id: 25)
      FakeActions.configure(runs_by_job_id: %{7331 => {:ok, run}})

      payload = %{
        "jobs" => [%{"job_id" => 7331, "ok" => true, "events" => [], "max_counter" => 25}]
      }

      EventIngestor.handle_command_result(
        %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
        opts()
      )

      refute Enum.any?(
               FakeActions.state().calls,
               &match?({:advance_watermark, _, _}, &1)
             )
    end
  end

  describe "crash safety" do
    test "exception in a handler does not propagate" do
      defmodule CrashingActions do
        @moduledoc false
        @behaviour IngestorActions

        def get_run_by_awx_job_id(_), do: raise("boom")
        def upsert_play(_), do: raise("nope")
        def upsert_task(_), do: raise("nope")
        def upsert_task_result(_), do: raise("nope")
        def get_run_target(_, _), do: raise("nope")
        def record_target_outcome(_, _), do: raise("nope")
        def advance_watermark(_, _), do: raise("nope")
        def transition_run(_, _, _), do: raise("nope")
        def get_command_context(_), do: raise("nope")
        def get_run_by_id(_), do: raise("nope")
        def get_controller_by_id(_), do: raise("nope")
        def record_controller_health(_, _), do: raise("nope")
        def upsert_awx_playbook(_, _), do: raise("nope")
        def emit_ocsf_event(_), do: raise("nope")
      end

      payload = %{"jobs" => [%{"job_id" => 1, "ok" => true, "events" => [], "max_counter" => 0}]}

      assert :ok =
               EventIngestor.handle_command_result(
                 %{command_type: "awx.fetch_events_for_jobs", result_payload: payload},
                 actions: CrashingActions
               )
    end
  end
end
