defmodule ServiceRadar.Automation.Ansible.AutomationResultSanitizerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationResultSanitizer

  @command_id "019f4a9c-cf95-77e5-9dd5-cb84c710fb8e"
  @agent_id "edge-agent-1"
  @partition_id "farm01"
  @dispatch_id "019f4a9c-de99-7f85-bc2e-3f193f6cda2c"
  @snapshot_digest String.duplicate("a", 64)
  @scm_revision String.duplicate("b", 40)

  test "non-AWX results are unchanged" do
    data = %{command_type: "mtr.run", payload: %{"arbitrary" => "value"}}
    assert AutomationResultSanitizer.sanitize(data) == data
  end

  test "every awx-prefixed result, acknowledgement, and progress update is protected" do
    secret = "Bearer future-verb-secret"

    data = %{
      command_id: @command_id,
      command_type: "awx.future_controller_verb",
      agent_id: @agent_id,
      partition_id: @partition_id,
      success: true,
      message: secret,
      failure_reason: secret,
      progress_percent: 50,
      payload: %{"variables" => secret, "stdout" => secret}
    }

    result = AutomationResultSanitizer.sanitize(data)
    ack = AutomationResultSanitizer.sanitize_ack(data)
    progress = AutomationResultSanitizer.sanitize_progress(data)

    assert result.success == false
    assert result.failure_reason == "invalid_automation_result"
    assert result.payload == %{"verb" => "awx.future_controller_verb", "ok" => false}
    assert ack.message == "automation command acknowledged"
    assert progress.message == "automation command in progress"
    assert progress.payload == %{}
    refute inspect([result, ack, progress]) =~ secret

    poisoned = %{data | command_type: "awx.Bearer-#{secret}"}
    poisoned_result = AutomationResultSanitizer.sanitize(poisoned)
    poisoned_ack = AutomationResultSanitizer.sanitize_ack(poisoned)

    assert poisoned_result.command_type == "awx.invalid"
    assert poisoned_result.payload == %{"verb" => "awx.invalid", "ok" => false}
    assert poisoned_ack.command_type == "awx.invalid"
    refute inspect([poisoned_result, poisoned_ack]) =~ secret
  end

  test "protected acknowledgements and progress discard agent text and payloads" do
    secret = "Bearer progress-must-not-survive"

    data = %{
      command_id: @command_id,
      command_type: "awx.fetch_job",
      agent_id: @agent_id,
      partition_id: "default",
      message: secret,
      progress_percent: 25,
      payload: %{"details" => secret}
    }

    ack = AutomationResultSanitizer.sanitize_ack(data)
    progress = AutomationResultSanitizer.sanitize_progress(data)

    assert ack.message == "automation command acknowledged"
    assert progress.message == "automation command in progress"
    assert progress.progress_percent == 25
    assert progress.payload == %{}
    refute inspect([ack, progress]) =~ secret
  end

  test "failed protected results retain no agent text or payload" do
    secret = "Bearer secret-that-must-not-survive"

    safe =
      AutomationResultSanitizer.sanitize(%{
        command_id: @command_id,
        command_type: "awx.launch_job",
        agent_id: @agent_id,
        partition_id: @partition_id,
        success: false,
        message: secret,
        failure_reason: {:http_error, secret},
        payload: %{"details" => secret, "raw_result_base64" => Base.encode64(secret)}
      })

    assert safe == %{
             command_id: @command_id,
             command_type: "awx.launch_job",
             agent_id: @agent_id,
             partition_id: @partition_id,
             success: false,
             message: "automation command failed",
             failure_reason: "automation_command_failed",
             payload: %{"verb" => "awx.launch_job", "ok" => false}
           }

    refute inspect(safe) =~ secret
  end

  test "malformed successful results collapse to a fixed failure" do
    safe =
      AutomationResultSanitizer.sanitize(%{
        command_id: @command_id,
        command_type: "awx.fetch_job",
        agent_id: @agent_id,
        partition_id: @partition_id,
        success: true,
        message: "secret",
        payload: %{"raw_result_base64" => "c2VjcmV0"}
      })

    assert safe.success == false
    assert safe.failure_reason == "invalid_automation_result"
    assert safe.payload == %{"verb" => "awx.fetch_job", "ok" => false}
    refute inspect(safe) =~ "c2VjcmV0"
  end

  test "template catalog retains the exact credential launch prompt" do
    template = %{
      "id" => 78,
      "name" => "Install Agent",
      "job_type" => "run",
      "survey_enabled" => false,
      "ask_variables_on_launch" => false,
      "ask_inventory_on_launch" => false,
      "ask_limit_on_launch" => true,
      "ask_credential_on_launch" => true
    }

    payload = %{
      "verb" => "awx.list_templates",
      "ok" => true,
      "count" => 1,
      "pages_walked" => 1,
      "results" => [Map.put(template, "variables", "Bearer secret")]
    }

    safe = AutomationResultSanitizer.sanitize(result("awx.list_templates", payload))
    assert safe.success == true
    assert hd(safe.payload["results"])["ask_credential_on_launch"] == true
    refute inspect(safe) =~ "Bearer secret"

    malformed = put_in(payload["results"], [Map.delete(template, "ask_credential_on_launch")])
    rejected = AutomationResultSanitizer.sanitize(result("awx.list_templates", malformed))
    assert rejected.success == false
  end

  test "launch evidence is projected to the exact lifecycle fields" do
    payload = %{
      "verb" => "awx.launch_job",
      "ok" => true,
      "template_id" => 78,
      "job" => Map.put(valid_job(), "untrusted_detail", "Bearer secret")
    }

    safe = AutomationResultSanitizer.sanitize(result("awx.launch_job", payload))

    assert safe.success == true
    assert safe.message == "automation command completed"
    assert safe.failure_reason == nil
    assert safe.payload["template_id"] == 78
    assert safe.payload["job"]["id"] == 357
    refute Map.has_key?(safe.payload["job"], "untrusted_detail")
    refute inspect(safe) =~ "Bearer secret"
  end

  test "launch evidence accepts pending jobs without scm revision or dispatch markers" do
    # Real AWX launch responses often have empty scm_revision before checkout,
    # and omit dispatch_markers when the template ignores request extra_vars.
    job =
      valid_job()
      |> Map.put("scm_revision", "")
      |> Map.delete("dispatch_markers")

    payload = %{
      "verb" => "awx.launch_job",
      "ok" => true,
      "template_id" => 78,
      "job" => job
    }

    safe = AutomationResultSanitizer.sanitize(result("awx.launch_job", payload))

    assert safe.success == true
    assert safe.payload["job"]["id"] == 357
    assert safe.payload["job"]["scm_revision"] == ""
    assert safe.payload["job"]["dispatch_markers"] == %{}
  end

  test "recent-job results are bounded and recursively projected" do
    payload = %{
      "verb" => "awx.list_recent_jobs",
      "ok" => true,
      "template_id" => 78,
      "inventory_id" => 67,
      "created_by_id" => 3,
      "created_after" => "2026-07-13T06:00:00Z",
      "page_size" => 50,
      "max_candidates" => 5_000,
      "count" => 1,
      "complete" => true,
      "jobs" => [Map.put(valid_job(), "artifacts", %{"token" => "secret"})]
    }

    safe = AutomationResultSanitizer.sanitize(result("awx.list_recent_jobs", payload))

    assert safe.success == true
    assert length(safe.payload["jobs"]) == 1
    refute Map.has_key?(hd(safe.payload["jobs"]), "artifacts")
    refute inspect(safe) =~ "secret"
  end

  test "callback provenance reads retain only exact secret-free credential scope" do
    name = "sr-callback-018f3f56-1111-7222-8333-123456789abc"

    credential = %{
      "id" => 401,
      "name" => name,
      "credential_type_id" => 91,
      "organization_id" => 2
    }

    verify =
      AutomationResultSanitizer.sanitize(
        result("awx.verify_callback_credential", %{
          "verb" => "awx.verify_callback_credential",
          "ok" => true,
          "credential_id" => 401,
          "credential" => credential
        })
      )

    assert verify.success == true
    assert verify.command_type == "awx.verify_callback_credential"
    assert verify.payload["credential"] == credential

    listed =
      AutomationResultSanitizer.sanitize(
        result("awx.list_callback_credentials", %{
          "verb" => "awx.list_callback_credentials",
          "ok" => true,
          "credential_type_id" => 91,
          "organization_id" => 2,
          "credential_name" => name,
          "max_credentials" => 5_000,
          "count" => 1,
          "complete" => true,
          "credentials" => [credential]
        })
      )

    assert listed.success == true
    assert listed.command_type == "awx.list_callback_credentials"
    assert listed.payload["credentials"] == [credential]
  end

  test "host summaries retain only exact identifiers, literal names, and counters" do
    summary =
      Map.merge(
        %{
          "summary_id" => 901,
          "job_id" => 357,
          "host_id" => 81,
          "constructed_host_id" => nil,
          "host_name" => "sr-win-test01",
          "failed" => false,
          "private_data" => "secret"
        },
        Map.new(~w(changed dark failures ok processed skipped ignored rescued), &{&1, 0})
      )

    payload = %{
      "verb" => "awx.fetch_job_host_summaries",
      "ok" => true,
      "job_id" => 357,
      "count" => 1,
      "summaries" => [summary]
    }

    safe =
      AutomationResultSanitizer.sanitize(result("awx.fetch_job_host_summaries", payload))

    assert safe.success == true
    [stored] = safe.payload["summaries"]
    assert stored["host_id"] == 81
    assert stored["host_name"] == "sr-win-test01"
    refute Map.has_key?(stored, "private_data")
    refute Map.has_key?(stored, "constructed_host_id")
  end

  test "callback credential results retain identifiers but never injected inputs" do
    payload = %{
      "verb" => "awx.create_callback_credential",
      "ok" => true,
      "credential_id" => 401,
      "credential_type_id" => 91,
      "organization_id" => 3,
      "credential_name" => "sr-callback-019f4a9c-cf95-77e5-9dd5-cb84c710fb8e",
      "injector_sha256" => @snapshot_digest
    }

    safe =
      AutomationResultSanitizer.sanitize(result("awx.create_callback_credential", payload))

    assert safe.success == true
    assert safe.payload == payload

    unsafe = put_in(payload["inputs"], %{"callback_grant" => "secret"})

    rejected =
      AutomationResultSanitizer.sanitize(result("awx.create_callback_credential", unsafe))

    assert rejected.success == false
    refute inspect(rejected) =~ "secret"
  end

  test "top-level payload keys must normalize uniquely and safely" do
    payload = %{
      "verb" => "awx.cancel_job",
      "ok" => false,
      :ok => true,
      "job_id" => 357,
      "status" => 202
    }

    duplicate = AutomationResultSanitizer.sanitize(result("awx.cancel_job", payload))

    assert duplicate.success == false
    assert duplicate.failure_reason == "invalid_automation_result"

    malformed =
      payload
      |> Map.delete(:ok)
      |> Map.put({:unexpected, :key}, "Bearer secret")
      |> then(&AutomationResultSanitizer.sanitize(result("awx.cancel_job", &1)))

    assert malformed.success == false
    refute inspect(malformed) =~ "Bearer secret"
  end

  test "cleanup results preserve only the bounded cleanup proof" do
    delete = %{
      "verb" => "awx.delete_callback_credential",
      "ok" => true,
      "credential_id" => 401,
      "credential_type_id" => 91,
      "cleanup_status" => "deleted"
    }

    cancel = %{
      "verb" => "awx.cancel_job",
      "ok" => true,
      "job_id" => 357,
      "status" => 202
    }

    assert AutomationResultSanitizer.sanitize(result("awx.delete_callback_credential", delete)).payload ==
             delete

    assert AutomationResultSanitizer.sanitize(result("awx.cancel_job", cancel)).payload == cancel
  end

  test "host names and limits must use hardened literal-token grammar" do
    payload = %{
      "verb" => "awx.fetch_job",
      "ok" => true,
      "job_id" => 357,
      "job" => Map.put(valid_job(), "limit", "host01:&malicious")
    }

    safe = AutomationResultSanitizer.sanitize(result("awx.fetch_job", payload))
    assert safe.success == false
    assert safe.failure_reason == "invalid_automation_result"
  end

  test "aggregate budget also applies to lifecycle result projections" do
    summaries =
      Enum.map(1..10_000, fn index ->
        %{
          "summary_id" => index,
          "job_id" => 357,
          "host_id" => index,
          "host_name" => "host#{index}-#{String.duplicate("x", 230)}",
          "failed" => false,
          "changed" => 0,
          "dark" => 0,
          "failures" => 0,
          "ok" => 1,
          "processed" => 1,
          "skipped" => 0,
          "ignored" => 0,
          "rescued" => 0
        }
      end)

    payload = %{
      "verb" => "awx.fetch_job_host_summaries",
      "ok" => true,
      "job_id" => 357,
      "count" => length(summaries),
      "summaries" => summaries
    }

    safe = AutomationResultSanitizer.sanitize(result("awx.fetch_job_host_summaries", payload))
    assert safe.success == false
    assert safe.failure_reason == "invalid_automation_result"
    assert safe.payload == %{"verb" => "awx.fetch_job_host_summaries", "ok" => false}
  end

  test "syntactically valid identifiers are not rejected for secret-like words" do
    job =
      valid_job()
      |> Map.put("limit", "secret-scanner")
      |> Map.put("credentials", [%{"id" => 70, "kind" => "token-ring"}])

    payload = %{
      "verb" => "awx.fetch_job",
      "ok" => true,
      "job_id" => 357,
      "job" => job
    }

    safe =
      "awx.fetch_job"
      |> result(payload)
      |> Map.put(:agent_id, "token-ring-edge")
      |> AutomationResultSanitizer.sanitize()

    assert safe.success == true
    assert safe.agent_id == "token-ring-edge"
    assert safe.payload["job"]["limit"] == "secret-scanner"
    assert safe.payload["job"]["credentials"] == [%{"id" => 70, "kind" => "token-ring"}]
  end

  defp result(command_type, payload) do
    %{
      command_id: @command_id,
      command_type: command_type,
      agent_id: @agent_id,
      partition_id: @partition_id,
      success: true,
      message: "agent-controlled message",
      payload: payload
    }
  end

  defp valid_job do
    %{
      "id" => 357,
      "status" => "running",
      "created" => "2026-07-13T06:00:00Z",
      "job_template" => 78,
      "inventory" => 67,
      "project" => 76,
      "scm_revision" => @scm_revision,
      "execution_environment" => 5,
      "job_type" => "run",
      "job_slice_count" => 1,
      "job_slice_number" => 0,
      "limit" => "sr-win-test01",
      "launched_by" => %{"id" => 3, "type" => "user"},
      "credentials" => [%{"id" => 70, "kind" => "ssh", "name" => "redacted"}],
      "dispatch_markers" => %{
        "serviceradar_dispatch_id" => @dispatch_id,
        "serviceradar_snapshot_digest" => @snapshot_digest
      }
    }
  end
end
