defmodule ServiceRadar.Automation.Ansible.AWXResultProjectionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AWXResultProjection

  @play_uuid "019f4a9c-cf95-77e5-9dd5-cb84c710fb8e"
  @task_uuid "019f4a9c-de99-7f85-bc2e-3f193f6cda2c"
  @sentinel "Bearer sentinel-secret-must-not-survive"

  test "ping and current-user results retain only bounded public identity" do
    assert {:ok,
            %{
              "verb" => "awx.ping",
              "ok" => true,
              "version" => "24.6.1",
              "active_node" => "awx-task-0"
            }} =
             AWXResultProjection.project("awx.ping", %{
               "verb" => "awx.ping",
               "ok" => true,
               "version" => "24.6.1",
               "active_node" => "awx-task-0",
               "install_uuid" => @play_uuid,
               "ha" => false,
               "instances" => [],
               "groups" => []
             })

    assert {:ok,
            %{
              "verb" => "awx.current_user",
              "ok" => true,
              "user_id" => 3,
              "username" => "sr-awx-exec"
            }} =
             AWXResultProjection.project("awx.current_user", %{
               "verb" => "awx.current_user",
               "ok" => true,
               "user_id" => 3,
               "username" => "sr-awx-exec"
             })

    assert :error =
             AWXResultProjection.project(
               "awx.ping",
               Map.put(ping_payload(), "unexpected_secret", @sentinel)
             )

    assert :error =
             AWXResultProjection.project(
               "awx.ping",
               Map.put(ping_payload(), "active_node", "awx-task-0\u202Ehidden")
             )
  end

  test "inventory, host, group, and project lists rebuild safe rows" do
    inventories =
      list_payload("awx.list_inventories", [
        %{
          "id" => 67,
          "name" => "ServiceRadar Windows Lab",
          "kind" => "",
          "organization" => 1,
          "total_hosts" => 1,
          "variables" => %{"api_token" => @sentinel},
          "related" => %{"hosts" => "https://awx.invalid/?token=#{@sentinel}"}
        }
      ])

    assert {:ok, safe_inventories} =
             AWXResultProjection.project("awx.list_inventories", inventories)

    [inventory] = safe_inventories["results"]

    assert inventory == %{
             "id" => 67,
             "name" => "ServiceRadar Windows Lab",
             "kind" => "",
             "organization" => 1,
             "total_hosts" => 1
           }

    refute inspect(safe_inventories) =~ @sentinel

    hosts =
      list_payload(
        "awx.list_hosts",
        [
          %{
            "id" => 81,
            "name" => "sr-win-test01",
            "inventory" => 67,
            "enabled" => true,
            "variables" => "ansible_password: #{@sentinel}",
            "summary_fields" => %{"credential" => @sentinel}
          }
        ],
        %{"inventory_id" => 67}
      )

    assert {:ok, safe_hosts} = AWXResultProjection.project("awx.list_hosts", hosts)

    assert safe_hosts["results"] == [
             %{"id" => 81, "name" => "sr-win-test01", "inventory" => 67, "enabled" => true}
           ]

    refute inspect(safe_hosts) =~ @sentinel

    groups =
      list_payload(
        "awx.list_inventory_groups",
        [%{"id" => 9, "name" => "windows", "variables" => @sentinel}],
        %{"inventory_id" => 67}
      )

    assert {:ok, safe_groups} =
             AWXResultProjection.project("awx.list_inventory_groups", groups)

    assert safe_groups["results"] == [%{"id" => 9, "name" => "windows"}]

    projects =
      list_payload("awx.list_projects", [
        %{
          "id" => 76,
          "name" => "ServiceRadar Ansible",
          "organization" => 1,
          "status" => "successful",
          "scm_type" => "git",
          "scm_revision" => String.duplicate("a", 40),
          "scm_update_on_launch" => false,
          "scm_url" => "https://user:#{@sentinel}@git.invalid/repo",
          "credential" => @sentinel
        }
      ])

    assert {:ok, safe_projects} = AWXResultProjection.project("awx.list_projects", projects)
    [project] = safe_projects["results"]
    refute Map.has_key?(project, "scm_url")
    refute Map.has_key?(project, "credential")
    refute inspect(safe_projects) =~ @sentinel
  end

  test "list envelopes require exact bounded counts and page evidence" do
    assert :error =
             AWXResultProjection.project(
               "awx.list_inventories",
               "awx.list_inventories" |> list_payload([]) |> Map.put("count", 1)
             )

    assert :error =
             AWXResultProjection.project(
               "awx.list_inventories",
               "awx.list_inventories" |> list_payload([]) |> Map.put("pages_walked", 1)
             )

    assert :error =
             AWXResultProjection.project(
               "awx.list_hosts",
               list_payload("awx.list_hosts", [], %{"inventory_id" => 67, "secret" => @sentinel})
             )

    for unsafe_name <- ["inventory\tname", "inventory\e[31m", "inventory\u202Ename"] do
      row = %{
        "id" => 67,
        "name" => unsafe_name,
        "kind" => "",
        "organization" => 1,
        "total_hosts" => 1
      }

      assert :error =
               AWXResultProjection.project(
                 "awx.list_inventories",
                 list_payload("awx.list_inventories", [row])
               )
    end
  end

  test "template rows drop variables and extra-vars without losing catalog fields" do
    templates =
      list_payload("awx.list_templates", [
        valid_template()
        |> Map.put("variables", "api_token: #{@sentinel}")
        |> Map.put("extra_vars", %{"password" => @sentinel})
        |> Map.put("credentials", [%{"inputs" => @sentinel}])
        |> Map.put("related", %{"survey_spec" => @sentinel})
      ])

    assert {:ok, safe} = AWXResultProjection.project("awx.list_templates", templates)

    assert safe["results"] == [valid_template()]
    refute inspect(safe) =~ @sentinel

    missing_prompt =
      list_payload("awx.list_templates", [
        Map.delete(valid_template(), "ask_credential_on_launch")
      ])

    assert :error = AWXResultProjection.project("awx.list_templates", missing_prompt)
  end

  test "fetch-template removes survey defaults and rejects non-public variables" do
    payload = %{
      "verb" => "awx.fetch_template",
      "ok" => true,
      "template_id" => 78,
      "template" =>
        valid_template()
        |> Map.put("variables", "authorization: #{@sentinel}")
        |> Map.put("extra_vars", %{"secret" => @sentinel}),
      "survey_spec" => %{
        "spec" => [
          %{
            "variable" => "package_version",
            "question_name" => "Package version",
            "question_description" => "Version to install",
            "type" => "text",
            "required" => true,
            "choices" => "",
            "min" => nil,
            "max" => nil,
            "default" => @sentinel
          }
        ]
      }
    }

    assert {:ok, safe} = AWXResultProjection.project("awx.fetch_template", payload)
    [field] = safe["survey_spec"]["spec"]
    refute Map.has_key?(field, "default")
    refute inspect(safe) =~ @sentinel

    for variable <- [
          "password",
          "api_token",
          "ansible_password",
          "inventory_hostname",
          "callback_url"
        ] do
      rejected = put_in(payload, ["survey_spec", "spec", Access.at(0), "variable"], variable)
      assert :error = AWXResultProjection.project("awx.fetch_template", rejected)
    end

    password = put_in(payload, ["survey_spec", "spec", Access.at(0), "type"], "password")
    assert :error = AWXResultProjection.project("awx.fetch_template", password)
  end

  test "fetch-template projects only exact dispatcher-owned marker survey fields" do
    marker_fields = [
      %{
        "variable" => "serviceradar_dispatch_id",
        "question_name" => "ServiceRadar dispatch ID",
        "question_description" => "Injected by ServiceRadar",
        "type" => "text",
        "required" => true,
        "choices" => "",
        "min" => 36,
        "max" => 36,
        "default" => ""
      },
      %{
        "variable" => "serviceradar_snapshot_digest",
        "question_name" => "ServiceRadar snapshot digest",
        "type" => "text",
        "required" => true,
        "choices" => "",
        "min" => 64,
        "max" => 64,
        "default" => nil
      }
    ]

    payload = %{
      "verb" => "awx.fetch_template",
      "ok" => true,
      "template_id" => 78,
      "template" =>
        valid_template()
        |> Map.put("survey_enabled", true)
        |> Map.put("ask_variables_on_launch", false),
      "survey_spec" => %{"spec" => marker_fields}
    }

    assert {:ok, safe} = AWXResultProjection.project("awx.fetch_template", payload)

    assert Enum.map(safe["survey_spec"]["spec"], & &1["variable"]) == [
             "serviceradar_dispatch_id",
             "serviceradar_snapshot_digest"
           ]

    refute inspect(safe) =~ "default"

    for invalid <- [
          put_in(payload, ["survey_spec", "spec", Access.at(0), "required"], false),
          put_in(payload, ["survey_spec", "spec", Access.at(0), "max"], 128),
          put_in(
            payload,
            ["survey_spec", "spec", Access.at(1), "default"],
            "operator-controlled"
          )
        ] do
      assert :error = AWXResultProjection.project("awx.fetch_template", invalid)
    end
  end

  test "aggregate projection budget rejects individually valid oversized surveys" do
    choice = String.duplicate("x", 400)

    fields =
      Enum.map(1..100, fn index ->
        %{
          "variable" => "package_choice_#{index}",
          "question_name" => "Package choice #{index}",
          "type" => "multiplechoice",
          "required" => true,
          "choices" => List.duplicate(choice, 100)
        }
      end)

    payload = %{
      "verb" => "awx.fetch_template",
      "ok" => true,
      "template_id" => 78,
      "template" => valid_template(),
      "survey_spec" => %{"spec" => fields}
    }

    assert :error = AWXResultProjection.project("awx.fetch_template", payload)
  end

  test "event batches retain only structural event data and numeric rc" do
    event = %{
      "event" => "runner_on_ok",
      "counter" => 7,
      "created" => "2026-07-13T06:00:00Z",
      "failed" => false,
      "changed" => true,
      "stdout" => @sentinel,
      "event_data" => %{
        "play_uuid" => @play_uuid,
        "task_uuid" => @task_uuid,
        "play" => "Provision Linux",
        "task" => "Install package",
        "task_action" => "ansible.builtin.package",
        "host" => "linux01",
        "ignore_errors" => false,
        "res" => %{
          "rc" => 0,
          "msg" => @sentinel,
          "cmd" => "curl -H 'Authorization: #{@sentinel}'",
          "stdout" => @sentinel,
          "stdout_lines" => [@sentinel],
          "stderr" => @sentinel,
          "stderr_lines" => [@sentinel],
          "warnings" => [@sentinel]
        }
      }
    }

    payload = %{
      "verb" => "awx.fetch_events_for_jobs",
      "ok" => true,
      "contract_version" => 2,
      "jobs" => [
        %{
          "job_id" => 357,
          "ok" => true,
          "events" => [event],
          "max_counter" => 7,
          "count" => 1
        }
      ]
    }

    assert {:ok, safe} = AWXResultProjection.project("awx.fetch_events_for_jobs", payload)
    assert safe["contract_version"] == 2
    [safe_event] = get_in(safe, ["jobs", Access.at(0), "events"])
    assert get_in(safe_event, ["event_data", "res"]) == %{"rc" => 0}
    refute Map.has_key?(safe_event, "stdout")
    refute inspect(safe) =~ @sentinel
  end

  test "event batches reject inconsistent counters and declared counts" do
    event = %{
      "event" => "playbook_on_play_start",
      "counter" => 8,
      "failed" => false,
      "changed" => false,
      "event_data" => %{"play_uuid" => @play_uuid, "play" => "Provision"}
    }

    payload = %{
      "verb" => "awx.fetch_events_for_jobs",
      "ok" => true,
      "contract_version" => 2,
      "jobs" => [
        %{
          "job_id" => 357,
          "ok" => true,
          "events" => [event],
          "max_counter" => 7,
          "count" => 1
        }
      ]
    }

    assert :error = AWXResultProjection.project("awx.fetch_events_for_jobs", payload)

    assert :error =
             AWXResultProjection.project(
               "awx.fetch_events_for_jobs",
               put_in(payload, ["jobs", Access.at(0), "count"], 0)
             )

    duplicated_job =
      payload
      |> put_in(["jobs", Access.at(0), "max_counter"], 8)
      |> then(&Map.put(&1, "jobs", &1["jobs"] ++ &1["jobs"]))

    assert :error =
             AWXResultProjection.project("awx.fetch_events_for_jobs", duplicated_job)

    assert :error =
             AWXResultProjection.project("awx.fetch_events_for_jobs", %{
               "verb" => "awx.fetch_events_for_jobs",
               "ok" => true,
               "contract_version" => 2,
               "jobs" => []
             })
  end

  test "legacy v0.1.5 event results are narrowly projected into bounded v2 windows" do
    unknown = %{"event" => "verbose", "counter" => 1, "event_data" => %{"secret" => @sentinel}}

    handled =
      Enum.map(2..13, fn counter ->
        %{
          "event" => "playbook_on_play_start",
          "counter" => counter,
          "stdout" => @sentinel,
          "event_data" => %{
            "play_uuid" => @play_uuid,
            "play" => "Provision #{counter}",
            "secret" => @sentinel
          }
        }
      end)

    payload = %{
      "verb" => "awx.fetch_events_for_jobs",
      "ok" => true,
      "jobs" => [
        %{
          "job_id" => 357,
          "ok" => true,
          "events" => [unknown | handled],
          "max_counter" => 13,
          "count" => 13
        },
        %{
          "job_id" => 358,
          "ok" => true,
          "events" => nil,
          "max_counter" => 44,
          "count" => 0
        },
        %{
          "job_id" => 359,
          "ok" => false,
          "error" => "GET https://awx.invalid/?token=#{@sentinel}",
          "events" => nil,
          "max_counter" => 0,
          "count" => 0
        }
      ]
    }

    assert {:ok, safe} = AWXResultProjection.project("awx.fetch_events_for_jobs", payload)
    assert safe["contract_version"] == 2

    [window, idle, failed] = safe["jobs"]
    assert window["count"] == 10
    assert window["max_counter"] == 11
    assert Enum.map(window["events"], & &1["counter"]) == Enum.to_list(2..11)

    assert idle == %{
             "job_id" => 358,
             "ok" => true,
             "events" => [],
             "max_counter" => 44,
             "count" => 0
           }

    assert failed == %{
             "job_id" => 359,
             "ok" => false,
             "error" => "awx_event_fetch_failed",
             "events" => [],
             "max_counter" => 0,
             "count" => 0
           }

    refute inspect(safe) =~ @sentinel
  end

  defp list_payload(verb, results, extra \\ nil) do
    payload = %{
      "verb" => verb,
      "ok" => true,
      "count" => length(results),
      "pages_walked" => if(results == [], do: 0, else: 1),
      "results" => results
    }

    if is_nil(extra), do: payload, else: Map.put(payload, "extra", extra)
  end

  defp valid_template do
    %{
      "id" => 78,
      "name" => "Install QEMU Guest Agent",
      "description" => "Installs the guest agent",
      "job_tags" => "proxmox,windows",
      "limit" => "",
      "job_type" => "run",
      "playbook" => "install-qemu-guest-agent-windows.yml",
      "project" => 76,
      "inventory" => 67,
      "survey_enabled" => true,
      "ask_variables_on_launch" => true,
      "ask_inventory_on_launch" => false,
      "ask_limit_on_launch" => true,
      "ask_credential_on_launch" => true
    }
  end

  defp ping_payload do
    %{
      "verb" => "awx.ping",
      "ok" => true,
      "version" => "24.6.1",
      "active_node" => "awx-task-0",
      "install_uuid" => @play_uuid,
      "ha" => false,
      "instances" => [],
      "groups" => []
    }
  end
end
