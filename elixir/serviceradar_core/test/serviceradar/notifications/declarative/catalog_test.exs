defmodule ServiceRadar.Notifications.Declarative.CatalogTest do
  @moduledoc """
  The seeded declarative catalog is data, so these tests are database-free and
  async (tasks 2.4.1, 2.4.1b, 2.5.3a).

  The catalog is the executable proof that the declarative tier needs no
  ServiceRadar code, and this file is what fails when that stops being true: an
  entry that does not validate, an entry that forgot `test` and so cannot be
  test-sent before saving, a credential field the dispatcher would never resolve,
  a schema `PluginConfigForm` cannot render, or a document whose fingerprint does
  not survive the `jsonb` round-trip and would therefore look operator-edited on
  the very next boot.

  `Definition.parse/1` already runs over every entry at COMPILE time, so a
  malformed document fails the build. These tests assert the properties the
  validator does not decide - the ones that are about the catalog being useful
  rather than about the document being well formed.

  The last section drives three SHIPPED entries through
  `ServiceRadar.Notifications.Transports.Declarative` and asserts the exact bytes
  they put on the wire. That is the one check that ties the catalog to the
  engine: `Transports.DeclarativeTest` covers the engine with documents written
  for it, and a document that renders correctly there can still be a document
  that describes the destination wrongly. Nothing here reaches the network - the
  destination is a function plug injected through `req_options` - and the hosts
  are public IP literals so the outbound URL policy never needs DNS.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Declarative.Catalog
  alias ServiceRadar.Notifications.Declarative.Definition
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.ProviderSeeder
  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.SeedFingerprint
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.Declarative
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.SecretRefs

  @moduletag :capture_log

  defp attrs, do: Catalog.provider_attrs()

  defp by_key, do: Map.new(attrs(), &{&1.provider_key, &1})

  # What a channel bound to each entry would carry. A credential field holds a
  # stored reference, never the credential.
  @ref SecretRefs.network_credential_ref("0198f0aa-2222-7000-8000-000000000001")

  defp admissible_configurations do
    [
      {"pagerduty", %{"routing_key" => @ref, "severity" => "critical"}},
      {"pagerduty",
       %{
         "routing_key" => @ref,
         "severity" => "warning",
         "api_base_url" => "https://events.eu.pagerduty.com"
       }},
      {"opsgenie", %{"api_key" => @ref}},
      {"opsgenie",
       %{"api_key" => @ref, "priority" => "P1", "api_base_url" => "https://api.eu.opsgenie.com"}},
      {"mattermost", %{"webhook_url" => @ref}},
      {"mattermost", %{"webhook_url" => @ref, "username" => "ServiceRadar NOC"}},
      {"rocketchat", %{"webhook_url" => @ref, "alias" => "ServiceRadar"}},
      {"googlechat", %{"webhook_url" => @ref}},
      {"teams", %{"webhook_url" => @ref}},
      {"telegram", %{"bot_token" => @ref, "chat_id" => "-1001234567890"}},
      {"ntfy", %{"topic" => "serviceradar-noc", "access_token" => @ref}},
      {"ntfy",
       %{
         "topic" => "serviceradar-noc",
         "access_token" => @ref,
         "base_url" => "https://ntfy.example.com"
       }},
      {"gotify", %{"base_url" => "https://gotify.example.com", "app_token" => @ref}}
    ]
  end

  # --- the catalog exists (task 2.5.3a) --------------------------------------

  describe "the catalog exists" do
    test "is non-empty, so the declarative tier is usable at install" do
      # The whole claim of design D2 is that an operator does not wait for a
      # release to reach a destination. A catalog of zero would make that a
      # promise instead of a shipped feature.
      refute attrs() == []
      assert length(attrs()) == length(Catalog.definitions())
    end

    test "every entry parses as a provider definition" do
      # Same validator an uploaded document passes: a first-party origin buys no
      # relaxed validation path.
      for entry <- attrs() do
        assert {:ok, %Definition{}} = Definition.parse(entry.definition),
               "#{entry.provider_key} does not validate as a declarative definition"
      end
    end

    test "the stored document is the canonical one and reparses identically" do
      # `NotificationProvider.definition` holds `to_map/1` output rather than the
      # bytes an author typed, which is what makes the fingerprint stable across
      # the jsonb round-trip.
      for definition <- Catalog.definitions() do
        assert {:ok, reparsed} = Definition.parse(Definition.to_map(definition))
        assert reparsed == definition
      end
    end

    test "every key is unique and none collides with a native provider" do
      keys = Enum.map(attrs(), & &1.provider_key)

      assert Enum.uniq(keys) == keys
      assert keys == Catalog.keys()

      native = Enum.map(ProviderSeeder.default_providers(), & &1.provider_key)
      assert MapSet.disjoint?(MapSet.new(keys), MapSet.new(native))
    end

    test "the seeder reconciles the native catalog and this one, in one list" do
      seeded = Enum.map(ProviderSeeder.seeded_providers(), & &1.provider_key)

      for key <- Catalog.keys() do
        assert key in seeded, "#{key} would never be seeded"
      end

      for key <- Enum.map(ProviderSeeder.default_providers(), & &1.provider_key) do
        assert key in seeded
      end
    end
  end

  # --- the tier contract -----------------------------------------------------

  describe "the tier contract" do
    test "every entry declares both send and test (task 2.4.1b)" do
      # Without `test` the catalog entry cannot be test-sent before a channel is
      # saved, which is the one moment an operator finds out the destination
      # rejects the payload.
      for entry <- attrs() do
        assert Transport.declares_required_capabilities?(entry.capabilities),
               "#{entry.provider_key} must declare send and test"
      end
    end

    test "every declared capability is one this tier can honour" do
      allowed = MapSet.new(Definition.allowed_capabilities())

      for entry <- attrs(), capability <- entry.capabilities do
        assert MapSet.member?(allowed, capability),
               "#{entry.provider_key} claims #{inspect(capability)}, which a request template " <>
                 "engine cannot implement"
      end
    end

    test "capabilities are sorted, so reordering the document is not an operator edit" do
      for entry <- attrs() do
        assert entry.capabilities == Enum.sort(entry.capabilities)
      end
    end

    test "every entry is declarative, carries a definition, and names no module" do
      for entry <- attrs() do
        assert entry.provider_type == :declarative
        assert is_map(entry.definition)
        assert is_nil(entry.implementation_module)
      end
    end

    test "no entry appears in the native transport allowlist" do
      # The catalog is the proof that this tier needs no compile-time entry
      # anywhere. If a key ever needed one, it would not be a declarative
      # provider.
      allowlist = MapSet.new(NotificationProvider.implementation_module_allowlist())

      for key <- Catalog.keys() do
        refute MapSet.member?(allowlist, key)
      end
    end

    test "every entry runs on the control plane only" do
      # There is no plugin-backed edge execution path for an uploaded document,
      # and a route that does not exist may not be declared.
      for entry <- attrs() do
        assert entry.supported_routes == [:control_plane]
      end
    end

    test "every declared payload format is one the renderer can render" do
      known = MapSet.new(Renderer.payload_formats())

      for entry <- attrs() do
        assert entry.payload_formats != [],
               "#{entry.provider_key} would negotiate no format at all"

        for format <- entry.payload_formats do
          assert MapSet.member?(known, format)
        end
      end
    end

    test "every entry ships managed, first-party, and versioned" do
      for entry <- attrs() do
        assert entry.managed, "#{entry.provider_key} must be managed to be reconcilable"
        assert entry.source == :first_party
        assert entry.template_version == Catalog.template_version()
        assert is_binary(entry.template_version) and entry.template_version != ""
      end
    end

    test "no entry carries a status, because a provider is activated deliberately" do
      # `status` is what makes an operator's disable survive an upgrade: the
      # seeder never writes it, and `:seed_managed` excludes it from
      # `upsert_fields`.
      for entry <- attrs() do
        refute Map.has_key?(entry, :status)
      end
    end
  end

  # --- the request each entry issues ----------------------------------------

  describe "the request" do
    test "every URL is https or supplies its scheme by substitution" do
      for definition <- Catalog.definitions() do
        url = definition.request.url

        assert String.starts_with?(url, "https://") or String.starts_with?(url, "{{"),
               "#{definition.key} would be refused by the outbound URL policy"
      end
    end

    test "every credential-shaped header reads from secrets, never from config" do
      for definition <- Catalog.definitions(),
          {name, value} <- definition.request.headers,
          name in ["authorization", "x-gotify-key"] do
        assert String.contains?(value, "{{ secrets."),
               "#{definition.key} would store a credential in the non-sensitive definition column"
      end
    end

    test "every secrets.* path a template addresses is a declared secretRef field" do
      # `SecretRefs.resolve_runtime_params/3` writes each resolved secret back
      # under its schema field name, so a template naming anything else resolves
      # to an empty string and the destination answers 401 during an incident.
      for definition <- Catalog.definitions() do
        declared =
          definition.config_schema
          |> SecretRefs.secret_ref_fields()
          |> Enum.map(&("secrets." <> SecretRefs.runtime_field_name(&1)))
          |> Enum.sort()

        assert Definition.secret_paths(definition) == declared
      end
    end

    test "every entry that authenticates declares exactly one credential field" do
      for definition <- Catalog.definitions() do
        assert length(Definition.secret_paths(definition)) == 1,
               "#{definition.key} should carry exactly one credential"
      end
    end

    test "success is 2xx and never overlaps the retryable set" do
      for definition <- Catalog.definitions() do
        for {low, high} <- definition.success_status do
          assert low >= 200 and high <= 299
        end

        success =
          MapSet.new(
            Enum.flat_map(definition.success_status, &Enum.to_list(elem(&1, 0)..elem(&1, 1)))
          )

        retryable =
          MapSet.new(
            Enum.flat_map(definition.retryable_status, &Enum.to_list(elem(&1, 0)..elem(&1, 1)))
          )

        assert MapSet.disjoint?(success, retryable)
      end
    end

    test "a rate limit is retryable and a rejected payload is terminal" do
      # The classification the retry decision reads. A 4xx that is not 408 or 429
      # is the destination telling us the request is wrong; repeating it five
      # times only delays the operator learning that.
      for definition <- Catalog.definitions() do
        assert Definition.classify_status(definition, 429) == :retryable
        assert Definition.classify_status(definition, 503) == :retryable
        assert Definition.classify_status(definition, 401) == :permanent
        assert Definition.classify_status(definition, 400) == :permanent
      end
    end

    test "a declared correlation path is a body path, since no entry returns a header handle" do
      for definition <- Catalog.definitions(), correlation = definition.correlation do
        assert correlation.from == :body
        assert correlation.path != []
      end
    end
  end

  # --- config schemas --------------------------------------------------------

  describe "config schemas" do
    test "every schema passes the constrained JSON Schema subset" do
      for entry <- attrs() do
        assert ConfigSchema.validate_schema(entry.config_schema) == :ok,
               "#{entry.provider_key} ships a schema PluginConfigForm cannot render"
      end
    end

    test "the provider row's schema is the document's schema" do
      # Two copies would drift, and the channel form is generated from the row.
      for definition <- Catalog.definitions() do
        assert by_key()[definition.key].config_schema == definition.config_schema
      end
    end

    test "every schema is a closed object" do
      for entry <- attrs() do
        assert entry.config_schema["type"] == "object"
        assert entry.config_schema["additionalProperties"] == false
      end
    end

    test "every required key is a declared property" do
      for entry <- attrs() do
        properties = Map.keys(entry.config_schema["properties"])

        for field <- Map.get(entry.config_schema, "required", []) do
          assert field in properties,
                 "#{entry.provider_key} requires a key it does not declare"
        end
      end
    end

    test "a credential field accepts a stored reference rather than a shaped value" do
      # The stored value is a `credentialref:...` string, so a `format`,
      # `pattern`, or `enum` on a secretRef property would reject every reference
      # an operator can actually save.
      for entry <- attrs(), field <- SecretRefs.secret_ref_fields(entry.config_schema) do
        property = entry.config_schema["properties"][field]

        assert property["type"] == "string"
        assert is_binary(property["credentialKind"])
        refute Map.has_key?(property, "format")
        refute Map.has_key?(property, "pattern")
        refute Map.has_key?(property, "enum")
        refute Map.has_key?(property, "maxLength")
      end
    end

    test "a configuration the schema admits is one the schema still admits normalised" do
      for {provider_key, config} <- admissible_configurations() do
        schema = by_key()[provider_key].config_schema
        normalized = ConfigSchema.normalize_params(schema, config)

        assert ConfigSchema.validate_params(schema, normalized) == :ok,
               "#{provider_key} schema rejected its own example"
      end
    end

    test "a missing credential is refused at save time, not at 3am" do
      for entry <- attrs() do
        required = Map.get(entry.config_schema, "required", [])
        secrets = SecretRefs.secret_ref_fields(entry.config_schema)

        assert secrets -- required == [],
               "#{entry.provider_key} lets a channel be saved without its credential"
      end
    end
  end

  # --- reconciliation contract ----------------------------------------------

  describe "PagerDuty action links" do
    test "the acknowledge links are top-level links, not custom_details text" do
      # PagerDuty renders custom_details as a flat key/value blob, so an
      # acknowledge URL placed there arrives as inert text an on-call engineer
      # has to select and paste. `links` is what PagerDuty renders as clickable.
      body = get_in(by_key()["pagerduty"], [:definition, "request", "body"])

      hrefs = Enum.map(body["links"], & &1["href"])

      assert "{{ links.acknowledge }}" in hrefs
      assert "{{ links.snooze }}" in hrefs
      assert "{{ links.resolve }}" in hrefs
      assert "{{ links.alert }}" in hrefs

      details = get_in(body, ["payload", "custom_details"])

      for key <- ["acknowledge_url", "snooze_url", "resolve_url"] do
        refute Map.has_key?(details, key),
               "#{key} is back in custom_details, where PagerDuty renders it as text"
      end
    end

    test "every link carries the text PagerDuty labels it with" do
      body = get_in(by_key()["pagerduty"], [:definition, "request", "body"])

      for link <- body["links"] do
        assert is_binary(link["text"]) and link["text"] != "",
               "a link with no text renders as a bare URL"
      end
    end
  end

  describe "reconciliation contract" do
    test "the managed set for this tier covers the definition" do
      # Without it an operator's edit to a catalog entry's request template would
      # not read as divergence and would be silently overwritten, and a corrected
      # document could never be applied.
      fields = ProviderSeeder.managed_fields(%{provider_type: :declarative})

      assert :definition in fields
      refute :status in fields
      refute :default_max_attempts in fields
      refute :provider_key in fields
      refute :provider_type in fields
    end

    test "the native field list is untouched, so existing digests stay valid" do
      # Adding a field to a fingerprint's field list changes every digest computed
      # with it. The rows in the field carry digests stamped by an earlier release.
      refute :definition in ProviderSeeder.managed_fields()

      assert ProviderSeeder.managed_fields(%{provider_type: :native}) ==
               ProviderSeeder.managed_fields()
    end

    test "every managed field is one the provider :update action accepts" do
      accepted =
        NotificationProvider
        |> Ash.Resource.Info.action(:update)
        |> Map.fetch!(:accept)

      for field <- ProviderSeeder.managed_fields(%{provider_type: :declarative}) do
        assert field in accepted
      end
    end

    test "every catalog row has a distinct fingerprint" do
      digests = Enum.map(attrs(), &SeedFingerprint.fingerprint(&1, managed_fields(&1)))

      assert length(Enum.uniq(digests)) == length(digests)
    end

    test "a row survives its own jsonb round-trip" do
      # The check that catches a canonicalisation bug: if encoding and decoding
      # the document changed the digest, every catalog row would look
      # operator-edited on the first boot after it was written and nothing would
      # ever reconcile again.
      for entry <- attrs() do
        fields = managed_fields(entry)

        stored = %{
          entry
          | config_schema: jsonb(entry.config_schema),
            definition: jsonb(entry.definition)
        }

        assert SeedFingerprint.fingerprint(stored, fields) ==
                 SeedFingerprint.fingerprint(entry, fields),
               "#{entry.provider_key} does not survive its own jsonb round-trip"
      end
    end

    test "an edit to the request template reads as diverged" do
      entry = by_key()["pagerduty"]
      fields = managed_fields(entry)
      stamped = Map.put(entry, :template_fingerprint, SeedFingerprint.fingerprint(entry, fields))

      refute SeedFingerprint.diverged?(stamped, fields)

      edited =
        put_in(
          stamped,
          [:definition, "request", "url"],
          "https://events.eu.pagerduty.com/v2/enqueue"
        )

      assert SeedFingerprint.diverged?(edited, fields),
             "an operator's edit to the document would be silently overwritten"
    end

    test "raising default_max_attempts is not divergence" do
      entry = by_key()["opsgenie"]
      fields = managed_fields(entry)
      stamped = Map.put(entry, :template_fingerprint, SeedFingerprint.fingerprint(entry, fields))

      refute SeedFingerprint.diverged?(%{stamped | default_max_attempts: 10}, fields)
    end
  end

  # --- the catalog, delivered (task 2.4.1) ----------------------------------

  @host "93.184.216.34"
  @secret "gk-live-9a8b7c6d5e4f3g2h1i0j"

  @alert %{
    "id" => "44444444-4444-4444-4444-444444444444",
    "title" => "Disk 92% on db-01",
    "message" => "threshold breached on the primary volume",
    "severity" => "emergency",
    "status" => "firing",
    "alert_class" => "capacity",
    "source" => "sysmon",
    "occurrence_count" => 7,
    "first_seen_at" => "2026-08-09T12:00:00Z",
    "last_seen_at" => "2026-08-09T12:30:00Z"
  }

  @context %{
    "alert" => @alert,
    "device" => %{"name" => "db-01", "hostname" => "db-01.example.com", "ip" => "10.4.2.9"},
    "rule" => %{"name" => "Disk capacity", "category" => "capacity"},
    "links" => %{
      "alert" => "https://sr.example.com/alerts/44444444",
      "acknowledge" => "https://sr.example.com/n/ack/tok-1",
      "snooze" => "https://sr.example.com/n/snooze/tok-2",
      "resolve" => "https://sr.example.com/n/resolve/tok-3"
    },
    "system" => %{"name" => "ServiceRadar", "url" => "https://sr.example.com"}
  }

  describe "delivering a shipped catalog entry" do
    test "pagerduty enqueues an Events API v2 trigger, keyed on the alert" do
      result =
        deliver("pagerduty",
          config: %{"api_base_url" => "https://#{@host}", "severity" => "error"},
          secrets: %{"routing_key" => @secret},
          plug: json_plug(202, %{"status" => "success", "dedup_key" => "pd-9"})
        )

      assert %Result{disposition: :delivered} = result
      assert result.external_correlation_id == "pd-9"
      assert Result.outcome(result, true) == :sent

      assert_received {:sent, sent}
      assert sent.method == "POST"
      assert sent.path == "/v2/enqueue"

      body = Jason.decode!(sent.body)

      assert body["routing_key"] == @secret
      assert body["event_action"] == "trigger"

      # One PagerDuty incident per ServiceRadar alert, so a second occurrence
      # updates rather than pages twice.
      assert body["dedup_key"] == @alert["id"]

      # The pinned per-channel severity, NOT `alert.severity`: PagerDuty has no
      # `emergency` and would answer 400 on the alert that mattered most.
      assert body["payload"]["severity"] == "error"
      assert body["payload"]["summary"] == "[EMERGENCY] Disk 92% on db-01"
      assert body["payload"]["source"] == "db-01.example.com"
      assert body["payload"]["custom_details"]["serviceradar_severity"] == "emergency"
      assert body["payload"]["custom_details"]["occurrences"] == "7"
      assert body["payload"]["custom_details"]["alert_url"] =~ "/alerts/44444444"
    end

    test "gotify writes the app token to its header and keeps a numeric literal numeric" do
      result =
        deliver("gotify",
          config: %{"base_url" => "https://#{@host}"},
          secrets: %{"app_token" => @secret},
          plug: json_plug(200, %{"id" => 4242})
        )

      assert %Result{disposition: :delivered} = result

      # An integer id is a usable handle; the extractor stringifies it rather
      # than dropping it.
      assert result.external_correlation_id == "4242"

      assert_received {:sent, sent}
      assert sent.method == "POST"
      assert sent.path == "/message"
      assert header(sent, "x-gotify-key") == @secret

      body = Jason.decode!(sent.body)

      # A literal number in the document stays a number. Rendered as a string it
      # would be a 400 from a server that types its fields.
      assert body["priority"] == 5
      assert body["title"] == "EMERGENCY: Disk 92% on db-01"

      # And the credential is in the header and nowhere else.
      refute String.contains?(sent.body, @secret)
      refute inspect(result) =~ @secret
    end

    test "mattermost posts to the webhook whose URL is itself the credential" do
      result =
        deliver("mattermost",
          secrets: %{"webhook_url" => "https://#{@host}/hooks/9f2b1c7a4e5d6082"},
          plug: json_plug(200, "ok")
        )

      assert %Result{disposition: :delivered} = result

      assert_received {:sent, sent}
      assert sent.method == "POST"
      assert sent.path == "/hooks/9f2b1c7a4e5d6082"

      body = Jason.decode!(sent.body)

      # The channel set no username, so the document's own default is what goes
      # out - never an empty string, which Mattermost would treat as a name.
      assert body["username"] == "ServiceRadar"
      assert body["text"] =~ "**EMERGENCY: Disk 92% on db-01**"
      assert body["text"] =~ "Device: db-01 (10.4.2.9)"
      assert body["text"] =~ "Open: https://sr.example.com/alerts/44444444"

      # The one-click action link (design D7) reaches a chat destination the same
      # way it reaches Slack, because the document asks for it by name.
      assert body["text"] =~ "Acknowledge: https://sr.example.com/n/ack/tok-1"

      assert result.result_summary["unresolved"] in [nil, []]
    end

    test "a rate-limited destination is retryable rather than failed" do
      result =
        deliver("mattermost",
          secrets: %{"webhook_url" => "https://#{@host}/hooks/9f2b1c7a4e5d6082"},
          plug: json_plug(429, %{}, [{"retry-after", "30"}])
        )

      assert %Result{disposition: :retryable_failure} = result
      assert result.error_class == "http_429"
      assert result.retry_after_ms == 30_000
    end
  end

  defp managed_fields(entry), do: ProviderSeeder.managed_fields(entry)

  defp jsonb(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp definition!(provider_key) do
    Enum.find(Catalog.definitions(), &(&1.key == provider_key)) ||
      flunk("no catalog entry #{provider_key}")
  end

  describe "PagerDuty resolves the incident it opened (task 4.3.3b)" do
    test "a resolving alert sends event_action resolve on the same dedup_key" do
      # The bug this pins: with event_action hardcoded to "trigger", a resolving
      # ServiceRadar alert sent PagerDuty a trigger on the dedup_key of the
      # incident it should have closed - so the incident was updated and stayed
      # open until a human closed it by hand.
      context =
        Map.put(@context, "delivery", %{
          "lifecycle_reason" => "resolve",
          "event_action" => "resolve"
        })

      deliver("pagerduty",
        config: %{"api_base_url" => "https://#{@host}"},
        secrets: %{"routing_key" => @secret},
        context: context,
        plug: json_plug(202, %{"status" => "success", "dedup_key" => "pd-9"})
      )

      assert_received {:sent, sent}
      body = Jason.decode!(sent.body)

      assert body["event_action"] == "resolve"
      # Same key, or PagerDuty resolves nothing.
      assert body["dedup_key"] == @alert["id"]
    end

    test "every other lifecycle reason still triggers" do
      for reason <- ["fire", "renotify", "escalate"] do
        context =
          Map.put(@context, "delivery", %{
            "lifecycle_reason" => reason,
            "event_action" => "trigger"
          })

        deliver("pagerduty",
          config: %{"api_base_url" => "https://#{@host}"},
          secrets: %{"routing_key" => @secret},
          context: context,
          plug: json_plug(202, %{"status" => "success", "dedup_key" => "pd-9"})
        )

        assert_received {:sent, sent}
        assert Jason.decode!(sent.body)["event_action"] == "trigger"
      end
    end

    test "a context with no delivery namespace falls back to trigger, not empty" do
      # An unresolved variable renders as "" and PagerDuty rejects an empty
      # event_action outright, so the `default:` filter is what keeps a missing
      # namespace from turning a working notification into a 400.
      deliver("pagerduty",
        config: %{"api_base_url" => "https://#{@host}"},
        secrets: %{"routing_key" => @secret},
        context: Map.delete(@context, "delivery"),
        plug: json_plug(202, %{"status" => "success", "dedup_key" => "pd-9"})
      )

      assert_received {:sent, sent}
      assert Jason.decode!(sent.body)["event_action"] == "trigger"
    end
  end

  defp deliver(provider_key, opts) do
    Declarative.deliver(
      %Request{
        delivery_id: "11111111-1111-1111-1111-111111111111",
        alert_id: @alert["id"],
        channel_id: "22222222-2222-2222-2222-222222222222",
        provider_key: provider_key,
        payload_format: :plain,
        payload: %{"subject" => @alert["title"]},
        config: Keyword.get(opts, :config, %{}),
        secrets: Keyword.get(opts, :secrets, %{})
      },
      definition: definition!(provider_key),
      context: Keyword.get(opts, :context, @context),
      req_options: Keyword.take(opts, [:plug])
    )
  end

  defp json_plug(status, body, resp_headers \\ []) do
    test_pid = self()

    fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:sent,
         %{
           method: conn.method,
           path: conn.request_path,
           headers: conn.req_headers,
           body: request_body
         }}
      )

      resp_headers
      |> Enum.reduce(conn, fn {name, value}, acc ->
        Plug.Conn.put_resp_header(acc, name, value)
      end)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  defp header(sent, name) do
    Enum.find_value(sent.headers, fn {key, value} -> if key == name, do: value end)
  end
end
