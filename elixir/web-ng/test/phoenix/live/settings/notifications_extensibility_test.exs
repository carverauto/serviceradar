defmodule ServiceRadarWebNGWeb.Settings.NotificationsExtensibilityTest do
  @moduledoc """
  Task 2.3.4: the extensibility claim, executed.

  Design D2's claim for the declarative tier is specific and testable: **an
  operator adds a notification destination by uploading a document - no
  ServiceRadar code change, no release, no Wasm toolchain.** Alertmanager and
  Grafana both hardcoded their receiver lists and cannot accept a community
  receiver without a release; this file is the proof that ServiceRadar does not
  have to.

  So the destination here - `acme_pager` - is deliberately one this repository
  has never heard of, and the first test says so in the terms that would have to
  change if the claim were false: it is in no seeded catalog and no compile-time
  transport allowlist, and after the upload it still names no implementation
  module.

  Everything after that is one continuous path with a single new artifact, the
  pasted document:

      paste a document in the UI -> provider row -> activate it in the UI ->
      create a channel against the config_schema THE DOCUMENT declared, in the UI
      -> an alert fires -> the engine routes it -> the delivery goes out over
      HTTP shaped exactly as the document described

  No module is compiled, no application is restarted, no configuration file is
  reloaded, and no release is cut between the paste and the delivery. The whole
  test runs in one process.

  The destination is a function plug injected through the transport's documented
  `req_options` seam, and it forwards what it received to the test process, so
  the last assertion is about the bytes on the wire rather than about an internal
  return value. The URL is a public IP literal because the outbound policy
  resolves hostnames and a test must not depend on DNS.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Notifications.Declarative.Catalog
  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.ProviderSeeder
  alias ServiceRadar.Notifications.Transports.Registry, as: TransportRegistry
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.NotificationsFixtures

  require Ash.Query

  @key "acme_pager"
  @host "93.184.216.34"
  @webhook_url "https://#{@host}/hooks/acme/9f2b1c7a"

  # The only new artifact in this test. Everything the platform needs to reach a
  # destination it has never seen is in these lines: what the channel form asks
  # for, where the request goes, what it carries, and what the answers mean.
  @document """
  schema_version: 1
  key: #{@key}
  display_name: Acme Pager
  description: Page the Acme on-call rotation. ServiceRadar ships no support for this.
  capabilities: [send, test]
  payload_formats: [markdown, plain]
  routes: [control_plane]
  config_schema:
    type: object
    additionalProperties: false
    required: [webhook_url]
    properties:
      webhook_url:
        type: string
        title: Webhook URL
      team:
        type: string
        title: Team
  request:
    method: POST
    url: "{{ config.webhook_url }}"
    headers:
      Content-Type: application/json
      X-Acme-Source: serviceradar
    body_format: json
    body:
      routing_key: "{{ config.team | default: \\"noc\\" }}"
      summary: "{{ alert.severity | upper }} {{ alert.title }}"
      source: "{{ alert.source }}"
  success:
    status: [200, 202]
  failure:
    retryable_status: [429, "500-599"]
  response:
    external_correlation_id:
      from: body
      path: id
  """

  setup %{conn: conn} do
    NotificationsFixtures.seed_providers()

    admin = AccountsFixtures.user_fixture(%{role: :admin})

    %{conn: log_in_user(conn, admin)}
  end

  test "this repository ships nothing for the destination under test" do
    # If any of these three stopped holding, adding this provider WOULD be a
    # repository change, and the tier would not be what the proposal claims.
    refute @key in Enum.map(ProviderSeeder.default_providers(), & &1.provider_key)
    refute @key in Catalog.keys()

    refute Enum.any?(
             TransportRegistry.allowlisted_module_names(),
             &String.contains?(String.downcase(&1), "acme")
           )
  end

  test "a pasted document reaches a real destination, with no release", %{conn: conn} do
    # 1. Upload. The operator pastes a document into the Providers tab.
    {:ok, providers_lv, _html} = live(conn, ~p"/settings/notifications/providers")

    assert render_submit(providers_lv, "save_provider_upload", %{
             "provider" => %{"document" => @document}
           }) =~ "saved as version 1"

    provider = provider!(@key)

    assert provider.provider_type == :declarative
    assert provider.source == :uploaded
    # The tier is authored, not compiled. There is no module for this provider,
    # which is exactly why no release was needed to add it.
    assert is_nil(provider.implementation_module)

    # 2. Activate, in the UI. Nothing is restarted or reloaded.
    render_click(providers_lv, "enable_provider", %{"id" => provider.id})
    assert provider!(@key).status == :active

    # 3. A channel, against the config_schema THE DOCUMENT declared. The form is
    #    generated from the uploaded schema; nothing in the repository knows what
    #    `webhook_url` or `team` mean.
    {:ok, channels_lv, _html} = live(conn, ~p"/settings/notifications/channels")

    render_click(channels_lv, "new_channel", %{})

    assert render_submit(channels_lv, "save_channel", %{
             "channel" => %{
               "name" => "Acme on-call",
               "provider_id" => to_string(provider!(@key).id),
               "execution_route" => "control_plane",
               "max_attempts" => "3"
             },
             "config" => %{"webhook_url" => @webhook_url, "team" => "sre"}
           }) =~ "Channel saved"

    channel = channel!("Acme on-call")
    assert channel.config == %{"webhook_url" => @webhook_url, "team" => "sre"}

    # 4. An alert fires and the engine routes it. Routing, escalation, and
    #    suppression never learn which tier the channel's provider belongs to.
    route_to!(channel)
    delivery_id = fire_alert!()

    # 5. The delivery goes out. The destination is a plug, so the assertion is
    #    about what was actually sent.
    assert {:ok, :sent} =
             Dispatcher.deliver(delivery_id,
               actor: system_actor(),
               transport_opts: [req_options: [plug: acme_plug()]]
             )

    assert_received {:acme_received, sent}

    assert sent.method == "POST"
    assert sent.path == "/hooks/acme/9f2b1c7a"
    assert header(sent, "x-acme-source") == "serviceradar"
    assert header(sent, "content-type") =~ "application/json"

    body = Jason.decode!(sent.body)

    # Every value here came from the document: the channel's `team`, the alert
    # the engine rendered, and the `upper` filter the document asked for.
    assert body["routing_key"] == "sre"
    assert body["summary"] == "CRITICAL Disk 92% on db-01"

    delivery = delivery!(delivery_id)

    assert delivery.state == :sent
    assert delivery.provider_version == 1
    # The document said where the destination's handle lives; the engine read it.
    assert delivery.external_correlation_id == "acme-77"
  end

  test "a second version renders the next delivery, and the first stays identified", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

    render_submit(lv, "save_provider_upload", %{"provider" => %{"document" => @document}})
    provider = provider!(@key)
    render_click(lv, "enable_provider", %{"id" => provider.id})

    channel =
      NotificationsFixtures.channel_fixture(%{
        provider: provider!(@key),
        name: "Acme on-call v1",
        config: %{"webhook_url" => @webhook_url, "team" => "sre"}
      })

    route_to!(channel)
    first = fire_alert!()

    assert {:ok, :sent} =
             Dispatcher.deliver(first,
               actor: system_actor(),
               transport_opts: [req_options: [plug: acme_plug()]]
             )

    assert_received {:acme_received, _first_request}

    # Version 2 changes what goes on the wire.
    render_submit(lv, "save_provider_upload", %{
      "provider" => %{
        "document" => String.replace(@document, ~s(routing_key: "), ~s(escalation_policy: "))
      }
    })

    assert provider!(@key).definition_version == 2

    second = fire_alert!()

    assert {:ok, :sent} =
             Dispatcher.deliver(second,
               actor: system_actor(),
               transport_opts: [req_options: [plug: acme_plug()]]
             )

    assert_received {:acme_received, second_request}

    assert Jason.decode!(second_request.body)["escalation_policy"] == "sre"

    # The superseded version stays identified on the delivery it rendered, which
    # is what makes "which document produced this page?" answerable after an
    # upload.
    assert delivery!(first).provider_version == 1
    assert delivery!(second).provider_version == 2
  end

  # --- the destination -------------------------------------------------------

  defp acme_plug do
    test_pid = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:acme_received,
         %{
           method: conn.method,
           path: conn.request_path,
           headers: conn.req_headers,
           body: body
         }}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "acme-77"}))
    end
  end

  defp header(sent, name) do
    Enum.find_value(sent.headers, fn {key, value} -> if key == name, do: value end)
  end

  # --- the engine's own fixtures ---------------------------------------------

  # A route, a one-step policy, and an alert: the ordinary configuration any
  # channel needs to be paged through. None of it is declarative-specific, which
  # is the point - the decision engine cannot tell the tiers apart.
  #
  # The route is created ONCE per test. A second everything-matches route would
  # make which one wins a matter of tiebreak order rather than of the test.
  defp route_to!(channel) do
    actor = system_actor()
    policy = create_policy!(actor)
    step = create_step!(actor, policy)
    attach!(actor, step, channel)
    create_route!(actor, policy)

    :ok
  end

  defp fire_alert! do
    actor = system_actor()
    alert = alert_fixture(%{title: "Disk 92% on db-01", severity: :critical})
    now = DateTime.add(alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

    id
  end

  defp create_policy!(actor) do
    NotificationEscalationPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{name: "acme-policy-#{System.unique_integer([:positive])}"},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_step!(actor, policy) do
    NotificationEscalationStep
    |> Ash.Changeset.for_create(
      :create,
      %{policy_id: policy.id, step_number: 1, delay_seconds: 0, condition: :always},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp attach!(actor, step, channel) do
    NotificationEscalationStepChannel
    |> Ash.Changeset.for_create(:attach, %{step_id: step.id, channel_id: channel.id}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_route!(actor, policy) do
    NotificationRoute
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "acme-route-#{System.unique_integer([:positive])}",
        escalation_policy_id: policy.id,
        match_expression: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp provider!(key) do
    NotificationProvider
    |> NotificationsFixtures.read_all()
    |> Enum.find(&(&1.provider_key == key))
    |> case do
      nil -> flunk("no provider with key #{key}")
      provider -> provider
    end
  end

  defp channel!(name) do
    NotificationChannel
    |> NotificationsFixtures.read_all()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> flunk("no channel named #{name}")
      channel -> channel
    end
  end

  defp delivery!(id) do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one!(actor: system_actor())
  end
end
