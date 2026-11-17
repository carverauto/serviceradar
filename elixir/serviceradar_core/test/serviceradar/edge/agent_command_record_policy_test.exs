defmodule ServiceRadar.Edge.AgentCommandRecordPolicyTest do
  # What a platform.agent_commands row may hold. The expected values come from
  # the stated rules: a declared camera.open_relay key keeps only scheme and
  # host, any *token/*secret/*password key is redacted unless it is a secret
  # reference, URLs lose userinfo and query, and agent free text keeps only a
  # URL's origin. All credentials below are invented.
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Edge.AgentCommandRecordPolicy

  @stream_url "rtsps://viewer:hunter2@camera01.example.com:7441/AbCdEf0123TokenXyz?enableSrtp"
  @secret_parts ["viewer", "hunter2", "AbCdEf0123TokenXyz", "enableSrtp", "lease-secret-1"]

  defp refute_secrets(value) do
    encoded = inspect(value, limit: :infinity, printable_limit: :infinity)

    for part <- @secret_parts do
      refute encoded =~ part, "#{part} survived in #{encoded}"
    end
  end

  test "camera.open_relay rows keep the camera host but not the stream URL or lease token" do
    payload = %{
      "relay_session_id" => "relay-1",
      "camera_source_id" => "camera-1",
      "source_url" => @stream_url,
      "lease_token" => "lease-secret-1"
    }

    stored = AgentCommandRecordPolicy.persisted_payload("camera.open_relay", payload)

    assert stored == %{
             "relay_session_id" => "relay-1",
             "camera_source_id" => "camera-1",
             "source_url" => "rtsps://camera01.example.com:7441/[redacted]",
             "lease_token" => "REDACTED"
           }

    context =
      AgentCommandRecordPolicy.persisted_context("camera.open_relay", %{source_url: @stream_url})

    assert context == %{source_url: "rtsps://camera01.example.com:7441/[redacted]"}

    # Re-applying the rules (the cleanup job re-runs them) changes nothing.
    assert AgentCommandRecordPolicy.persisted_payload("camera.open_relay", stored) == stored
  end

  test "a command type that declares nothing still loses secret-named keys and URL credentials" do
    ref = "secretref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

    payload = %{
      "api_token" => "plain-token-value",
      "token_ref_style" => %{"admin_password" => "plain-password"},
      "webhook_secret" => ref,
      "base_url" => "https://user:pw@awx.example.com/api/v2/job_templates/7?sig=abc",
      "enabled" => true
    }

    stored = AgentCommandRecordPolicy.persisted_payload("example.future_command", payload)

    assert stored["api_token"] == "REDACTED"
    assert stored["token_ref_style"] == %{"admin_password" => "REDACTED"}
    assert stored["webhook_secret"] == ref
    # The path stays: a structured consumer compares it; userinfo and query go.
    assert stored["base_url"] == "https://awx.example.com/api/v2/job_templates/7"
    assert stored["enabled"] == true
  end

  test "agent reports are scrubbed of URLs in message, failure_reason and payload strings" do
    report = %{
      message: "describe #{@stream_url} failed: 401",
      failure_reason: "unknown: dial #{@stream_url}",
      payload: Jason.encode!(%{"source" => @stream_url, "frames" => 0})
    }

    scrubbed = AgentCommandRecordPolicy.scrub_agent_report(report)

    assert scrubbed.message == "describe rtsps://camera01.example.com:7441 failed: 401"
    assert scrubbed.failure_reason == "unknown: dial rtsps://camera01.example.com:7441"

    assert Jason.decode!(scrubbed.payload) == %{
             "source" => "rtsps://camera01.example.com:7441/AbCdEf0123TokenXyz",
             "frames" => 0
           }

    clean = %{message: "relay started", payload: ~s({"frames":3})}
    assert AgentCommandRecordPolicy.scrub_agent_report(clean) == clean
  end

  test "a legacy row is cleaned in every column and a second pass is a no-op" do
    row = %{
      "command_type" => "camera.open_relay",
      "payload" => %{"source_url" => @stream_url, "lease_token" => "lease-secret-1"},
      "context" => %{"source_url" => @stream_url},
      "message" => "camera source failed: #{@stream_url}",
      "failure_reason" => nil,
      "result_payload" => %{"error" => "open #{@stream_url}"}
    }

    once = AgentCommandRecordPolicy.scrub_row(row)

    refute_secrets(Map.delete(once, "result_payload"))

    assert once["result_payload"] == %{
             "error" => "open rtsps://camera01.example.com:7441/AbCdEf0123TokenXyz"
           }

    assert once["failure_reason"] == nil
    assert AgentCommandRecordPolicy.scrub_row(once) == once
  end

  # Managed certificate redispatch transmits the payload read back from its
  # row, so the stored payload must be the payload the agent needs.
  test "managed certificate payloads are stored exactly as created" do
    pem =
      "-----BEGIN CERTIFICATE-----\n" <>
        Base.encode64(:binary.copy(<<0x30, 0x82, 0x01, 0x0A>>, 48)) <>
        "\n-----END CERTIFICATE-----\n"

    prepare = %{
      request_id: "11111111-2222-4333-8444-555555555555",
      component_id: "component-invented-01",
      host_agent_id: "agent-invented-01",
      partition_id: "default",
      generation: 3,
      service: "agent",
      server_hosts: ["host01.example.com", "192.0.2.10"]
    }

    install = %{
      request_id: "11111111-2222-4333-8444-555555555555",
      generation: 3,
      certificates: %{
        server: %{certificate_pem: pem, ca_chain_pem: pem},
        client: %{certificate_pem: pem, ca_chain_pem: pem}
      }
    }

    assert AgentCommandRecordPolicy.persisted_payload("certificates.prepare", prepare) == prepare
    assert AgentCommandRecordPolicy.persisted_payload("certificates.install", install) == install
  end

  test "a stored payload matches the rebuilt value it was persisted from, and nothing else" do
    expected = %{"artifact_url" => "https://files.example.com/pkg.tgz?version=1.2.3#sha"}
    stored = %{"artifact_url" => "https://files.example.com/pkg.tgz"}

    assert AgentCommandRecordPolicy.matches_persisted?(
             :payload,
             "future.command",
             stored,
             expected
           )

    refute AgentCommandRecordPolicy.matches_persisted?(
             :payload,
             "future.command",
             expected,
             stored
           )

    refute AgentCommandRecordPolicy.matches_persisted?(
             :payload,
             "future.command",
             %{"artifact_url" => "https://files.example.com/other.tgz"},
             expected
           )
  end

  # An AWX launch's args are bound to the request body the credential broker
  # authorized, so a declared non-secret URL is stored as launched. Every other
  # command type still loses a URL's userinfo, query and fragment.
  test "an AWX launch keeps its non-secret URLs whole while other types lose query and fragment" do
    url = "https://files.example.com/pkg.tgz?version=1.2.3#sha"

    launch = %{
      "args" => %{"template_id" => 42, "extra_vars" => %{"artifact_url" => url}},
      "api_token" => "invented-token-1"
    }

    stored_launch = AgentCommandRecordPolicy.persisted_payload("awx.launch_job", launch)
    assert stored_launch["args"] == launch["args"]
    assert stored_launch["api_token"] == "REDACTED"

    for command_type <- ["awx.list_recent_jobs", "future.command"] do
      stored = AgentCommandRecordPolicy.persisted_payload(command_type, launch)

      assert stored["args"]["extra_vars"]["artifact_url"] == "https://files.example.com/pkg.tgz"
    end

    assert AgentCommandRecordPolicy.persisted_payload("future.command", %{
             "link" => "https://viewer:hunter2@files.example.com/pkg.tgz"
           }) == %{"link" => "https://files.example.com/pkg.tgz"}
  end

  # The launch payload is stored whole, so userinfo must never reach it: the
  # broker scope that authorizes the launch body refuses it by input name.
  test "an AWX launch payload carrying a URL with userinfo cannot be authorized" do
    args = %{
      "template_id" => 42,
      "extra_vars" => %{"artifact_url" => "https://viewer:hunter2@files.example.com/pkg.tgz"}
    }

    assert {:error, {:credential_url_launch_input, "artifact_url"}} =
             AwxClient.broker_scope("https://awx.example.com", "awx.launch_job", args)
  end
end
