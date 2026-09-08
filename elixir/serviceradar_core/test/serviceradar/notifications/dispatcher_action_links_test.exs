defmodule ServiceRadar.Notifications.DispatcherActionLinksTest do
  @moduledoc """
  The capability tokens `deliver/2` mints, and the one place they must never
  appear.

  A notification carries `Acknowledge`, `Snooze 1h`, and `Resolve` links, and
  each of those URLs *is* a single-use credential
  (`ServiceRadar.Notifications.ActionToken`). Every render therefore produces two
  payloads: `payload`, which goes on the wire and must carry the live token, and
  `redacted_payload`, which is the only form that may be persisted or displayed -
  it is what the Delivery Log shows and what the edge route forwards to an agent
  as `plugin.run_action` params.

  `Automation.Northbound.ActionRedaction` matches on KEY names, and a token sits
  inside a `url` VALUE where there is no sensitive key to match. So the audit copy
  is only safe because `Dispatcher.render/5` passes
  `sensitive_values: ActionLinks.sensitive_values(links)` to the renderer, which
  runs a second, value-based scrub. Drop that one option and the plaintext
  capability survives into the audit trail, in a form an operator can read and
  replay - and nothing else in the pipeline notices, because the notification
  itself still works.

  That is what this file pins:

    * a token-bearing provider mints one capability per action, and only sha256
      digests reach the token table;
    * the plaintext reaches the WIRE payload (otherwise the links are dead) and
      NOTHING that is persisted or displayed - the audit copy, the stored digest,
      the result summary, or the error message;
    * a `:stream` provider mints nothing at all (design C2/D7): a broadcast to
      every authorised subscriber must never carry a single-use capability, and
      the first listener to click it would consume it on everyone else's behalf.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.ActionLinks
  alias ServiceRadar.Notifications.ActionToken
  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.NotificationActionToken
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.TestSupport

  require Ash.Query

  @base_url "https://notifications.serviceradar.test"

  # The shape `ActionToken.mint/2` emits: "srn1", a 16-character selector, and a
  # 43-character secret, all URL-safe base64. Scraping the wire for this rather
  # than trusting a template shape is what keeps the scrub assertions honest -
  # every match is then verified against the token table before it is used.
  @token_regex ~r/srn1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{43}/

  @actions [:acknowledge, :snooze, :resolve]

  defmodule StubTransport do
    @moduledoc """
    A `Transport` that answers from the calling process's dictionary and keeps
    the request it was handed.

    The dispatcher invokes the transport inline, so the stub shares a process
    with the test and needs no supervision and no network. It is also the only
    seam that sees the plaintext token, which is exactly why the test reads the
    capability back from here.
    """

    @behaviour ServiceRadar.Notifications.Transport

    @impl true
    def capabilities, do: [:send, :test]

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(request, _opts) do
      Process.put(:stub_requests, [request | Process.get(:stub_requests, [])])
      Process.get(:stub_result) || Result.delivered(external_correlation_id: "ts-1")
    end

    @impl true
    def test(request, opts), do: deliver(request, opts)

    def requests, do: Enum.reverse(Process.get(:stub_requests, []))
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    Process.delete(:stub_requests)
    Process.delete(:stub_result)

    # `Dispatcher` mints through `ActionLinks.issue/3` with no `:base_url`
    # override, so an unconfigured deployment yields an empty link set and every
    # assertion below would pass vacuously.
    previous = Application.get_env(:serviceradar_core, :notification_action_base_url)
    Application.put_env(:serviceradar_core, :notification_action_base_url, @base_url)

    on_exit(fn ->
      Application.put_env(:serviceradar_core, :notification_action_base_url, previous)
    end)

    {:ok, actor: SystemActor.system(:notification_action_links_test)}
  end

  describe "a token-bearing provider" do
    test "mints one capability per action, bound to this delivery", %{actor: actor} do
      %{id: id, now: now, alert: alert} = planned!(actor, :native)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      rows = tokens_for(id, actor)

      assert length(rows) == 3
      assert MapSet.new(rows, & &1.action) == MapSet.new(@actions)
      assert Enum.all?(rows, &(&1.alert_id == alert.id))
      assert Enum.all?(rows, &is_nil(&1.consumed_at))

      # The duration is bound into the capability at mint time, so it cannot be
      # chosen by whoever clicks the link.
      snooze = Enum.find(rows, &(&1.action == :snooze))
      assert snooze.snooze_seconds == ActionLinks.default_snooze_seconds()
    end

    test "the capability reaches the wire payload", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, :native)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert [request] = StubTransport.requests()
      wire = scannable(request.payload)

      # Scrubbing the message instead of the audit copy would be a silent
      # regression in the other direction: every link would 404.
      Enum.each(live_tokens!(request, id, actor), fn token -> assert wire =~ token end)

      assert %{"links" => links} = request.payload
      assert Enum.map(links, & &1["action"]) == ["acknowledge", "snooze", "resolve"]
      assert Enum.all?(links, &String.starts_with?(&1["url"], @base_url))
    end

    test "the plaintext never reaches anything persisted or displayed", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, :native)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert [request] = StubTransport.requests()
      tokens = live_tokens!(request, id, actor)

      # `metadata["redacted_payload"]` IS `rendered.redacted_payload`: the copy
      # the Delivery Log renders and the edge route forwards to an agent.
      audit = scannable(request.metadata["redacted_payload"])
      delivery = reload!(id, actor)

      assert delivery.state == :sent
      assert delivery.rendered_payload_digest

      Enum.each(tokens, fn token ->
        refute audit =~ token
        refute scannable(delivery.rendered_payload_digest) =~ token
        refute scannable(delivery.result_summary) =~ token
        refute scannable(delivery.error_message) =~ token
      end)

      # Non-vacuity: the audit copy really did carry the three links, and the
      # value-based pass is what emptied them. `url` is not a sensitive KEY, so
      # key-name redaction alone leaves this string untouched.
      assert audit =~ "/api/notifications/actions/"
      assert audit =~ "[REDACTED]"
    end

    test "only sha256 digests are stored", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, :native)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert [request] = StubTransport.requests()
      tokens = live_tokens!(request, id, actor)

      Enum.each(tokens_for(id, actor), fn row ->
        assert row.token_hash =~ ~r/\A[0-9a-f]{64}\z/
        row_text = scannable(row)

        # A database dump, a replica, or a backup must yield no usable
        # credential - not the token, and not the secret half of one.
        Enum.each(tokens, fn token ->
          refute row_text =~ token
          refute row_text =~ secret_half(token)
        end)
      end)
    end
  end

  describe "the :stream provider (design C2)" do
    test "mints no capability and broadcasts no action link", %{actor: actor} do
      %{id: id, now: now, alert: alert} = planned!(actor, :stream)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      # A real row count, over the whole table: the sandbox rolls back, so these
      # are the only capabilities that could exist.
      assert tokens_for(id, actor) == []
      assert Ash.read!(NotificationActionToken, actor: actor) == []

      assert [request] = StubTransport.requests()
      wire = scannable(request.payload)

      refute Regex.match?(@token_regex, wire)
      refute wire =~ "/api/notifications/actions/"
      refute Map.has_key?(request.payload, "links")

      # `to_renderer_opts/1` derives `include_action_links?` from the struct, so
      # the three action names are dropped from the variable context too and a
      # hand-written template cannot reintroduce one.
      Enum.each(@actions, fn action -> refute wire =~ "\"#{action}\"" end)

      # The plain deep link carries no capability and is present for every
      # destination, so its absence would mean the envelope was empty for an
      # unrelated reason and the assertions above proved nothing.
      assert request.payload["alert_url"] == @base_url <> "/alerts/" <> alert.id
    end
  end

  # --- capability helpers ---------------------------------------------------

  # The plaintext tokens the wire payload carried, each verified against the
  # token table before it is used as a needle. A string scraped off the wire that
  # is NOT a live capability bound to this delivery would make every `refute`
  # below pass for the wrong reason.
  defp live_tokens!(request, delivery_id, actor) do
    tokens =
      @token_regex
      |> Regex.scan(scannable(request.payload))
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    assert length(tokens) == 3

    Enum.each(tokens, fn token ->
      assert {:ok, :active, record} = ActionToken.verify(token, actor: actor)
      assert record.delivery_id == delivery_id
    end)

    tokens
  end

  defp secret_half(token), do: token |> String.split(".") |> List.last()

  defp tokens_for(delivery_id, actor) do
    NotificationActionToken
    |> Ash.Query.filter(delivery_id == ^delivery_id)
    |> Ash.read!(actor: actor)
  end

  # Everything a needle could be hiding in, as one searchable string. Structs are
  # flattened to plain maps first so a custom `Inspect` implementation cannot
  # hide a field from the scan.
  defp scannable(nil), do: ""
  defp scannable(value) when is_binary(value), do: value
  defp scannable(%_struct{} = value), do: value |> Map.from_struct() |> scannable()
  defp scannable(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  # --- fixtures -------------------------------------------------------------

  defp planned!(actor, provider_type) do
    channel = create_channel!(actor, provider_type)
    policy = create_policy!(actor)
    step = create_step!(actor, policy)
    attach!(actor, step, channel)
    create_route!(actor, policy)

    alert = create_alert!(actor)
    now = DateTime.add(alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

    %{id: id, alert: alert, channel: channel, now: now}
  end

  defp reload!(id, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one!(actor: actor)
  end

  defp create_alert!(actor) do
    Alert
    |> Ash.Changeset.for_create(
      :trigger,
      %{
        title: "Device unreachable #{System.unique_integer([:positive])}",
        description: "ICMP failed three times",
        severity: :critical,
        source_type: :device
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  # Providers are born `:draft`, and `Suppression` withholds a dispatch to a
  # channel whose provider is not `:active`. Activating is part of a usable
  # fixture: without it every test here would assert against suppression.
  defp create_provider!(actor, :native) do
    create_provider!(actor, %{
      provider_key: "webhook-#{System.unique_integer([:positive])}",
      provider_type: :native,
      display_name: "Test webhook",
      implementation_module: "ServiceRadar.Notifications.Transports.GenericWebhook"
    })
  end

  # The firehose. `implementation_module` MUST be absent: the
  # `notification_providers_native_module` constraint admits it only on a
  # `:native` row, and the stream transport is reached through the provider type.
  defp create_provider!(actor, :stream) do
    create_provider!(actor, %{
      provider_key: "stream-#{System.unique_integer([:positive])}",
      provider_type: :stream,
      display_name: "Test event stream"
    })
  end

  defp create_provider!(actor, attrs) when is_map(attrs) do
    NotificationProvider
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          capabilities: [:send, :test],
          supported_routes: [:control_plane],
          payload_formats: [:json],
          config_schema: %{}
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp create_channel!(actor, provider_type) do
    provider = create_provider!(actor, provider_type)

    NotificationChannel
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "channel-#{System.unique_integer([:positive])}",
        provider_id: provider.id,
        config: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_policy!(actor) do
    NotificationEscalationPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{name: "policy-#{System.unique_integer([:positive])}"},
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
    |> Ash.Changeset.for_create(:attach, %{step_id: step.id, channel_id: channel.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_route!(actor, policy) do
    NotificationRoute
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "route-#{System.unique_integer([:positive])}",
        escalation_policy_id: policy.id,
        match_expression: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
