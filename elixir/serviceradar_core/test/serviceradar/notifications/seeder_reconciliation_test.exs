defmodule ServiceRadar.Notifications.SeederReconciliationTest do
  @moduledoc """
  What the seeders do to rows that already exist.

  These need real rows - the whole question is what a second run does to what a
  first run wrote - so this is the one part of the seeder suite that takes a
  database.

  An upgrade is simulated by winding a seeded row's `template_version` back to
  `"0"`, which is exactly the state a release that bumped the shipped template
  leaves behind: a managed row stamped at a version the seeder no longer ships.
  From there the two outcomes that matter are asserted directly - an untouched
  row is advanced, an operator-edited one is not - along with the rule that
  outranks both: a provider an operator disabled is never re-enabled.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.Declarative.Catalog
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationTemplate
  alias ServiceRadar.Notifications.ProviderSeeder
  alias ServiceRadar.Notifications.SeedFingerprint
  alias ServiceRadar.Notifications.TemplateSeeder
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:notification_seeder_test)}
  end

  # --- helpers ---------------------------------------------------------------

  defp providers(actor) do
    NotificationProvider
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read!(actor: actor)
  end

  defp provider!(provider_key, actor) do
    assert [provider] =
             NotificationProvider
             |> Ash.Query.for_read(:read, %{}, actor: actor)
             |> Ash.Query.filter(provider_key == ^provider_key)
             |> Ash.read!(actor: actor)

    provider
  end

  defp template!(payload_format, actor) do
    assert [template] =
             NotificationTemplate
             |> Ash.Query.for_read(:read, %{}, actor: actor)
             |> Ash.Query.filter(
               alert_class == "default" and payload_format == ^payload_format and
                 is_nil(provider_key)
             )
             |> Ash.read!(actor: actor)

    template
  end

  defp update!(record, action, attrs, actor) do
    record
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  # The state a release that bumped the shipped template leaves behind: a managed
  # row still stamped at the previous version.
  defp wind_back_provider!(provider_key, actor, attrs \\ %{}) do
    update!(
      provider!(provider_key, actor),
      :update,
      Map.put(attrs, :template_version, "0"),
      actor
    )
  end

  defp catalog_entry(provider_key) do
    Enum.find(ProviderSeeder.default_providers(), &(&1.provider_key == provider_key))
  end

  defp declarative_entry(provider_key) do
    Enum.find(Catalog.provider_attrs(), &(&1.provider_key == provider_key))
  end

  # The state the PREVIOUS release left behind for a row nobody touched: that
  # release's content, that release's version, and a fingerprint that still
  # matches the content. It is the only state a reconcile is allowed to rewrite
  # content from, so it is the only way to prove that an upgrade really does
  # replace a stale document rather than merely bumping a version string.
  defp wind_back_pristine!(provider_key, actor, previous_attrs) do
    stale = Map.put(previous_attrs, :template_version, "0")

    update!(
      provider!(provider_key, actor),
      :update,
      %{
        definition: stale.definition,
        template_version: "0",
        template_fingerprint:
          SeedFingerprint.fingerprint(stale, ProviderSeeder.managed_fields(stale))
      },
      actor
    )
  end

  defp create_channel(provider_key, config, actor) do
    NotificationChannel
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "#{provider_key}-#{System.unique_integer([:positive])}",
        provider_id: provider!(provider_key, actor).id,
        config: config
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp create_channel!(provider_key, config, actor) do
    assert {:ok, channel} = create_channel(provider_key, config, actor)
    channel
  end

  # --- provider seeding ------------------------------------------------------

  describe "provider seeding" do
    test "seeds the whole first-party catalog and activates it", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()

      seeded = Map.new(providers(actor), &{&1.provider_key, &1})

      for expected <- ProviderSeeder.default_providers() do
        provider = Map.fetch!(seeded, expected.provider_key)

        assert provider.provider_type == expected.provider_type
        assert provider.capabilities == expected.capabilities
        assert provider.payload_formats == expected.payload_formats
        assert provider.supported_routes == expected.supported_routes
        assert provider.implementation_module == expected.implementation_module
        assert provider.config_schema == expected.config_schema
        assert provider.managed
        assert provider.template_version == expected.template_version

        assert provider.template_fingerprint ==
                 SeedFingerprint.fingerprint(expected, ProviderSeeder.managed_fields())

        # A `:draft` provider is a silent notification platform: `Suppression`
        # withholds every dispatch to a channel whose provider is not `:active`.
        assert provider.status == :active
      end
    end

    test "the stored row still matches its own fingerprint after the round-trip", %{actor: actor} do
      # The check that catches a canonicalisation bug: if the jsonb round-trip
      # changed the digest, every managed row would look operator-edited on the
      # very next boot and nothing would ever reconcile again.
      assert :ok = ProviderSeeder.seed_all()

      for provider <- providers(actor) do
        refute SeedFingerprint.diverged?(provider, ProviderSeeder.managed_fields(provider)),
               "#{provider.provider_key} does not survive its own jsonb round-trip"
      end
    end

    test "is idempotent", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()
      first = Map.new(providers(actor), &{&1.provider_key, &1})

      assert :ok = ProviderSeeder.seed_all()
      second = Map.new(providers(actor), &{&1.provider_key, &1})

      assert map_size(second) == map_size(first)

      for {key, provider} <- second do
        assert provider.id == first[key].id
        assert provider.updated_at == first[key].updated_at
        assert provider.template_fingerprint == first[key].template_fingerprint
      end
    end

    test "does not re-enable a provider an operator disabled", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()

      disabled = update!(provider!("slack", actor), :disable, %{}, actor)
      assert disabled.status == :disabled

      assert :ok = ProviderSeeder.seed_all()
      assert provider!("slack", actor).status == :disabled

      # And not across an upgrade that rewrites the row's managed content either.
      wind_back_provider!("slack", actor)
      assert :ok = ProviderSeeder.seed_all()

      slack = provider!("slack", actor)
      assert slack.status == :disabled
      assert slack.template_version == ProviderSeeder.template_version()
    end

    test "installs :stream as a first-party managed provider (task 4.4.2c)", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()

      stream = provider!("stream", actor)

      assert stream.provider_type == :stream
      assert stream.source == :first_party
      assert stream.managed
      assert stream.status == :active
      # The firehose is seeded, never operator-authored: `:stream` is a
      # provider_type, not a fourth extensibility tier.
      assert is_nil(stream.implementation_module)
    end

    test "does not re-enable a :stream provider an operator disabled (task 4.4.2c)", %{
      actor: actor
    } do
      # The mechanism is provider-agnostic and the slack case above already
      # exercises it. This pins it for `:stream` specifically because `:stream`
      # is a distinct provider_type and the seeder already branches on type
      # elsewhere (`managed_fields/1`); a future type-specific branch would slip
      # past a test that only ever disabled a `:native` row.
      assert :ok = ProviderSeeder.seed_all()

      disabled = update!(provider!("stream", actor), :disable, %{}, actor)
      assert disabled.status == :disabled

      assert :ok = ProviderSeeder.seed_all()
      assert provider!("stream", actor).status == :disabled

      wind_back_provider!("stream", actor)
      assert :ok = ProviderSeeder.seed_all()

      stream = provider!("stream", actor)
      assert stream.status == :disabled
      assert stream.template_version == ProviderSeeder.template_version()
    end

    test "activates a managed provider left in :draft", %{actor: actor} do
      # Self-healing. A boot where the create succeeded and the activation failed
      # would otherwise leave the provider permanently mute, and `:draft` can only
      # mean "seeded and never activated" - the state machine has no way back into
      # it, so this can never resurrect a disabled provider.
      attrs = catalog_entry("stream")

      draft =
        NotificationProvider
        |> Ash.Changeset.for_create(
          :seed_managed,
          Map.put(attrs, :template_fingerprint, "seeded-elsewhere"),
          actor: actor
        )
        |> Ash.create!(actor: actor)

      assert draft.status == :draft

      assert :ok = ProviderSeeder.seed_all()
      assert provider!("stream", actor).status == :active
    end

    test "advances an untouched managed provider across an upgrade", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()
      assert wind_back_provider!("webhook", actor).template_version == "0"

      assert :ok = ProviderSeeder.seed_all()

      webhook = provider!("webhook", actor)
      assert webhook.template_version == ProviderSeeder.template_version()
      assert webhook.managed
      assert webhook.status == :active
      assert webhook.display_name == catalog_entry("webhook").display_name
    end

    test "preserves an operator edit across an upgrade", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()
      wind_back_provider!("webhook", actor, %{display_name: "Webhook (NOC)"})

      assert :ok = ProviderSeeder.seed_all()

      webhook = provider!("webhook", actor)
      assert webhook.display_name == "Webhook (NOC)"

      # Left at the version it diverged from, so the skip stays visible instead of
      # looking like a successful reconcile.
      assert webhook.template_version == "0"
    end

    test "an operator-tuned retry bound is not divergence and still reconciles", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()
      wind_back_provider!("discord", actor, %{default_max_attempts: 10})

      assert :ok = ProviderSeeder.seed_all()

      discord = provider!("discord", actor)
      assert discord.template_version == ProviderSeeder.template_version()
      assert discord.default_max_attempts == 10
    end
  end

  # --- the seeded declarative catalog (tasks 2.4.1a, 2.4.2, 2.5.3) -----------

  describe "the seeded declarative catalog" do
    test "installs every entry active, managed, and first-party", %{actor: actor} do
      # Task 2.5.3a's other half: the catalog is not merely well formed, it is
      # actually in the database and actually dispatchable after a fresh install.
      # A catalog left in `:draft` is a catalog that pages nobody, because
      # `Suppression` withholds every dispatch to a channel whose provider is not
      # `:active`.
      assert :ok = ProviderSeeder.seed_all()

      seeded = Map.new(providers(actor), &{&1.provider_key, &1})
      refute Catalog.provider_attrs() == []

      for expected <- Catalog.provider_attrs() do
        provider = Map.fetch!(seeded, expected.provider_key)

        assert provider.provider_type == :declarative
        assert provider.source == :first_party
        assert provider.managed
        assert provider.status == :active

        # The proof that this tier needs no ServiceRadar code: the row carries a
        # document and names no module. The `notification_providers_native_module`
        # CHECK constraint would refuse one anyway.
        assert is_nil(provider.implementation_module)
        assert provider.definition == expected.definition
        assert provider.config_schema == expected.config_schema
        assert provider.capabilities == expected.capabilities
        assert :send in provider.capabilities
        assert :test in provider.capabilities
        assert provider.supported_routes == [:control_plane]
        assert provider.template_version == expected.template_version

        assert provider.template_fingerprint ==
                 SeedFingerprint.fingerprint(expected, ProviderSeeder.managed_fields(expected))
      end
    end

    test "advances an untouched entry's document across an upgrade", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()

      shipped = declarative_entry("pagerduty")

      previous =
        Map.put(
          shipped,
          :definition,
          put_in(
            shipped.definition,
            ["request", "url"],
            "https://events.pagerduty.com/v2/enqueue"
          )
        )

      stale = wind_back_pristine!("pagerduty", actor, previous)
      assert stale.definition["request"]["url"] == "https://events.pagerduty.com/v2/enqueue"

      assert :ok = ProviderSeeder.seed_all()

      pagerduty = provider!("pagerduty", actor)
      assert pagerduty.template_version == Catalog.template_version()
      assert pagerduty.definition == shipped.definition
      assert pagerduty.status == :active

      refute SeedFingerprint.diverged?(pagerduty, ProviderSeeder.managed_fields(pagerduty))
    end

    test "preserves an operator-edited document across an upgrade", %{actor: actor} do
      # `:definition` is in this tier's fingerprint precisely so that this holds.
      # Were it not, an operator who corrected a request template for their own
      # destination would find the correction gone after the next release.
      assert :ok = ProviderSeeder.seed_all()

      edited =
        put_in(
          declarative_entry("opsgenie").definition,
          ["request", "headers", "x-serviceradar-deployment"],
          "noc"
        )

      wind_back_provider!("opsgenie", actor, %{definition: edited})

      assert :ok = ProviderSeeder.seed_all()

      opsgenie = provider!("opsgenie", actor)
      assert opsgenie.definition == edited

      # Left at the version it diverged from, so the skip stays visible instead
      # of looking like a successful reconcile.
      assert opsgenie.template_version == "0"
    end

    test "does not resurrect an entry an operator disabled", %{actor: actor} do
      # Task 2.4.1a. Every catalog entry is individually disablable, and the
      # disable outranks an upgrade - including an upgrade that ships a new
      # template_version for that very entry.
      assert :ok = ProviderSeeder.seed_all()

      disabled = update!(provider!("telegram", actor), :disable, %{}, actor)
      assert disabled.status == :disabled

      assert :ok = ProviderSeeder.seed_all()
      assert provider!("telegram", actor).status == :disabled

      wind_back_provider!("telegram", actor)
      assert :ok = ProviderSeeder.seed_all()

      telegram = provider!("telegram", actor)
      assert telegram.status == :disabled
      assert telegram.template_version == Catalog.template_version()
    end

    test "disabling one entry leaves every other provider alone", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()

      update!(provider!("ntfy", actor), :disable, %{}, actor)
      assert :ok = ProviderSeeder.seed_all()

      for provider <- providers(actor), provider.provider_key != "ntfy" do
        assert provider.status == :active,
               "disabling ntfy also affected #{provider.provider_key}"
      end
    end

    test "is idempotent, and reseeding writes nothing", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()
      first = Map.new(providers(actor), &{&1.provider_key, &1})

      assert :ok = ProviderSeeder.seed_all()
      second = Map.new(providers(actor), &{&1.provider_key, &1})

      for key <- Catalog.keys() do
        assert second[key].id == first[key].id
        assert second[key].updated_at == first[key].updated_at
      end
    end
  end

  # --- template seeding ------------------------------------------------------

  describe "template seeding" do
    test "seeds a managed default for every payload format", %{actor: actor} do
      assert :ok = TemplateSeeder.seed_all()

      for expected <- TemplateSeeder.default_templates() do
        template = template!(expected.payload_format, actor)

        assert template.name == expected.name
        assert template.body_template == expected.body_template
        assert template.subject_template == expected.subject_template
        assert template.managed
        assert template.template_version == expected.template_version

        assert template.template_fingerprint ==
                 SeedFingerprint.fingerprint(expected, TemplateSeeder.managed_fields())

        refute SeedFingerprint.diverged?(template, TemplateSeeder.managed_fields())
      end
    end

    test "is idempotent", %{actor: actor} do
      assert :ok = TemplateSeeder.seed_all()
      first = template!(:plain, actor)

      assert :ok = TemplateSeeder.seed_all()
      second = template!(:plain, actor)

      assert second.id == first.id
      assert second.updated_at == first.updated_at
    end

    test "advances an untouched managed template across an upgrade", %{actor: actor} do
      assert :ok = TemplateSeeder.seed_all()
      update!(template!(:markdown, actor), :reconcile_managed, %{template_version: "0"}, actor)

      assert :ok = TemplateSeeder.seed_all()

      markdown = template!(:markdown, actor)
      assert markdown.template_version == TemplateSeeder.template_version()
      assert markdown.managed
    end

    test "an operator edit detaches the row permanently", %{actor: actor} do
      # `NotificationTemplate.:update` clears `managed`, and this seeder never
      # re-adopts: an upgrade must not restore default wording an on-call team
      # has learned to read.
      assert :ok = TemplateSeeder.seed_all()

      edited =
        update!(
          template!(:plain, actor),
          :update,
          %{body_template: "{{ alert.title }} needs attention."},
          actor
        )

      refute edited.managed

      assert :ok = TemplateSeeder.seed_all()

      plain = template!(:plain, actor)
      assert plain.body_template == "{{ alert.title }} needs attention."
      refute plain.managed
    end

    test "a managed template whose content diverges is skipped", %{actor: actor} do
      assert :ok = TemplateSeeder.seed_all()

      update!(
        template!(:html, actor),
        :reconcile_managed,
        %{body_template: "<p>{{ alert.title }}</p>", template_version: "0"},
        actor
      )

      assert :ok = TemplateSeeder.seed_all()

      html = template!(:html, actor)
      assert html.body_template == "<p>{{ alert.title }}</p>"
      assert html.template_version == "0"
    end
  end

  # --- both ------------------------------------------------------------------

  describe "a seeded provider is bindable" do
    # The point of the catalog is that an operator can create a channel against
    # it. `Changes.ApplyProviderContract` normalizes and validates the channel
    # config against the provider's `config_schema` with
    # `ServiceRadar.Plugins.ConfigSchema`, so this is the first place a schema
    # that does not describe its transport actually bites.
    test "a stream channel saves against the seeded schema", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()

      channel = create_channel!("stream", %{"topic" => "noc", "include_payload" => true}, actor)

      assert channel.config == %{"topic" => "noc", "include_payload" => true}
      assert channel.execution_route == :control_plane
      assert channel.max_attempts == catalog_entry("stream").default_max_attempts
    end

    test "an email channel saves, and a deployment mail setting is refused", %{actor: actor} do
      assert :ok = ProviderSeeder.seed_all()

      channel =
        create_channel!(
          "email",
          %{"to" => ["noc@example.com"], "subject_prefix" => "[SR] "},
          actor
        )

      assert channel.config["to"] == ["noc@example.com"]

      # Relay host and credentials are deployment configuration. Author-time
      # normalization drops unknown keys (and `_unused_*` form leftovers)
      # before the closed schema runs, so a typed relay must not persist.
      assert {:ok, refused} =
               create_channel(
                 "email",
                 %{"to" => ["noc@example.com"], "relay" => "10.0.0.1"},
                 actor
               )

      assert refused.config["to"] == ["noc@example.com"]
      refute Map.has_key?(refused.config, "relay")
    end
  end

  describe "the two seeders together" do
    test "leave every active provider with a template to render", %{actor: actor} do
      # `Renderer.render/4` fails a dispatch outright when no body template
      # resolves for the negotiated format, so this is the condition that decides
      # whether a fresh install can page anyone at all.
      assert :ok = ProviderSeeder.seed_all()
      assert :ok = TemplateSeeder.seed_all()

      formats =
        actor
        |> providers()
        |> Enum.filter(&(&1.status == :active))
        |> Enum.flat_map(& &1.payload_formats)
        |> Enum.uniq()

      assert formats != []

      for format <- formats do
        assert %NotificationTemplate{} = template!(format, actor)
      end
    end
  end
end
