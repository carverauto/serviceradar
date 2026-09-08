defmodule ServiceRadar.Inventory.DeviceRiskIocExposureTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DeviceRiskIocExposure

  describe "process_matches_package?/3" do
    test "matches the same process and package name" do
      assert DeviceRiskIocExposure.process_matches_package?("openssl", nil, "openssl")
      assert DeviceRiskIocExposure.process_matches_package?("sudo", nil, "sudo")
    end

    test "matches common service aliases" do
      assert DeviceRiskIocExposure.process_matches_package?("sshd", nil, "openssh-server")
      assert DeviceRiskIocExposure.process_matches_package?("httpd", nil, "apache2")
    end

    test "matches a package name inside the command line" do
      assert DeviceRiskIocExposure.process_matches_package?(
               nil,
               "/usr/sbin/nginx -g daemon off;",
               "nginx"
             )
    end

    test "does not match an unrelated process" do
      refute DeviceRiskIocExposure.process_matches_package?("sshd", nil, "sudo")
      refute DeviceRiskIocExposure.process_matches_package?(nil, nil, "openssl")
      refute DeviceRiskIocExposure.process_matches_package?("sshd", nil, nil)
    end
  end

  describe "correlate/2" do
    test "joins an inbound hostile flow to the matching vulnerable package" do
      flows = [
        %{
          device_uid: "sr:host-1",
          agent_id: "agent-1",
          hostile_ip: "203.0.113.9",
          dst_ip: "10.0.0.8",
          dst_port: 22,
          comm: "sshd",
          cmdline: nil,
          observed_at: ~U[2026-08-15 12:00:00Z],
          ioc_sources: ["alienvault_otx"],
          ioc_severity: 4
        }
      ]

      findings = [
        %{
          device_uid: "sr:host-1",
          cve_id: "CVE-2024-6387",
          package: "openssh-server",
          kev: true,
          cvss: 8.1
        },
        %{
          device_uid: "sr:host-1",
          cve_id: "CVE-2025-32463",
          package: "sudo",
          kev: true,
          cvss: 7.8
        }
      ]

      assert [
               %{
                 device_uid: "sr:host-1",
                 hostile_ip: "203.0.113.9",
                 cve_id: "CVE-2024-6387",
                 package: "openssh-server",
                 dst_port: 22
               }
             ] = DeviceRiskIocExposure.correlate(flows, findings)
    end

    test "ignores a hostile flow whose process is not the vulnerable package" do
      flows = [
        %{
          device_uid: "sr:host-1",
          agent_id: "agent-1",
          hostile_ip: "203.0.113.9",
          dst_ip: "10.0.0.8",
          dst_port: 443,
          comm: "nginx",
          cmdline: nil,
          observed_at: ~U[2026-08-15 12:00:00Z],
          ioc_sources: ["alienvault_otx"],
          ioc_severity: 4
        }
      ]

      findings = [
        %{
          device_uid: "sr:host-1",
          cve_id: "CVE-2025-32463",
          package: "sudo",
          kev: true,
          cvss: 7.8
        }
      ]

      assert DeviceRiskIocExposure.correlate(flows, findings) == []
    end
  end

  describe "evaluate/1" do
    test "writes a max score, event, and alert for a new hit" do
      parent = self()

      hit = %{
        device_uid: "sr:host-1",
        agent_id: "agent-1",
        hostile_ip: "203.0.113.9",
        dst_ip: "10.0.0.8",
        dst_port: 22,
        comm: "sshd",
        cmdline: nil,
        observed_at: ~U[2026-08-15 12:00:00Z],
        ioc_sources: ["alienvault_otx"],
        ioc_severity: 4,
        cve_id: "CVE-2024-6387",
        package: "openssh-server",
        kev: true,
        cvss: 8.1
      }

      assert {:ok, %{devices: 1, hits: 1, events: 1, alerts: 1, resolved: 0}} =
               DeviceRiskIocExposure.evaluate(
                 hits: [hit],
                 query_active_contribution_uids: fn -> [] end,
                 open_alert?: fn _source_id -> false end,
                 upsert_contribution: fn contribution, _opts ->
                   send(parent, {:score, contribution})
                   :ok
                 end,
                 emit_event: fn payload ->
                   send(parent, {:event, payload})
                   :ok
                 end,
                 create_alert: fn attrs ->
                   send(parent, {:alert, attrs})
                   {:ok, %{id: "alert-1"}}
                 end
               )

      assert_received {:score,
                       %{
                         device_uid: "sr:host-1",
                         source: "hostile_ioc_vulnerable_service",
                         score: 100,
                         active: true
                       }}

      assert_received {:event,
                       %{
                         "event_type" => "hostile_ioc_vulnerable_service",
                         "hostile_ip" => "203.0.113.9",
                         "cve" => "CVE-2024-6387",
                         "severity_id" => 5
                       }}

      assert_received {:alert,
                       %{
                         severity: :critical,
                         device_uid: "sr:host-1",
                         source_id: "hostile-ioc-vuln:sr:host-1:203.0.113.9:CVE-2024-6387"
                       }}
    end

    test "does not re-alert when an open alert already exists" do
      parent = self()

      hit = %{
        device_uid: "sr:host-1",
        agent_id: "agent-1",
        hostile_ip: "203.0.113.9",
        dst_ip: "10.0.0.8",
        dst_port: 22,
        comm: "sshd",
        cmdline: nil,
        observed_at: ~U[2026-08-15 12:00:00Z],
        ioc_sources: ["alienvault_otx"],
        ioc_severity: 4,
        cve_id: "CVE-2024-6387",
        package: "openssh-server",
        kev: true,
        cvss: 8.1
      }

      assert {:ok, %{events: 0, alerts: 0, devices: 1}} =
               DeviceRiskIocExposure.evaluate(
                 hits: [hit],
                 query_active_contribution_uids: fn -> ["sr:host-1"] end,
                 open_alert?: fn _source_id -> true end,
                 upsert_contribution: fn contribution, _opts ->
                   send(parent, {:score, contribution.score})
                   :ok
                 end,
                 emit_event: fn _payload ->
                   send(parent, :event)
                   :ok
                 end,
                 create_alert: fn _attrs ->
                   send(parent, :alert)
                   {:ok, %{}}
                 end
               )

      assert_received {:score, 100}
      refute_received :event
      refute_received :alert
    end

    test "clears the max-score contribution when the hit is gone" do
      parent = self()

      assert {:ok, %{devices: 0, resolved: 1}} =
               DeviceRiskIocExposure.evaluate(
                 hits: [],
                 query_active_contribution_uids: fn -> ["sr:host-1"] end,
                 upsert_contribution: fn contribution, _opts ->
                   send(parent, {:score, contribution})
                   :ok
                 end
               )

      assert_received {:score,
                       %{
                         device_uid: "sr:host-1",
                         score: 0,
                         active: false
                       }}
    end
  end
end
