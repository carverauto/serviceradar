defmodule ServiceRadar.Inventory.DiscoverySchemaRegistryTest do
  @moduledoc """
  The build-time guardrail for discovery schemas.

  A schema registered with the wrong `source` does not fail at runtime. It
  ingests normally with the wrong identity policy applied -- randomized MACs
  minting a device per rotation, or mDNS creating devices it should only
  describe -- and nothing anywhere says so. These tests are the only thing that
  makes that visible, and they are why the registry lands before any producer.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DiscoverySchemaRegistry, as: Registry
  alias ServiceRadar.Inventory.Sync.SourcePolicy

  defp update_via_source(source), do: %{source: source, metadata: %{}}

  defp update_via_identity_source(identity_source),
    do: %{source: "some-unrelated-source", metadata: %{"identity_source" => identity_source}}

  defp assert_policy_class(update, :passive_census, context) do
    assert SourcePolicy.passive_census_source?(update),
           "#{context}: declared :passive_census but SourcePolicy does not recognise it"

    refute SourcePolicy.enrichment_only_source?(update),
           "#{context}: declared :passive_census but SourcePolicy also calls it enrichment-only"
  end

  defp assert_policy_class(update, :enrichment_only, context) do
    assert SourcePolicy.enrichment_only_source?(update),
           "#{context}: declared :enrichment_only but SourcePolicy does not recognise it"

    refute SourcePolicy.passive_census_source?(update),
           "#{context}: declared :enrichment_only but SourcePolicy would let it anchor devices"
  end

  defp assert_policy_class(update, :standard, context) do
    refute SourcePolicy.passive_census_source?(update),
           "#{context}: declared :standard but SourcePolicy applies the census MAC guardrail"

    refute SourcePolicy.enrichment_only_source?(update),
           "#{context}: declared :standard but SourcePolicy refuses to let it create devices"
  end

  describe "every registered schema agrees with SourcePolicy" do
    test "through the source channel" do
      for {schema, entry} <- Registry.all() do
        assert_policy_class(
          update_via_source(entry.source),
          entry.policy_class,
          "#{schema} via source=#{inspect(entry.source)}"
        )
      end
    end

    test "through the identity_source channel, independently" do
      # A schema correct through one channel and wrong through the other is HALF
      # disarmed, which is worse than being obviously broken: it works until a
      # downstream hop rewrites `source`, which is exactly the case the Go
      # translators set both fields to survive.
      for {schema, entry} <- Registry.all(), entry.identity_source != nil do
        assert_policy_class(
          update_via_identity_source(entry.identity_source),
          entry.policy_class,
          "#{schema} via identity_source=#{inspect(entry.identity_source)}"
        )
      end
    end

    test "the collector's agent_id can never become a device identifier" do
      # Every discovery source is an OBSERVER: it reports on other hosts it
      # overheard, never on itself. If its agent_id registered as an identifier,
      # every device it described would carry the same one and collapse onto a
      # single device.
      for {schema, entry} <- Registry.all() do
        assert SourcePolicy.observer_agent_source?(update_via_source(entry.source)),
               "#{schema}: source #{inspect(entry.source)} is not treated as an observer, " <>
                 "so its agent_id would identify the devices it reports"
      end
    end
  end

  describe "the registry refuses to be a place where guesses live" do
    test "every entry declares a source SourcePolicy actually classifies" do
      # :standard is a real classification -- "neither census nor
      # enrichment-only" -- so this does not reject it. What it rejects is an
      # entry whose declared class does not match, which the tests above cover
      # per channel. This one pins the SHAPE: no entry may omit the fields the
      # guardrail reads.
      for {schema, entry} <- Registry.all() do
        assert is_binary(entry.source) and entry.source != "",
               "#{schema}: source must be a non-empty string"

        assert entry.policy_class in [:passive_census, :enrichment_only, :standard],
               "#{schema}: unknown policy_class #{inspect(entry.policy_class)}"

        assert is_nil(entry.identity_source) or
                 (is_binary(entry.identity_source) and entry.identity_source != ""),
               "#{schema}: identity_source must be a non-empty string or nil"

        # A registered schema with no working decoder is a schema whose payloads
        # are accepted and then dropped -- exactly the silent-discard shape the
        # loud-drop rule exists to prevent, moved one level up.
        assert Code.ensure_loaded?(entry.decoder),
               "#{schema}: decoder #{inspect(entry.decoder)} does not exist"

        assert function_exported?(entry.decoder, :decode, 1),
               "#{schema}: decoder #{inspect(entry.decoder)} does not export decode/1"
      end
    end

    test "schema names are namespaced and versioned" do
      # The whole point of a schema STRING is that new ones are cheap. Cheap
      # plus unversioned is how two producers end up disagreeing about what
      # "census" means with no way to tell them apart.
      for schema <- Registry.schemas() do
        assert String.starts_with?(schema, "serviceradar."),
               "#{schema}: schema names must be namespaced"

        assert Regex.match?(~r/\.v\d+$/, schema),
               "#{schema}: schema names must end in a version, e.g. .v1"
      end
    end

    test "an unregistered schema is not resolvable" do
      assert Registry.fetch("serviceradar.netprobe.census.v1") != :error
      assert Registry.fetch("serviceradar.netprobe.lldp.v1") == :error
      assert Registry.fetch("") == :error
      assert Registry.fetch(nil) == :error
    end
  end

  describe "the existing router/policy pairing is not orphaned" do
    test "every registered source stays routable by service type while both paths are live" do
      # ResultsRouter still carries the census and mDNS routes, and
      # source_policy_census_test.exs / source_policy_mdns_test.exs assert THOSE
      # against SourcePolicy. The discovery path bypasses ResultsRouter
      # entirely, so without this the two invariants drift apart silently: those
      # tests would keep passing while guarding a route nothing uses.
      #
      # Asserting the registry's sources are the same strings keeps the old and
      # new routes pinned to one another until the old one is retired.
      router_sources =
        MapSet.new(
          ServiceRadar.ResultsRouter.census_service_types() ++
            ServiceRadar.ResultsRouter.mdns_service_types() ++
            ServiceRadar.ResultsRouter.passive_netprobe_service_types(),
          &to_string/1
        )

      for {schema, entry} <- Registry.all() do
        assert entry.source in router_sources,
               "#{schema}: source #{inspect(entry.source)} is not one ResultsRouter accepts. " <>
                 "If the legacy route was retired, retire this assertion with it."
      end
    end
  end
end
