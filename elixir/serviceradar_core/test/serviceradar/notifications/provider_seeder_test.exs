defmodule ServiceRadar.Notifications.ProviderSeederTest do
  @moduledoc """
  The catalog is data, so these tests are database-free and async.

  Every assertion here answers a question that would otherwise only be answered
  at boot, by a `Logger.warning` nobody reads, on the release that shipped the
  mistake: a `config_schema` the schema validator rejects, an
  `implementation_module` the provider resource's allowlist refuses, a
  `capabilities` list that claims something the transport does not implement, a
  credential field the dispatcher will never resolve, or a `:stream` row that
  violates the `notification_providers_native_module` CHECK constraint.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.ProviderSeeder
  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.SeedFingerprint
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transports.Discord
  alias ServiceRadar.Notifications.Transports.Email
  alias ServiceRadar.Notifications.Transports.GenericWebhook
  alias ServiceRadar.Notifications.Transports.Registry, as: TransportRegistry
  alias ServiceRadar.Notifications.Transports.Slack
  alias ServiceRadar.Notifications.Transports.Stream
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.SecretRefs

  # The transport each seeded provider is backed by.
  @transports %{
    "slack" => Slack,
    "discord" => Discord,
    "webhook" => GenericWebhook,
    "email" => Email,
    "stream" => Stream
  }

  # The credential keys each transport reads out of `Transport.Request.secrets`.
  # `SecretRefs.resolve_runtime_params/3` writes a resolved secret back under its
  # schema field name, so a schema that names them differently produces a channel
  # whose credential silently never arrives.
  @expected_secret_fields %{
    "slack" => ["bot_token", "webhook_url"],
    "discord" => ["webhook_url"],
    "webhook" => ["password", "token"],
    "email" => [],
    "stream" => []
  }

  @ref SecretRefs.network_credential_ref("0198f0aa-1111-7000-8000-000000000001")

  defp catalog, do: ProviderSeeder.default_providers()

  defp by_key, do: Map.new(catalog(), &{&1.provider_key, &1})

  # One configuration per shape the schema is meant to describe.
  defp admissible_configurations do
    [
      {"slack", Slack, %{"mode" => "incoming_webhook", "webhook_url" => @ref}},
      {"slack", Slack,
       %{
         "mode" => "bot_token",
         "bot_token" => @ref,
         "channel" => "#noc",
         "api_base_url" => "https://slack.com/api",
         "thread_ts" => "1754745600.000100",
         "username" => "ServiceRadar",
         "icon_emoji" => ":rotating_light:"
       }},
      {"discord", Discord,
       %{
         "webhook_url" => @ref,
         "wait" => true,
         "thread_id" => "1180000000000000000",
         "username" => "ServiceRadar",
         "avatar_url" => "https://serviceradar.example.com/avatar.png"
       }},
      {"email", Email,
       %{
         "to" => ["noc@example.com", "oncall@example.com"],
         "cc" => ["records@example.com"],
         "from" => "serviceradar@example.com",
         "subject_prefix" => "[ServiceRadar] "
       }},
      {"stream", Stream, %{"topic" => "noc", "include_payload" => true}},
      {"stream", Stream, %{}}
    ]
  end

  # `Email.validate_config/1` resolves the deployment mailer, which a unit test
  # has none of; the second arity exists precisely so the configuration rules can
  # be checked without one.
  defp validate_transport_config(Email, config),
    do: Email.validate_config(config, mailer_diagnostic: :ok)

  defp validate_transport_config(module, config), do: module.validate_config(config)

  describe "the shipped catalog" do
    test "is exactly the five first-party providers" do
      assert Enum.map(catalog(), & &1.provider_key) == [
               "slack",
               "discord",
               "webhook",
               "email",
               "stream"
             ]
    end

    test "ships every row managed, first-party, and versioned" do
      for provider <- catalog() do
        assert provider.managed, "#{provider.provider_key} must be managed to be reconcilable"
        assert provider.source == :first_party
        assert is_binary(provider.template_version)
        assert provider.template_version != ""
      end
    end

    test "carries no status, because a provider is born :draft and activated deliberately" do
      for provider <- catalog() do
        refute Map.has_key?(provider, :status)
      end
    end
  end

  describe "the transport contract (design D2)" do
    test "every provider declares both :send and :test" do
      for provider <- catalog() do
        assert Transport.declares_required_capabilities?(provider.capabilities),
               "#{provider.provider_key} must declare send and test"
      end
    end

    test "declared capabilities are exactly what the transport implements" do
      for {key, module} <- @transports do
        assert by_key()[key].capabilities == Enum.sort(module.capabilities()),
               "#{key} claims a capability its transport does not implement"
      end
    end

    test "every declared capability is in the closed vocabulary" do
      known = MapSet.new(Transport.capabilities())

      for provider <- catalog(), capability <- provider.capabilities do
        assert MapSet.member?(known, capability)
      end
    end

    test "every declared payload format is one the renderer can render" do
      known = MapSet.new(Renderer.payload_formats())

      for provider <- catalog() do
        assert provider.payload_formats != [],
               "#{provider.provider_key} would negotiate no format at all"

        for format <- provider.payload_formats do
          assert MapSet.member?(known, format)
        end
      end
    end

    test "Phase 1 declares the control-plane route only" do
      # `ApplyProviderContract` refuses a channel whose execution_route is not in
      # its provider's supported_routes, and the edge route has no agent-side
      # handler in Phase 1. Declaring :edge_agent now would let an operator save a
      # channel that cannot dispatch.
      for provider <- catalog() do
        assert provider.supported_routes == [:control_plane]
      end
    end
  end

  describe "module resolution" do
    test "every :native provider names an allowlisted transport" do
      allowlist = MapSet.new(NotificationProvider.implementation_module_allowlist())

      for provider <- catalog(), provider.provider_type == :native do
        assert MapSet.member?(allowlist, provider.implementation_module),
               "#{provider.provider_key} names a module the provider resource would refuse"

        assert TransportRegistry.allowed?(provider.implementation_module)
      end
    end

    test "every named transport conforms to the Transport behaviour" do
      for provider <- catalog(), provider.provider_type == :native do
        assert {:ok, module} = TransportRegistry.resolve(provider.implementation_module)
        assert TransportRegistry.conformance(module) == :ok
      end
    end

    test "the :stream row leaves implementation_module nil" do
      # notification_providers_native_module admits the column only on a :native
      # row, and NotificationProvider mirrors that as an Ash validation.
      stream = by_key()["stream"]

      assert stream.provider_type == :stream
      assert is_nil(stream.implementation_module)
    end

    # Phase 3 admits the :wasm_plugin tier, but nothing SEEDED is one: a seeded
    # provider would have to reference an installed plugin package, and the
    # seeder runs before any package exists.
    test "no seeded provider is a :wasm_plugin" do
      for provider <- catalog() do
        refute provider.provider_type == :wasm_plugin
        refute Map.has_key?(provider, :plugin_package_id)
        refute Map.has_key?(provider, :action_key)
      end
    end
  end

  describe "config schemas" do
    test "every schema passes the constrained JSON Schema subset" do
      for provider <- catalog() do
        assert ConfigSchema.validate_schema(provider.config_schema) == :ok,
               "#{provider.provider_key} ships a schema PluginConfigForm cannot render"
      end
    end

    test "every schema is a closed object, so deployment settings cannot arrive on a channel" do
      for provider <- catalog() do
        assert provider.config_schema["type"] == "object"
        assert provider.config_schema["additionalProperties"] == false
      end
    end

    test "credential fields are named for the keys the transport resolves" do
      for {key, expected} <- @expected_secret_fields do
        actual = by_key()[key].config_schema |> SecretRefs.secret_ref_fields() |> Enum.sort()

        assert actual == expected,
               "#{key} declares secret fields the dispatcher will not resolve"
      end
    end

    test "a credential field accepts a stored reference rather than a shaped value" do
      # The stored value is a `credentialref:...` string, so a `format` or
      # `pattern` on a secretRef property would reject every reference an
      # operator can actually save.
      for provider <- catalog() do
        for field <- SecretRefs.secret_ref_fields(provider.config_schema) do
          property = provider.config_schema["properties"][field]

          assert property["type"] == "string"
          refute Map.has_key?(property, "format")
          refute Map.has_key?(property, "pattern")
          refute Map.has_key?(property, "enum")
        end
      end
    end

    test "a credential field names the credential kind it can be filled from" do
      for provider <- catalog() do
        for field <- SecretRefs.secret_ref_fields(provider.config_schema) do
          assert is_binary(provider.config_schema["properties"][field]["credentialKind"])
        end
      end
    end

    test "every required key is a declared property" do
      for provider <- catalog() do
        properties = Map.keys(provider.config_schema["properties"])

        for field <- Map.get(provider.config_schema, "required", []) do
          assert field in properties,
                 "#{provider.provider_key} requires a key it does not declare"
        end
      end
    end

    test "a required credential field is satisfied by the reference in secret_refs" do
      # `ApplyProviderContract` validates `config` merged with the PUBLIC part of
      # `secret_refs`, because the schema describes one configuration document.
      # Requiring a credential field is therefore legitimate: the reference
      # string is what satisfies it.
      discord = by_key()["discord"]

      assert "webhook_url" in Map.get(discord.config_schema, "required", [])
      assert ConfigSchema.validate_params(discord.config_schema, %{"webhook_url" => @ref}) == :ok
      assert {:error, _errors} = ConfigSchema.validate_params(discord.config_schema, %{})
    end

    test "a configuration the schema admits is one the transport accepts" do
      # The direction that matters. A schema stricter than its transport rejects
      # a configuration that would have worked; a schema looser than its
      # transport defers to a check that still runs before the channel is saved.
      #
      # `webhook` is absent because `GenericWebhook.validate_config/1` resolves
      # the URL host through DNS, which does not belong in a database-free unit
      # test; its own transport tests cover it.
      for {provider_key, module, config} <- admissible_configurations() do
        schema = by_key()[provider_key].config_schema
        normalized = ConfigSchema.normalize_params(schema, config)

        assert ConfigSchema.validate_params(schema, normalized) == :ok,
               "#{provider_key} schema rejected its own example"

        assert validate_transport_config(module, normalized) == :ok,
               "#{provider_key} schema admits a configuration its transport refuses"
      end
    end

    test "email declares no credential field at all" do
      # Relay host, port, and credentials are deployment mail configuration.
      # `Transports.Email.validate_config/1` rejects them by name; the closed
      # schema refuses them for the same reason.
      email = by_key()["email"]

      assert SecretRefs.secret_ref_fields(email.config_schema) == []

      for key <- ~w(adapter relay port hostname username password api_key ssl tls auth) do
        refute Map.has_key?(email.config_schema["properties"], key)
      end
    end
  end

  describe "reconciliation contract" do
    test "the managed set excludes status and the operator-tunable retry bound" do
      fields = ProviderSeeder.managed_fields()

      refute :status in fields
      refute :default_max_attempts in fields
      refute :provider_key in fields
      refute :provider_type in fields
    end

    test "every managed field is one the provider :update action accepts" do
      # An unaccepted field would make every reconcile fail with a field error
      # that only appears in a boot log.
      accepted =
        NotificationProvider
        |> Ash.Resource.Info.action(:update)
        |> Map.fetch!(:accept)

      for field <- ProviderSeeder.managed_fields() do
        assert field in accepted
      end

      for field <- [:managed, :template_version, :template_fingerprint] do
        assert field in accepted
      end
    end

    test "a catalog row fingerprints identically twice" do
      fields = ProviderSeeder.managed_fields()

      for provider <- catalog() do
        assert SeedFingerprint.fingerprint(provider, fields) ==
                 SeedFingerprint.fingerprint(provider, fields)
      end
    end

    test "every catalog row has a distinct fingerprint" do
      fields = ProviderSeeder.managed_fields()
      digests = Enum.map(catalog(), &SeedFingerprint.fingerprint(&1, fields))

      assert length(Enum.uniq(digests)) == length(digests)
    end

    test "an operator edit to a managed field reads as diverged" do
      fields = ProviderSeeder.managed_fields()
      slack = by_key()["slack"]
      stamped = Map.put(slack, :template_fingerprint, SeedFingerprint.fingerprint(slack, fields))

      refute SeedFingerprint.diverged?(stamped, fields)
      assert SeedFingerprint.diverged?(%{stamped | display_name: "Slack (NOC)"}, fields)
    end

    test "raising default_max_attempts does not read as diverged" do
      fields = ProviderSeeder.managed_fields()
      slack = by_key()["slack"]
      stamped = Map.put(slack, :template_fingerprint, SeedFingerprint.fingerprint(slack, fields))

      refute SeedFingerprint.diverged?(%{stamped | default_max_attempts: 10}, fields)
    end
  end
end
