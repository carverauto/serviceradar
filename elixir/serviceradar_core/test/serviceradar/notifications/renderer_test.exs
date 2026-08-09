defmodule ServiceRadar.Notifications.RendererTest do
  @moduledoc """
  The renderer is a pure function, so these tests are database-free and async.

  `now` is never read inside the renderer - every timestamp is an input - which
  is what lets the same alert render byte-identically twice and lets the digest
  mean something.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.Renderer.Rendered
  alias ServiceRadar.Notifications.Template.Syntax

  @token "cap_9f3a7c1e55b04d2ea1f0aa774c2b"
  @secret "sk-live-0123456789abcdef"

  @all_formats [:slack_blocks, :discord_embed, :markdown, :plain, :html, :pagerduty_v2, :json]

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "0198f0aa-1111-7000-8000-000000000001",
        "title" => "Device tonka01 is unreachable",
        "message" => "ICMP probe failed three consecutive times",
        "severity" => "critical",
        "status" => "pending",
        "alert_class" => "device_down",
        "source" => "stateful_alert_engine",
        "dedupe_key" => "rule-42|device_id=abc|severity=critical",
        "first_seen_at" => ~U[2026-08-09 12:00:00Z],
        "url" => "https://serviceradar.example.com/alerts/0198",
        "metadata" => %{"region" => "us-east-1", "api_key" => @secret}
      },
      overrides
    )
  end

  defp links, do: links_for(@token)

  defp links_for(token) do
    %{
      acknowledge: "https://serviceradar.example.com/n/ack?t=#{token}",
      snooze: "https://serviceradar.example.com/n/snooze?t=#{token}",
      resolve: "https://serviceradar.example.com/n/resolve?t=#{token}",
      alert: "https://serviceradar.example.com/alerts/0198"
    }
  end

  defp template(payload_format, body, subject \\ nil) do
    %{
      payload_format: payload_format,
      subject_template: subject,
      body_template: body
    }
  end

  defp render!(alert, template, format, opts) do
    assert {:ok, rendered} = Renderer.render(alert, template, format, opts)
    rendered
  end

  # --- substitution ---------------------------------------------------------

  describe "substitution" do
    test "replaces whitelisted variable paths and leaves literal text alone" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "ALERT: {{ alert.title }} ({{ alert.severity }})"),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.body == "ALERT: Device tonka01 is unreachable (critical)"
    end

    test "resolves an open namespace leaf that cannot be enumerated at compile time" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "region={{ alert.metadata.region }}"),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.body == "region=us-east-1"
    end

    test "resolves atom-keyed context maps without creating atoms from the path" do
      rendered =
        render!(
          %{title: "Atom keyed", severity: "high"},
          template(:plain, "{{ alert.title }}/{{ alert.severity }}"),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.body == "Atom keyed/high"
    end

    test "renders the subject and body independently" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "body {{ alert.severity }}", "subject {{ alert.title }}"),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.subject == "subject Device tonka01 is unreachable"
      assert rendered.body == "body critical"
    end

    test "a template with no expressions renders verbatim" do
      rendered =
        render!(snapshot(), template(:plain, "static text"), :plain, supported_formats: [:plain])

      assert rendered.body == "static text"
    end

    test "script-like text that the syntax validator permits is literal, never evaluated" do
      body = "value ${alert.title} and <script>alert(1)</script> stays text"

      rendered =
        render!(snapshot(), template(:plain, body), :plain, supported_formats: [:plain])

      assert rendered.body == body
    end
  end

  describe "filters" do
    defp filtered(body, alert \\ nil) do
      render!(
        alert || snapshot(),
        template(:plain, body),
        :plain,
        supported_formats: [:plain]
      ).body
    end

    test "upper" do
      assert filtered("{{ alert.severity | upper }}") == "CRITICAL"
    end

    test "lower" do
      assert filtered("{{ alert.severity | lower }}", snapshot(%{"severity" => "CRITICAL"})) ==
               "critical"
    end

    test "truncate marks the cut and keeps the total length at the limit" do
      assert filtered("{{ alert.title | truncate: 10 }}") == "Device ..."
      assert String.length(filtered("{{ alert.title | truncate: 10 }}")) == 10
    end

    test "truncate leaves a short value untouched" do
      assert filtered("{{ alert.severity | truncate: 100 }}") == "critical"
    end

    test "json quotes and escapes, so it is safe inside a JSON document" do
      alert = snapshot(%{"title" => ~s(He said "hi"\nthen left)})

      assert filtered("{{ alert.title | json }}", alert) == ~s("He said \\"hi\\"\\nthen left")
    end

    test "json encodes a structured value" do
      assert filtered("{{ alert.metadata.region | json }}") == ~s("us-east-1")
    end

    test "url_encode" do
      assert filtered("{{ alert.severity | url_encode }}") == "critical"
      assert filtered("{{ alert.title | url_encode }}") == "Device+tonka01+is+unreachable"
    end

    test "iso8601 formats a DateTime" do
      assert filtered("{{ alert.first_seen_at | iso8601 }}") == "2026-08-09T12:00:00Z"
    end

    test "iso8601 normalises a string timestamp and passes an unparseable one through" do
      alert = snapshot(%{"first_seen_at" => "2026-08-09T12:00:00Z"})
      assert filtered("{{ alert.first_seen_at | iso8601 }}", alert) == "2026-08-09T12:00:00Z"

      alert = snapshot(%{"first_seen_at" => "not a timestamp"})
      assert filtered("{{ alert.first_seen_at | iso8601 }}", alert) == "not a timestamp"
    end

    test "default fills a missing value" do
      assert filtered(~s({{ device.hostname | default: "unknown" }})) == "unknown"
    end

    test "default fills a present-but-blank value" do
      alert = snapshot(%{"source" => "   "})
      assert filtered(~s({{ alert.source | default: "unknown" }}), alert) == "unknown"
    end

    test "default does not override a present value" do
      assert filtered(~s({{ alert.severity | default: "unknown" }})) == "critical"
    end

    test "default accepts a number" do
      assert filtered("{{ alert.occurrence_count | default: 0 }}") == "0"
    end

    test "a default argument containing a pipe stays one filter segment" do
      # This is exactly why the pipeline splitter is quote-aware; splitting
      # naively on `|` would turn the fallback into a bogus second filter.
      assert filtered(~s({{ device.hostname | default: "a|b" }})) == "a|b"
    end

    test "filters chain left to right" do
      assert filtered("{{ alert.title | upper | truncate: 10 }}") == "DEVICE ..."
      assert filtered(~s({{ device.hostname | default: "eth0" | upper }})) == "ETH0"
    end

    test "the seven filters are exactly the ones the syntax validator publishes" do
      assert Enum.sort(Syntax.filters()) ==
               Enum.sort(~w(upper lower truncate json url_encode iso8601 default))
    end
  end

  # --- unresolvable variables ----------------------------------------------

  describe "unresolvable variables" do
    test "a missing path renders empty and is reported, not raised" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "host={{ device.hostname }}."),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.body == "host=."

      assert [%Renderer.Unresolved{} = note] = rendered.unresolved
      assert note.path == "device.hostname"
      assert note.expression == "{{ device.hostname }}"
      assert note.location == :body
      assert note.reason == :missing
      refute note.default_applied?

      assert Rendered.unresolved?(rendered)
      assert Rendered.unresolved_paths(rendered) == ["device.hostname"]
    end

    test "a present-but-nil path is reported with its own reason" do
      rendered =
        render!(
          snapshot(%{"resolved_at" => nil}),
          template(:plain, "{{ alert.resolved_at }}"),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.body == ""
      assert [%{reason: :nil_value, path: "alert.resolved_at"}] = rendered.unresolved
    end

    test "a default-covered gap is reported but does not count as unresolved" do
      rendered =
        render!(
          snapshot(),
          template(:plain, ~s({{ device.hostname | default: "unknown" }})),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.body == "unknown"
      assert [%{path: "device.hostname", default_applied?: true}] = rendered.unresolved

      # The operator declared the fallback, so this is not a defect to surface.
      refute Rendered.unresolved?(rendered)
      assert Rendered.unresolved_paths(rendered) == []
    end

    test "unresolved notes record which half of the template they came from" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "{{ device.ip }}", "{{ device.name }}"),
          :plain,
          supported_formats: [:plain]
        )

      assert [subject_note, body_note] = rendered.unresolved
      assert subject_note.location == :subject
      assert subject_note.path == "device.name"
      assert body_note.location == :body
      assert body_note.path == "device.ip"
    end

    test "several unresolved variables are all reported" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "{{ device.ip }} {{ device.mac }} {{ device.ip }}"),
          :plain,
          supported_formats: [:plain]
        )

      assert length(rendered.unresolved) == 3
      assert Rendered.unresolved_paths(rendered) == ["device.ip", "device.mac"]
    end

    test "an alert missing every optional field still renders" do
      rendered =
        render!(
          %{},
          template(:plain, "{{ alert.title }}|{{ alert.severity }}"),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.body == "|"
      assert Rendered.unresolved_paths(rendered) == ["alert.severity", "alert.title"]
    end
  end

  # --- format negotiation ---------------------------------------------------

  describe "format negotiation" do
    test "an explicitly requested, declared format is used" do
      rendered =
        render!(
          snapshot(),
          template(:markdown, "body"),
          :markdown,
          supported_formats: [:markdown, :plain]
        )

      assert rendered.payload_format == :markdown
    end

    test "a format the provider does not declare is a typed error, never a substitution" do
      assert {:error, {:unsupported_payload_format, details}} =
               Renderer.render(snapshot(), template(:slack_blocks, "body"), :slack_blocks,
                 supported_formats: [:markdown, :plain]
               )

      assert details.requested == :slack_blocks
      assert details.supported == [:markdown, :plain]
      assert Renderer.describe_error({:unsupported_payload_format, details}) =~ "slack_blocks"
    end

    test "with no requested format the richest declared format wins" do
      assert {:ok, :slack_blocks} = Renderer.negotiate_format(nil, [:plain, :slack_blocks])
      assert {:ok, :discord_embed} = Renderer.negotiate_format(nil, [:markdown, :discord_embed])
      assert {:ok, :json} = Renderer.negotiate_format(nil, [:plain, :json, :markdown])
      assert {:ok, :plain} = Renderer.negotiate_format(nil, [:plain])
    end

    test "preference order is the module's declared order" do
      assert Renderer.payload_formats() == [
               :slack_blocks,
               :discord_embed,
               :pagerduty_v2,
               :json,
               :html,
               :markdown,
               :plain
             ]
    end

    test "an unknown format name is rejected without String.to_atom" do
      never_seen = "format_#{System.unique_integer([:positive])}"

      assert {:error, {:unknown_payload_format, ^never_seen}} =
               Renderer.negotiate_format(never_seen, [:plain])

      # Rejecting the name did not mint an atom for it, which is the whole
      # difference between an allowlist and String.to_atom/1.
      assert_raise ArgumentError, fn -> String.to_existing_atom(never_seen) end

      assert {:error, {:unknown_payload_format, :telepathy}} =
               Renderer.negotiate_format(:telepathy, [:plain])
    end

    test "a string format name resolves through the fixed map" do
      assert {:ok, :slack_blocks} = Renderer.negotiate_format("slack_blocks", [:slack_blocks])
      assert {:ok, :pagerduty_v2} = Renderer.parse_format("pagerduty_v2")
    end

    test "a provider declaring no format is an error" do
      assert {:error, {:no_supported_payload_format, []}} = Renderer.negotiate_format(nil, [])
      assert {:error, {:no_supported_payload_format, nil}} = Renderer.negotiate_format(nil, nil)
    end

    test "supported_formats is required, because a channel is never asked for an undeclared format" do
      assert {:error, {:missing_option, :supported_formats}} =
               Renderer.render(snapshot(), template(:plain, "body"), :plain)

      assert Renderer.describe_error({:missing_option, :supported_formats}) =~ "declared"
    end

    test "a template resolved for the wrong format is refused rather than rendered" do
      assert {:error, {:template_format_mismatch, details}} =
               Renderer.render(snapshot(), template(:markdown, "body"), :json,
                 supported_formats: [:json]
               )

      assert details.template == :markdown
      assert details.negotiated == :json
    end

    test "a template with no declared format renders under the negotiated one" do
      rendered =
        render!(
          snapshot(),
          %{body_template: "hello"},
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.payload_format == :plain
    end

    test "every declared payload format has a renderer module" do
      for format <- @all_formats do
        assert {:ok, module} = Renderer.format_module(format)
        assert module.payload_format() == format
      end
    end
  end

  # --- template validation ---------------------------------------------------

  describe "template validation at render time" do
    test "an unknown variable path is a typed error, not a raise and not a blank" do
      assert {:error, {:invalid_template, %{field: :body_template, message: message}}} =
               Renderer.render(snapshot(), template(:plain, "{{ alert.nonsense }}"), :plain,
                 supported_formats: [:plain]
               )

      assert message =~ "alert.nonsense"
    end

    test "an unknown filter is refused" do
      assert {:error, {:invalid_template, %{message: message}}} =
               Renderer.render(snapshot(), template(:plain, "{{ alert.title | exec }}"), :plain,
                 supported_formats: [:plain]
               )

      assert message =~ "exec"
    end

    test "EEx and interpolation markers are refused rather than evaluated" do
      for marker <- ["<%= alert %>", "{% if x %}", "\#{System.halt()}"] do
        assert {:error, {:invalid_template, _details}} =
                 Renderer.render(snapshot(), template(:plain, marker), :plain,
                   supported_formats: [:plain]
                 )
      end
    end

    test "a broken subject template is attributed to the subject field" do
      assert {:error, {:invalid_template, %{field: :subject_template}}} =
               Renderer.render(
                 snapshot(),
                 template(:plain, "ok", "{{ alert.nope }}"),
                 :plain,
                 supported_formats: [:plain]
               )
    end

    test "a missing body template is a typed error" do
      assert {:error, {:missing_body_template, :plain}} =
               Renderer.render(snapshot(), %{payload_format: :plain}, :plain,
                 supported_formats: [:plain]
               )
    end

    test "a non-map alert snapshot is refused" do
      assert {:error, {:invalid_alert_snapshot, "nope"}} =
               Renderer.render("nope", template(:plain, "x"), :plain, supported_formats: [:plain])
    end
  end

  # --- redaction and digest -------------------------------------------------

  describe "redaction" do
    @json_body ~s({"api_key": {{ alert.metadata.api_key | json }}, "text": {{ alert.title | json }}})

    test "the wire payload keeps the content but the persistable copy is redacted" do
      rendered =
        render!(snapshot(), template(:json, @json_body), :json, supported_formats: [:json])

      # What the transport sends is the notification itself.
      assert rendered.payload["api_key"] == @secret
      assert rendered.payload["text"] == "Device tonka01 is unreachable"

      # What may be persisted or logged is not.
      assert rendered.redacted_payload["api_key"] == "[REDACTED]"
      assert rendered.redacted_payload["text"] == "Device tonka01 is unreachable"
    end

    test "the policy version is the northbound one, not a second policy" do
      rendered =
        render!(snapshot(), template(:json, @json_body), :json, supported_formats: [:json])

      assert rendered.redaction_policy_version == "northbound-action-redaction-v1"
    end

    test "a capability token in an action link is scrubbed from the persistable copy" do
      rendered =
        render!(
          snapshot(),
          template(:markdown, "See {{ links.acknowledge }}"),
          :markdown,
          supported_formats: [:markdown],
          links: links(),
          sensitive_values: [@token]
        )

      assert rendered.payload["body"] =~ @token
      refute rendered.redacted_payload["body"] =~ @token
      assert rendered.redacted_payload["body"] =~ "[REDACTED]"
    end

    test "scrubbing reaches nested structures" do
      rendered =
        render!(
          snapshot(),
          template(:slack_blocks, "body"),
          :slack_blocks,
          supported_formats: [:slack_blocks],
          links: links(),
          sensitive_values: [@token]
        )

      refute rendered.redacted_payload |> Jason.encode!() |> String.contains?(@token)
      assert rendered.payload |> Jason.encode!() |> String.contains?(@token)
    end

    test "a value too short to be a credential is not blanket-replaced" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "{{ alert.title }}"),
          :plain,
          supported_formats: [:plain],
          sensitive_values: ["is"]
        )

      assert rendered.redacted_payload["body"] == "Device tonka01 is unreachable"
    end
  end

  describe "digest" do
    test "is stable across renders of identical input" do
      opts = [supported_formats: [:plain], links: links()]
      alert = snapshot()
      tmpl = template(:plain, "{{ alert.title }} {{ alert.severity }}")

      first = render!(alert, tmpl, :plain, opts)
      second = render!(alert, tmpl, :plain, opts)

      assert is_binary(first.digest)
      assert first.digest == second.digest
    end

    test "changes when the rendered content changes" do
      opts = [supported_formats: [:plain]]
      tmpl = template(:plain, "{{ alert.title }}")

      first = render!(snapshot(), tmpl, :plain, opts)
      second = render!(snapshot(%{"title" => "Something else"}), tmpl, :plain, opts)

      refute first.digest == second.digest
    end

    test "is computed over the redacted copy, so a secret never enters the hash" do
      # Two alerts differing ONLY in a redacted value hash the same. That is the
      # proof the digest is taken after redaction, not before.
      opts = [supported_formats: [:json]]
      tmpl = template(:json, @json_body)

      first = render!(snapshot(), tmpl, :json, opts)

      second =
        render!(
          snapshot(%{"metadata" => %{"api_key" => "sk-live-totally-different"}}),
          tmpl,
          :json,
          opts
        )

      assert first.digest == second.digest
      refute first.payload == second.payload
    end

    test "is unaffected by a per-delivery capability token" do
      # Two deliveries of the same alert mint different tokens. Without this
      # property every failover hop would look like different content and the
      # column could not answer "did these two deliveries carry the same thing?".
      token_a = "cap_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      token_b = "cap_bbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      tmpl = template(:markdown, "ack: {{ links.acknowledge }}")

      first =
        render!(snapshot(), tmpl, :markdown,
          supported_formats: [:markdown],
          links: links_for(token_a),
          sensitive_values: [token_a]
        )

      second =
        render!(snapshot(), tmpl, :markdown,
          supported_formats: [:markdown],
          links: links_for(token_b),
          sensitive_values: [token_b]
        )

      refute first.payload == second.payload
      assert first.digest == second.digest
    end

    test "key insertion order does not change the digest" do
      opts = [supported_formats: [:json]]
      tmpl = template(:json, @json_body)

      forward = render!(snapshot(), tmpl, :json, opts)

      reordered =
        snapshot()
        |> Map.delete("title")
        |> Map.put("title", "Device tonka01 is unreachable")

      assert forward.digest == render!(reordered, tmpl, :json, opts).digest
    end
  end

  # --- provenance and the stream exemption ----------------------------------

  describe "delivery provenance" do
    test "records the format actually rendered and the provider version" do
      rendered =
        render!(
          snapshot(),
          template(:markdown, "body"),
          nil,
          supported_formats: [:markdown, :plain],
          provider_version: 3
        )

      assert rendered.payload_format == :markdown
      assert rendered.provider_version == 3
    end

    test "provider_version is nil when the caller does not stamp one" do
      rendered =
        render!(snapshot(), template(:plain, "body"), :plain, supported_formats: [:plain])

      assert rendered.provider_version == nil
    end
  end

  describe "stream exemption (design D7)" do
    test "action links are dropped from the variable context, not merely from the payload" do
      rendered =
        render!(
          snapshot(),
          template(
            :json,
            ~s({"ack": {{ links.acknowledge | default: "" | json }}, "alert": {{ links.alert | json }}})
          ),
          :json,
          supported_formats: [:json],
          links: links(),
          include_action_links?: false
        )

      # A hand-written template cannot reintroduce a capability token into a
      # broadcast: the value is simply not in scope.
      assert rendered.payload["ack"] == ""
      assert rendered.payload["alert"] == "https://serviceradar.example.com/alerts/0198"
      refute rendered.body =~ @token
    end

    test "the same template does carry the link when links are permitted" do
      rendered =
        render!(
          snapshot(),
          template(:json, ~s({"ack": {{ links.acknowledge | json }}})),
          :json,
          supported_formats: [:json],
          links: links()
        )

      assert rendered.payload["ack"] =~ @token
    end
  end

  # --- purity ---------------------------------------------------------------

  describe "purity" do
    test "renders identically twice, and invents no timestamp of its own" do
      alert = Map.delete(snapshot(), "first_seen_at")
      tmpl = template(:pagerduty_v2, "body")
      opts = [supported_formats: [:pagerduty_v2], dedupe_key: "k"]

      first = render!(alert, tmpl, :pagerduty_v2, opts)
      second = render!(alert, tmpl, :pagerduty_v2, opts)

      assert first.payload == second.payload
      refute Map.has_key?(first.payload["payload"], "timestamp")
    end

    test "system.now is an input, not a clock read" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "{{ system.now | iso8601 }}"),
          :plain,
          supported_formats: [:plain],
          context: %{"system" => %{"now" => ~U[2026-01-01 00:00:00Z]}}
        )

      assert rendered.body == "2026-01-01T00:00:00Z"
    end

    test "an absent system.now is reported rather than filled in from the clock" do
      rendered =
        render!(
          snapshot(),
          template(:plain, "{{ system.now }}"),
          :plain,
          supported_formats: [:plain]
        )

      assert rendered.body == ""
      assert Rendered.unresolved_paths(rendered) == ["system.now"]
    end
  end

  describe "render_string/4" do
    test "renders a standalone template for previews" do
      assert {:ok, "hello CRITICAL", []} =
               Renderer.render_string(
                 "hello {{ alert.severity | upper }}",
                 %{"alert" => %{"severity" => "critical"}}
               )
    end

    test "reports unresolved paths without raising" do
      assert {:ok, "", [%{path: "alert.title"}]} =
               Renderer.render_string("{{ alert.title }}", %{})
    end

    test "refuses an invalid template" do
      assert {:error, {:invalid_template, _details}} =
               Renderer.render_string("{{ alert.nope }}", %{})
    end

    test "escapes according to the chosen format" do
      assert {:ok, "&lt;b&gt;", []} =
               Renderer.render_string(
                 "{{ alert.title }}",
                 %{"alert" => %{"title" => "<b>"}},
                 :html
               )
    end
  end
end
