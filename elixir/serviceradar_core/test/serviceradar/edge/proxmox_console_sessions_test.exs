defmodule ServiceRadar.Edge.ProxmoxConsoleSessionsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadar.Edge.ProxmoxConsoleSessions
  alias ServiceRadar.Repo

  defmodule Previewer do
    @moduledoc false

    def preview_rule(_rule, _opts) do
      {:ok, %{sample_devices: [%{uid: Process.get(:proxmox_console_test_device_uid)}]}}
    end
  end

  @system_actor SystemActor.system(:proxmox_console_sessions_test)

  test "browser tickets are single-use and plaintext tickets are never persisted in session data" do
    uid = unique_uid("ticket")
    insert_device!(uid, agent_id: "agent-ticket", gateway_id: "gateway-ticket")
    Process.put(:proxmox_console_test_device_uid, uid)
    secret = create_secret!("ticket")
    _rule = create_rule!(secret, scope_value: "agent-ticket")

    assert {:ok, %{session: session, ticket: ticket}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{
                 metadata: %{
                   "private_key" => private_key_fixture(),
                   "safe" => "kept",
                   "remote_console" => %{"provider" => "caller-controlled"}
                 }
               },
               previewer: Previewer,
               actor: @system_actor
             )

    refute inspect(session) =~ ticket
    assert session.metadata["private_key"] == "REDACTED"
    assert session.metadata["safe"] == "kept"
    assert session.metadata["remote_console"]["schema"] == "serviceradar.remote_console_target.v1"
    assert session.metadata["remote_console"]["provider"] == "proxmox"
    assert session.metadata["remote_console"]["target_type"] == "host"
    assert session.metadata["remote_console"]["protocol"] == "proxmox-termproxy"
    assert session.metadata["remote_console"]["transport"] == "pty"
    assert session.metadata["remote_console"]["agent_id"] == "agent-ticket"
    refute inspect(session.metadata) =~ "PRIVATE KEY"

    assert {:ok, %ProxmoxConsoleSession{status: :attached}} =
             ProxmoxConsoleSessions.attach_with_ticket(ticket, session_id: session.id)

    assert {:error, :invalid_or_expired_ticket} =
             ProxmoxConsoleSessions.attach_with_ticket(ticket, session_id: session.id)
  end

  test "requested agent-scoped console credential rule can route unmanaged targets" do
    uid = unique_uid("agent-scoped-route")
    insert_device!(uid, agent_id: nil, gateway_id: nil)
    Process.put(:proxmox_console_test_device_uid, uid)
    secret = create_secret!("agent-scoped-route")
    rule = create_rule!(secret, scope_value: "agent-proxmox")

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{credential_rule_id: rule.id},
               previewer: Previewer,
               actor: @system_actor
             )

    assert session.agent_id == "agent-proxmox"
  end

  test "native guest console modes can use scoped Proxmox API token rules" do
    uid = unique_uid("guest-mode")
    insert_device!(uid, agent_id: "agent-guest", gateway_id: "gateway-guest")
    Process.put(:proxmox_console_test_device_uid, uid)
    secret = create_secret!("guest-mode")
    _rule = create_rule!(secret, scope_value: "agent-guest")

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{target_kind: "lxc_guest", console_mode: "proxmox_termproxy"},
               previewer: Previewer,
               actor: @system_actor
             )

    assert session.console_mode == :proxmox_termproxy
    assert session.metadata["remote_console"]["target_type"] == "guest"
  end

  test "console rule using gateway scope still requires an agent route for the target device" do
    uid = unique_uid("missing-agent")
    insert_device!(uid, agent_id: nil, gateway_id: "gateway-device")
    Process.put(:proxmox_console_test_device_uid, uid)
    secret = create_secret!("missing-agent")
    _rule = create_rule!(secret, scope_type: :gateway, scope_value: "gateway-device")

    assert {:error, :missing_agent_scope} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               actor: @system_actor
             )
  end

  test "console rule can use Proxmox discovery agent metadata when agent_id is not populated" do
    uid = unique_uid("metadata-agent")

    insert_device!(uid,
      agent_id: nil,
      gateway_id: "gateway-metadata",
      metadata: %{"sync_service_id" => "agent-from-proxmox-discovery"}
    )

    Process.put(:proxmox_console_test_device_uid, uid)
    secret = create_secret!("metadata-agent")
    _rule = create_rule!(secret, scope_value: "agent-from-proxmox-discovery")

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               actor: @system_actor
             )

    assert session.agent_id == "agent-from-proxmox-discovery"
    assert session.metadata["remote_console"]["agent_id"] == "agent-from-proxmox-discovery"
  end

  defp insert_device!(uid, opts) do
    now = DateTime.utc_now()

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: uid,
        vendor_name: "Proxmox",
        agent_id: Keyword.get(opts, :agent_id),
        gateway_id: Keyword.get(opts, :gateway_id),
        is_available: true,
        metadata: Keyword.get(opts, :metadata, %{}),
        first_seen_time: now,
        last_seen_time: now
      }
    ])
  end

  defp create_secret!(suffix) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(:create, %{
        name: "pve-console-#{suffix}-#{System.unique_integer([:positive])}",
        provider: "proxmox",
        credential_kind: :api_token,
        username: "root@pam!sr",
        secret_payload: "root@pam!sr=test-token",
        metadata: %{"auth_method" => "proxmox_api_token"}
      })
      |> Ash.create(actor: @system_actor)

    secret
  end

  defp create_rule!(secret, attrs) do
    {:ok, rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "pve-console-rule-#{System.unique_integer([:positive])}",
          provider: "proxmox",
          auth_method: :proxmox_api_token,
          purpose: :inventory_enrichment,
          target_query: "in:devices",
          scope_type: Keyword.get(attrs, :scope_type, :agent),
          scope_value: Keyword.fetch!(attrs, :scope_value),
          secret_id: secret.id,
          metadata: %{}
        }
      )
      |> Ash.create(actor: @system_actor)

    rule
  end

  defp unique_uid(label), do: "pve-console-#{label}-#{System.unique_integer([:positive])}"

  defp private_key_fixture do
    private_key_fixture_header() <>
      """
      b3BlbnNzaC10ZXN0LWtleS1tYXRlcmlhbA==
      #{private_key_fixture_footer()}
      """
  end

  defp private_key_fixture_header, do: "-----BEGIN OPENSSH " <> "PRIVATE KEY-----\n"
  defp private_key_fixture_footer, do: "-----END OPENSSH " <> "PRIVATE KEY-----"
end
