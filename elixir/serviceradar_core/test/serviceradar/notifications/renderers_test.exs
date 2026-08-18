defmodule ServiceRadar.Notifications.RenderersTest do
  @moduledoc """
  One small pure module per payload format: finished strings in, provider-shaped
  map out. No database, no clock, no I/O - `timestamp` is an input, so the same
  content renders byte-identically every time.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.Renderers.Content
  alias ServiceRadar.Notifications.Renderers.DiscordEmbed
  alias ServiceRadar.Notifications.Renderers.Format
  alias ServiceRadar.Notifications.Renderers.Html
  alias ServiceRadar.Notifications.Renderers.Json
  alias ServiceRadar.Notifications.Renderers.Markdown
  alias ServiceRadar.Notifications.Renderers.PagerdutyV2
  alias ServiceRadar.Notifications.Renderers.Plain
  alias ServiceRadar.Notifications.Renderers.SlackBlocks

  @modules [SlackBlocks, DiscordEmbed, PagerdutyV2, Json, Html, Markdown, Plain]

  @dedupe_key "rule-42|device_id=abc|severity=critical"
  @delivery_id "0198f0aa-2222-7000-8000-000000000002"

  @links %{
    "acknowledge" => "https://sr.example.com/n/ack?t=aaa",
    "snooze" => "https://sr.example.com/n/snooze?t=bbb",
    "resolve" => "https://sr.example.com/n/resolve?t=ccc",
    "alert" => "https://sr.example.com/alerts/0198"
  }

  defp content(overrides \\ []) do
    defaults = [
      payload_format: :plain,
      subject: "tonka01 is unreachable",
      body: "ICMP probe failed three consecutive times",
      severity: "critical",
      alert_class: "device_down",
      alert_id: "0198f0aa-1111-7000-8000-000000000001",
      alert_url: "https://sr.example.com/alerts/0198",
      dedupe_key: @dedupe_key,
      source: "tonka01",
      timestamp: "2026-08-09T12:00:00Z",
      alert: %{"title" => "tonka01 is unreachable"},
      links: @links,
      include_action_links?: true,
      event_action: :trigger,
      snooze_seconds: 3600
    ]

    struct!(Content, Keyword.merge(defaults, overrides))
  end

  # --- the contract every format keeps --------------------------------------

  describe "every format module" do
    test "declares the payload format the renderer maps to it" do
      for module <- @modules do
        format = module.payload_format()

        assert format in Renderer.payload_formats()
        assert {:ok, ^module} = Renderer.format_module(format)
      end
    end

    test "covers exactly the seven declared payload formats" do
      assert Enum.sort(Enum.map(@modules, & &1.payload_format())) ==
               Enum.sort(Renderer.payload_formats())
    end

    test "returns a JSON-encodable map" do
      for module <- @modules do
        payload = module.render(content(payload_format: module.payload_format()))

        assert is_map(payload)
        assert {:ok, _encoded} = Jason.encode(payload)
      end
    end

    test "is deterministic" do
      for module <- @modules do
        input = content(payload_format: module.payload_format())

        assert module.render(input) == module.render(input)
      end
    end

    test "omits action links when the destination is exempt (design D7)" do
      for module <- @modules do
        payload =
          [payload_format: module.payload_format(), include_action_links?: false]
          |> content()
          |> module.render()

        encoded = Jason.encode!(payload)

        refute encoded =~ "n/ack"
        refute encoded =~ "n/snooze"
        refute encoded =~ "n/resolve"
      end
    end

    test "carries all three action links when the destination is not exempt" do
      for module <- @modules do
        encoded =
          [payload_format: module.payload_format()]
          |> content()
          |> module.render()
          |> Jason.encode!()

        assert encoded =~ "n/ack", "#{inspect(module)} dropped the acknowledge link"
        assert encoded =~ "n/snooze", "#{inspect(module)} dropped the snooze link"
        assert encoded =~ "n/resolve", "#{inspect(module)} dropped the resolve link"
      end
    end

    test "survives a content with only the required fields" do
      for module <- @modules do
        minimal = %Content{payload_format: module.payload_format(), body: "something happened"}

        assert is_map(module.render(minimal))
      end
    end
  end

  describe "Content" do
    test "action_links are in the fixed D7 order with the fixed wording" do
      assert [
               %{action: :acknowledge, label: "Acknowledge"},
               %{action: :snooze, label: "Snooze 1h"},
               %{action: :resolve, label: "Resolve"}
             ] = Content.action_links(content())
    end

    test "action_links is empty for an exempt destination" do
      assert Content.action_links(content(include_action_links?: false)) == []
    end

    test "an unminted link is skipped rather than rendered as a broken URL" do
      links = Map.delete(@links, "snooze")

      assert [%{action: :acknowledge}, %{action: :resolve}] =
               Content.action_links(content(links: links))
    end

    test "action_controls carry the identifiers a callback needs and no URL" do
      controls = Content.action_controls(content(delivery_id: @delivery_id))

      assert [
               %{action: :acknowledge, label: "Acknowledge"},
               %{action: :snooze, label: "Snooze 1h"},
               %{action: :resolve, label: "Resolve"}
             ] = controls

      for control <- controls do
        assert control.alert_id == "0198f0aa-1111-7000-8000-000000000001"
        assert control.delivery_id == @delivery_id
        # A control posts an interaction; it is not a link and must carry no URL
        # and no token.
        refute Map.has_key?(control, :url)
      end
    end

    test "action_controls is empty for an exempt destination" do
      # The firehose exemption. This clause matches the struct exactly as
      # action_links/1 does, so an interactive call site cannot route around the
      # exemption by reaching for a different accessor.
      assert Content.action_controls(
               content(include_action_links?: false, delivery_id: @delivery_id)
             ) == []
    end

    test "action_controls is empty without a delivery to bind to" do
      # A control bound to an alert alone is a WEAKER binding than the Phase 1
      # link it replaces, and ActionLinks refuses to mint one.
      assert Content.action_controls(content(delivery_id: nil)) == []
    end

    test "action_controls omits snooze when no duration was carried" do
      # apply_native/2 refuses a snooze with no duration, so rendering the button
      # would guarantee a failure on click.
      controls = Content.action_controls(content(delivery_id: @delivery_id, snooze_seconds: nil))

      assert Enum.map(controls, & &1.action) == [:acknowledge, :resolve]
    end

    test "action_controls carries the snooze duration on the snooze control only" do
      controls = Content.action_controls(content(delivery_id: @delivery_id, snooze_seconds: 900))

      assert %{action: :snooze, snooze_seconds: 900} =
               Enum.find(controls, &(&1.action == :snooze))

      assert %{snooze_seconds: nil} = Enum.find(controls, &(&1.action == :acknowledge))
    end

    test "SlackBlocks interactive buttons carry no url and bind the delivery" do
      payload =
        [payload_format: :slack_blocks, interactive?: true, delivery_id: @delivery_id]
        |> content()
        |> SlackBlocks.render()

      [actions] = Enum.filter(payload["blocks"], &(&1["type"] == "actions"))
      encoded = Jason.encode!(actions)

      # A button with a url opens a browser tab as well as sending the
      # interaction, and would carry a capability we deliberately did not mint.
      refute encoded =~ "\"url\""
      refute encoded =~ "n/ack"

      assert Enum.map(actions["elements"], & &1["action_id"]) == [
               "notification_acknowledge",
               "notification_snooze",
               "notification_resolve"
             ]

      for element <- actions["elements"] do
        assert element["value"] =~ @delivery_id
      end
    end

    test "SlackBlocks falls back to link buttons when interactive mode is off" do
      payload =
        [payload_format: :slack_blocks, delivery_id: @delivery_id]
        |> content()
        |> SlackBlocks.render()

      encoded = Jason.encode!(payload)

      assert encoded =~ "n/ack"
      assert encoded =~ "\"url\""
    end

    test "SlackBlocks renders no actions block for an exempt destination even interactive" do
      # The firehose exemption survives interactive mode; action_controls/1
      # returns [] for an exempt destination and the block is omitted entirely.
      payload =
        [
          payload_format: :slack_blocks,
          interactive?: true,
          delivery_id: @delivery_id,
          include_action_links?: false
        ]
        |> content()
        |> SlackBlocks.render()

      assert Enum.filter(payload["blocks"], &(&1["type"] == "actions")) == []
    end

    test "control_value encodes the binding the callback parses" do
      assert SlackBlocks.control_value(%{
               action: :acknowledge,
               alert_id: "alert-1",
               delivery_id: "delivery-1"
             }) == "acknowledge:alert-1:delivery-1"

      assert SlackBlocks.control_value(%{
               action: :snooze,
               alert_id: "alert-1",
               delivery_id: "delivery-1",
               snooze_seconds: 3600
             }) == "snooze:alert-1:delivery-1:3600"
    end

    test "link/2 accepts atom and string keys" do
      assert Content.link(@links, :alert) == "https://sr.example.com/alerts/0198"
      assert Content.link(%{alert: "x"}, :alert) == "x"
      assert Content.link(%{}, :alert) == nil
    end

    test "summary falls back to the first non-empty body line" do
      assert Content.summary(content()) == "tonka01 is unreachable"

      assert Content.summary(content(subject: nil, body: "\n\nfirst line\nsecond")) ==
               "first line"
    end
  end

  # --- plain ----------------------------------------------------------------

  describe "Plain" do
    test "writes the URLs out in full, because plain text has no link text" do
      payload = Plain.render(content(payload_format: :plain))

      assert payload["subject"] == "tonka01 is unreachable"
      assert payload["body"] =~ "ICMP probe failed"
      assert payload["text"] =~ "Acknowledge: https://sr.example.com/n/ack?t=aaa"
      assert payload["text"] =~ "Snooze 1h: https://sr.example.com/n/snooze?t=bbb"
      assert payload["text"] =~ "Resolve: https://sr.example.com/n/resolve?t=ccc"
    end

    test "drops an absent subject rather than emitting a null" do
      payload = Plain.render(content(payload_format: :plain, subject: nil))

      refute Map.has_key?(payload, "subject")
      assert payload["text"] =~ "ICMP probe failed"
    end
  end

  # --- markdown -------------------------------------------------------------

  describe "Markdown" do
    test "renders a heading and a single link row" do
      payload = Markdown.render(content(payload_format: :markdown))

      assert payload["text"] =~ "### tonka01 is unreachable"
      assert payload["text"] =~ "[Acknowledge](https://sr.example.com/n/ack?t=aaa)"
      assert payload["text"] =~ "[Snooze 1h](https://sr.example.com/n/snooze?t=bbb) | "
      assert payload["severity"] == "critical"
    end

    test "does not escape markdown in substituted values" do
      # Escaping would corrupt every device name containing an underscore.
      payload = Markdown.render(content(payload_format: :markdown, body: "core_switch_01 down"))

      assert payload["body"] == "core_switch_01 down"
    end
  end

  # --- html -----------------------------------------------------------------

  describe "Html" do
    test "escapes a substituted value so an alert title cannot inject markup" do
      injection = "<img src=x onerror=\"alert(1)\">"

      assert Html.escape(injection) == "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;"

      assert Html.escape("a & b") == "a &amp; b"
      assert Html.escape("it's") == "it&#39;s"
    end

    test "escaping happens through the renderer, on substituted values only" do
      {:ok, rendered, []} =
        Renderer.render_string(
          "<p>{{ alert.title }}</p>",
          %{"alert" => %{"title" => "<script>alert(1)</script>"}},
          :html
        )

      # The operator's <p> survives; the alert's <script> does not.
      assert rendered == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>"
    end

    test "wraps the body and escapes the subject and the link attributes" do
      payload = Html.render(content(payload_format: :html, subject: "a <b> c"))

      assert payload["html"] =~ "<h2>a &lt;b&gt; c</h2>"
      assert payload["html"] =~ ~s(<a href="https://sr.example.com/n/ack?t=aaa">Acknowledge</a>)
      assert payload["html"] =~ "serviceradar-notification-body"
    end

    test "every other format leaves substituted values alone" do
      for module <- @modules -- [Html] do
        assert module.escape("<b>") == "<b>"
      end
    end
  end

  # --- json -----------------------------------------------------------------

  describe "Json" do
    test "a body that parses as a JSON object IS the payload" do
      body = ~s({"text": "device down", "priority": 5, "nested": {"a": [1, 2]}})

      assert Json.render(content(payload_format: :json, body: body)) == %{
               "text" => "device down",
               "priority" => 5,
               "nested" => %{"a" => [1, 2]}
             }
    end

    test "a non-object body falls back to a stable envelope" do
      payload = Json.render(content(payload_format: :json, body: "just some text"))

      assert payload["body"] == "just some text"
      assert payload["subject"] == "tonka01 is unreachable"
      assert payload["severity"] == "critical"
      assert payload["dedupe_key"] == @dedupe_key
      assert payload["timestamp"] == "2026-08-09T12:00:00Z"

      assert [
               %{"action" => "acknowledge", "label" => "Acknowledge"},
               %{"action" => "snooze"},
               %{"action" => "resolve"}
             ] = payload["links"]
    end

    test "a JSON array body uses the envelope, because a payload must be an object" do
      payload = Json.render(content(payload_format: :json, body: ~s([1, 2, 3])))

      assert payload["body"] == "[1, 2, 3]"
    end

    test "broken JSON degrades to the envelope instead of losing the notification" do
      # This is what an unescaped quote in an alert title does to a hand-written
      # JSON template. The notification still leaves, in a parseable shape.
      payload = Json.render(content(payload_format: :json, body: ~s({"text": "he said "hi""})))

      assert payload["body"] =~ "he said"
      assert payload["alert_id"] == "0198f0aa-1111-7000-8000-000000000001"
    end
  end

  # --- slack ----------------------------------------------------------------

  describe "SlackBlocks" do
    test "carries a text fallback alongside blocks" do
      payload = SlackBlocks.render(content(payload_format: :slack_blocks))

      # Blocks without text render as "This content can't be displayed".
      assert payload["text"] == "tonka01 is unreachable"
      assert is_list(payload["blocks"])
    end

    test "builds header, section, context and action blocks" do
      payload = SlackBlocks.render(content(payload_format: :slack_blocks))
      types = Enum.map(payload["blocks"], & &1["type"])

      assert types == ["header", "section", "context", "actions"]

      assert %{"text" => %{"type" => "plain_text", "text" => "tonka01 is unreachable"}} =
               Enum.at(payload["blocks"], 0)

      assert %{"text" => %{"type" => "mrkdwn"}} = Enum.at(payload["blocks"], 1)

      context_text = payload["blocks"] |> Enum.at(2) |> Map.fetch!("elements") |> hd()

      assert context_text["text"] =~ "Severity:"
      assert context_text["text"] =~ "critical"
    end

    test "buttons are url buttons carrying the action id and a style" do
      payload = SlackBlocks.render(content(payload_format: :slack_blocks))
      [ack, snooze, resolve] = List.last(payload["blocks"])["elements"]

      assert ack["type"] == "button"
      assert ack["url"] == "https://sr.example.com/n/ack?t=aaa"
      assert ack["action_id"] == "notification_acknowledge"
      assert ack["style"] == "primary"
      assert ack["value"] == @dedupe_key

      assert snooze["action_id"] == "notification_snooze"
      refute Map.has_key?(snooze, "style")

      assert resolve["action_id"] == "notification_resolve"
      assert resolve["style"] == "danger"
    end

    test "omits the actions block entirely for an exempt destination" do
      payload =
        SlackBlocks.render(content(payload_format: :slack_blocks, include_action_links?: false))

      refute "actions" in Enum.map(payload["blocks"], & &1["type"])
    end

    test "enforces Slack's field limits, because exceeding one is a permanent failure" do
      long_subject = String.duplicate("x", 400)
      long_body = String.duplicate("y", 5000)

      payload =
        SlackBlocks.render(
          content(payload_format: :slack_blocks, subject: long_subject, body: long_body)
        )

      [header, section | _rest] = payload["blocks"]

      assert String.length(header["text"]["text"]) == 150
      assert String.ends_with?(header["text"]["text"], "...")
      assert String.length(section["text"]["text"]) == 3000
      assert String.length(payload["text"]) <= 3000
    end

    test "omits the header when there is no subject" do
      payload = SlackBlocks.render(content(payload_format: :slack_blocks, subject: nil))

      refute "header" in Enum.map(payload["blocks"], & &1["type"])
    end
  end

  # --- discord --------------------------------------------------------------

  describe "DiscordEmbed" do
    test "renders one embed with the alert fields" do
      %{"embeds" => [embed]} = DiscordEmbed.render(content(payload_format: :discord_embed))

      assert embed["title"] == "tonka01 is unreachable"
      assert embed["description"] =~ "ICMP probe failed"
      assert embed["url"] == "https://sr.example.com/alerts/0198"
      assert embed["timestamp"] == "2026-08-09T12:00:00Z"

      names = Enum.map(embed["fields"], & &1["name"])
      assert names == ["Severity", "Class", "Source", "Open in ServiceRadar", "Actions"]

      open = Enum.find(embed["fields"], &(&1["name"] == "Open in ServiceRadar"))
      assert open["value"] == "[Open alert](https://sr.example.com/alerts/0198)"
    end

    test "colours by severity, with a fixed default for anything unrecognised" do
      color = fn severity ->
        %{"embeds" => [embed]} =
          DiscordEmbed.render(content(payload_format: :discord_embed, severity: severity))

        embed["color"]
      end

      assert color.("critical") != color.("info")
      assert color.("CRITICAL") == color.("critical")
      assert color.("wat") == color.(nil)
      assert is_integer(color.("critical"))
    end

    test "action links go in a field, because a webhook cannot send components" do
      %{"embeds" => [embed]} = DiscordEmbed.render(content(payload_format: :discord_embed))
      actions = Enum.find(embed["fields"], &(&1["name"] == "Actions"))

      assert actions["value"] =~ "[Acknowledge](https://sr.example.com/n/ack?t=aaa)"
      refute actions["inline"]
    end

    test "enforces Discord's title and description limits" do
      %{"embeds" => [embed]} =
        DiscordEmbed.render(
          content(
            payload_format: :discord_embed,
            subject: String.duplicate("x", 400),
            body: String.duplicate("y", 5000)
          )
        )

      assert String.length(embed["title"]) == 256
      assert String.length(embed["description"]) == 4096
    end

    test "falls back to the body summary when there is no subject" do
      %{"embeds" => [embed]} =
        DiscordEmbed.render(
          content(payload_format: :discord_embed, subject: nil, body: "first line\nsecond")
        )

      assert embed["title"] == "first line"
    end
  end

  # --- pagerduty ------------------------------------------------------------

  describe "PagerdutyV2" do
    test "dedup_key is the notification dedupe key" do
      payload = PagerdutyV2.render(content(payload_format: :pagerduty_v2))

      assert payload["dedup_key"] == @dedupe_key
      assert payload["event_action"] == "trigger"
    end

    test "a firing event and its resolution carry the SAME dedup_key" do
      # PagerDuty correlates a trigger with its resolve by dedup_key alone. A
      # different key on the resolve closes nothing and every renotify opens a
      # new incident - which is the entire reason the key is carried here.
      firing = PagerdutyV2.render(content(payload_format: :pagerduty_v2, event_action: :trigger))

      resolution =
        PagerdutyV2.render(
          content(
            payload_format: :pagerduty_v2,
            event_action: :resolve,
            subject: "tonka01 recovered",
            body: "ICMP probe succeeded"
          )
        )

      assert firing["event_action"] == "trigger"
      assert resolution["event_action"] == "resolve"
      assert firing["dedup_key"] == resolution["dedup_key"]
      assert resolution["dedup_key"] == @dedupe_key

      # ...and nothing about the escalation step or the delivery leaks into it.
      refute firing["dedup_key"] =~ "step"
      refute firing["dedup_key"] =~ firing["payload"]["summary"]
    end

    test "an unknown event action falls back to trigger rather than emitting garbage" do
      payload =
        PagerdutyV2.render(content(payload_format: :pagerduty_v2, event_action: :something_else))

      assert payload["event_action"] == "trigger"
    end

    test "maps ServiceRadar severities onto PagerDuty's four" do
      severity = fn value ->
        [payload_format: :pagerduty_v2, severity: value]
        |> content()
        |> PagerdutyV2.render()
        |> get_in(["payload", "severity"])
      end

      assert severity.("critical") == "critical"
      assert severity.("CRITICAL") == "critical"
      assert severity.("high") == "error"
      assert severity.("medium") == "warning"
      assert severity.("warning") == "warning"
      assert severity.("low") == "info"
      assert severity.("info") == "info"

      # PagerDuty rejects anything outside the four with a 400, which is
      # terminal, so an unrecognised severity degrades instead of losing the page.
      assert severity.("spicy") == "error"
      assert severity.(nil) == "error"
    end

    test "the routing key is never rendered; the transport injects it from the broker" do
      payload = PagerdutyV2.render(content(payload_format: :pagerduty_v2))

      refute Map.has_key?(payload, "routing_key")
      refute Jason.encode!(payload) =~ "routing_key"
    end

    test "carries the alert link plus the three action links" do
      payload = PagerdutyV2.render(content(payload_format: :pagerduty_v2))

      assert [
               %{"text" => "View in ServiceRadar"},
               %{"text" => "Acknowledge"},
               %{"text" => "Snooze 1h"},
               %{"text" => "Resolve"}
             ] = payload["links"]
    end

    test "truncates the summary to PagerDuty's limit" do
      payload =
        PagerdutyV2.render(
          content(payload_format: :pagerduty_v2, subject: String.duplicate("x", 2000))
        )

      assert String.length(payload["payload"]["summary"]) == 1024
    end

    test "omits an absent timestamp rather than inventing one" do
      payload = PagerdutyV2.render(content(payload_format: :pagerduty_v2, timestamp: nil))

      refute Map.has_key?(payload["payload"], "timestamp")
    end

    test "defaults the source, because PagerDuty requires one" do
      payload = PagerdutyV2.render(content(payload_format: :pagerduty_v2, source: nil))

      assert payload["payload"]["source"] == "serviceradar"
    end
  end

  # --- shared helpers -------------------------------------------------------

  describe "Format helpers" do
    test "compact drops nil and empty-list values, keeping false and zero" do
      assert Format.compact(%{"a" => nil, "b" => [], "c" => false, "d" => 0, "e" => ""}) ==
               %{"c" => false, "d" => 0, "e" => ""}
    end

    test "presence and blank?" do
      assert Format.presence("x") == "x"
      assert Format.presence("  ") == nil
      assert Format.presence(nil) == nil
      assert Format.blank?("")
      refute Format.blank?("x")
    end

    test "truncate keeps the total length at the limit and marks the cut" do
      assert Format.truncate("abcdefghij", 10) == "abcdefghij"
      assert Format.truncate("abcdefghijk", 10) == "abcdefg..."
      assert Format.truncate("abcdef", 3) == "abc"
      assert Format.truncate(nil, 10) == nil
    end

    test "join_nonempty skips blanks" do
      assert Format.join_nonempty(["a", nil, "  ", "b"], "-") == "a-b"
    end
  end
end
