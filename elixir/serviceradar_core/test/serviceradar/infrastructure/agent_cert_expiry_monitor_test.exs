defmodule ServiceRadar.Infrastructure.AgentCertExpiryMonitorTest do
  @moduledoc """
  Verifies peer certificate lifecycle persistence on `ServiceRadar.Infrastructure.Agent`
  and `ServiceRadar.Infrastructure.AgentCertExpiryMonitor` alert evaluation:
  - `0 < cert_expires_at - now <= 14d` (> 7d) raises `:warning` (`expiring_soon`)
  - `0 < cert_expires_at - now <= 7d` raises `:critical` (`expiring_soon`)
  - `cert_expires_at <= now` raises `:critical` (`expired`)
  - `cert_expires_at - now > 14d` resolves any active certificate expiry alert
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.AgentCertExpiryMonitor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Monitoring.Alert

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    uniq = System.unique_integer([:positive, :monotonic])
    actor = SystemActor.system(:agent_cert_expiry_monitor_test)
    now = ~U[2026-10-28 12:00:00.000000Z]
    {:ok, uniq: uniq, actor: actor, now: now}
  end

  describe "peer certificate metadata persistence via AgentGatewaySync" do
    test "persists cert_not_before, cert_expires_at, cert_serial, and cert_fingerprint_sha256 on Hello and heartbeat",
         %{uniq: uniq, actor: actor, now: now} do
      agent_uid = "agent-cert-sync-#{uniq}"
      not_before = DateTime.shift(now, day: -1)
      expires_at = DateTime.shift(not_before, day: 90)
      serial = "01a2b3c4d5e6"
      fingerprint = String.duplicate("a", 64)

      assert :ok =
               AgentGatewaySync.upsert_agent(agent_uid, %{
                 name: "sensor-#{uniq}.example.test",
                 host: "sensor-#{uniq}.example.test",
                 ip: "192.0.2.40",
                 gateway_id: "gateway-synthetic-1",
                 version: "1.2.3",
                 capabilities: ["icmp"],
                 cert_not_before: not_before,
                 cert_expires_at: expires_at,
                 cert_serial: serial,
                 cert_fingerprint_sha256: fingerprint
               })

      assert {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
      assert DateTime.compare(agent.cert_not_before, not_before) == :eq
      assert DateTime.compare(agent.cert_expires_at, expires_at) == :eq
      assert agent.cert_serial == serial
      assert agent.cert_fingerprint_sha256 == fingerprint

      renewed_not_before = now
      renewed_expires_at = DateTime.shift(now, day: 90)
      renewed_serial = "09f8e7d6c5b4"
      renewed_fingerprint = String.duplicate("b", 64)

      assert :ok =
               AgentGatewaySync.heartbeat_agent(agent_uid, %{
                 gateway_id: "gateway-synthetic-1",
                 ip: "192.0.2.40",
                 cert_not_before: renewed_not_before,
                 cert_expires_at: renewed_expires_at,
                 cert_serial: renewed_serial,
                 cert_fingerprint_sha256: renewed_fingerprint,
                 cert_renewed_at: now
               })

      assert {:ok, updated} = Agent.get_by_uid(agent_uid, actor: actor)
      assert DateTime.compare(updated.cert_not_before, renewed_not_before) == :eq
      assert DateTime.compare(updated.cert_expires_at, renewed_expires_at) == :eq
      assert updated.cert_serial == renewed_serial
      assert updated.cert_fingerprint_sha256 == renewed_fingerprint
      assert DateTime.compare(updated.cert_renewed_at, now) == :eq
    end
  end

  describe "certificate expiry alerting lifecycle" do
    test "raises warning at <= 14d, escalates to critical at <= 7d and expired, and resolves when renewed > 14d",
         %{uniq: uniq, actor: actor, now: now} do
      device_uid = "sr:device-cert-test-#{uniq}"

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(:create, %{
          uid: device_uid,
          hostname: "host-cert-#{uniq}.example.test",
          ip: "192.0.2.50"
        })
        |> Ash.create(actor: actor)

      agent_uid = "agent-cert-monitor-#{uniq}"
      not_before = DateTime.shift(now, day: -78)
      warning_expires_at = DateTime.shift(now, day: 10)

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: agent_uid,
          name: "host-cert-#{uniq}.example.test",
          host: "host-cert-#{uniq}.example.test",
          ip: "192.0.2.50",
          device_uid: device_uid,
          cert_not_before: not_before,
          cert_expires_at: warning_expires_at,
          cert_serial: "1001aabb",
          cert_fingerprint_sha256: String.duplicate("c", 64)
        })
        |> Ash.create(actor: actor)

      # 1. Within 14 days (10d remaining) -> warning alert (expiring_soon)
      _summary = AgentCertExpiryMonitor.evaluate(now: now)
      assert [warning_alert] = active_alerts_for(agent_uid, actor)
      assert warning_alert.severity == :warning
      assert warning_alert.agent_uid == agent_uid
      assert warning_alert.device_uid == device_uid
      assert warning_alert.metadata["expiry_state"] == "expiring_soon"
      assert warning_alert.metadata["cert_serial"] == "1001aabb"

      # 2. Within 7 days (5d remaining) -> escalates to critical alert (expiring_soon)
      critical_soon_now = DateTime.shift(now, day: 5)
      _summary = AgentCertExpiryMonitor.evaluate(now: critical_soon_now)
      assert [critical_soon_alert] = active_alerts_for(agent_uid, actor)
      assert critical_soon_alert.severity == :critical
      assert critical_soon_alert.metadata["expiry_state"] == "expiring_soon"

      # 3. Past expiration (-1d remaining) -> critical alert with expiry_state == "expired"
      expired_now = DateTime.shift(now, day: 11)
      _summary = AgentCertExpiryMonitor.evaluate(now: expired_now)
      assert [expired_alert] = active_alerts_for(agent_uid, actor)
      assert expired_alert.severity == :critical
      assert expired_alert.metadata["expiry_state"] == "expired"
      assert expired_alert.title =~ "expired"

      # 4. Certificate renewed to 90 days in the future -> active alert is resolved
      renewed_expires_at = DateTime.shift(expired_now, day: 90)

      {:ok, _renewed_agent} =
        agent
        |> Ash.Changeset.for_update(:update_certificate, %{
          cert_not_before: expired_now,
          cert_expires_at: renewed_expires_at,
          cert_serial: "2002ccdd",
          cert_fingerprint_sha256: String.duplicate("d", 64),
          cert_renewed_at: expired_now
        })
        |> Ash.update(actor: actor)

      _summary = AgentCertExpiryMonitor.evaluate(now: expired_now)
      assert active_alerts_for(agent_uid, actor) == []

      {:ok, resolved} = Alert.get_by_id(expired_alert.id, actor: actor)
      assert resolved.status == :resolved
    end
  end

  defp active_alerts_for(agent_uid, actor) do
    source_id = AgentCertExpiryMonitor.alert_source_id(agent_uid)

    Alert
    |> Ash.Query.for_read(:active)
    |> Ash.Query.filter(source_id == ^source_id)
    |> Ash.read!(actor: actor)
    |> case do
      %Ash.Page.Keyset{results: results} -> results
      results when is_list(results) -> results
    end
  end
end
