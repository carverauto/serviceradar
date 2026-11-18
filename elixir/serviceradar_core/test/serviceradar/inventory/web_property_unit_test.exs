defmodule ServiceRadar.Inventory.WebPropertyUnitTest do
  @moduledoc """
  DB-free unit tests for L7 WebProperty normalization, RUM site key generation
  and rotation, WebPropertyBinding validation, ServiceCheck.web_property_id
  agent config compilation, Metrics backfill guard, and WebPropertyDiscoveryWorker
  pure helpers.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.Inventory.WebProperty
  alias ServiceRadar.Inventory.WebPropertyBinding
  alias ServiceRadar.Inventory.WebPropertyDiscoveryWorker
  alias ServiceRadar.Monitoring.ServiceCheck

  @moduletag :db_free

  describe "canonical_origin normalization" do
    test "lowercases scheme and host, strips default ports, paths, query, and fragments" do
      assert {:ok, "https://shop.example.com"} =
               WebProperty.normalize_canonical_origin(
                 "  HTTPS://Shop.Example.COM:443/checkout?a=1#top  "
               )

      assert {:ok, "http://portal.example.com"} =
               WebProperty.normalize_canonical_origin("HTTP://PORTAL.example.com:80/login")

      assert {:ok, "https://shop.example.com:8443"} =
               WebProperty.normalize_canonical_origin("https://SHOP.example.com:8443/app")

      assert {:ok, "http://[::1]:8080"} =
               WebProperty.normalize_canonical_origin("HTTP://[::1]:8080/health")
    end

    test "rejects non-http/https schemes, blank origins, wildcards, and userinfo" do
      assert {:error, _} = WebProperty.normalize_canonical_origin("")
      assert {:error, _} = WebProperty.normalize_canonical_origin("ftp://files.example.com")
      assert {:error, _} = WebProperty.normalize_canonical_origin("not-a-url")

      assert {:error, _} =
               WebProperty.normalize_canonical_origin("https://user:pass@shop.example.com")

      assert {:error, _} =
               WebProperty.normalize_canonical_origin("https://@shop.example.com")

      assert {:error, _} = WebProperty.normalize_canonical_origin("https://shop.example.com:abc")
      assert {:error, _} = WebProperty.normalize_canonical_origin("https://shop.example.com:-1")
      assert {:error, _} = WebProperty.normalize_canonical_origin("https://shop.example.com:0")

      assert {:error, _} =
               WebProperty.normalize_canonical_origin("https://shop.example.com:65536")

      assert {:error, _} = WebProperty.normalize_canonical_origin("https://shop.example.com:")
      assert {:error, _} = WebProperty.normalize_canonical_origin("https://2001:db8::1")
      assert {:error, _} = WebProperty.normalize_canonical_origin("https://[::1")
      assert {:error, _} = WebProperty.normalize_canonical_origin("https://*.example.com")
    end

    test "restricts wildcard allowed_origins to scheme://*.<domain> with at least two labels" do
      for bad_wildcard <- [
            "https://*",
            "https://*.*",
            "https://*.com",
            "https://*.*.example.com",
            "https://foo*.example.com",
            "https://*.example..com"
          ] do
        changeset =
          Ash.Changeset.for_create(WebProperty, :create, %{
            name: "Bad Wildcard",
            canonical_origin: "https://shop.example.com",
            allowed_origins: [bad_wildcard]
          })

        refute changeset.valid?, "expected #{bad_wildcard} to be rejected"
      end

      changeset =
        Ash.Changeset.for_create(WebProperty, :create, %{
          name: "Valid Wildcard",
          canonical_origin: "https://shop.example.com",
          allowed_origins: ["https://*.sub.example.com:8443", "https://*.example.com:443"]
        })

      assert changeset.valid?

      assert Ash.Changeset.get_attribute(changeset, :allowed_origins) == [
               "https://*.sub.example.com:8443",
               "https://*.example.com"
             ]
    end
  end

  describe "rum_site_key generation and changesets" do
    test "generates valid sr_rum_ site keys on create and rotates cleanly" do
      key1 = WebProperty.generate_rum_site_key()
      key2 = WebProperty.generate_rum_site_key()

      assert WebProperty.valid_rum_site_key?(key1)
      assert WebProperty.valid_rum_site_key?(key2)
      assert key1 != key2
      assert String.starts_with?(key1, "sr_rum_")

      changeset =
        Ash.Changeset.for_create(WebProperty, :create, %{
          name: "Storefront",
          canonical_origin: "HTTPS://Shop.Example.com:443/cart",
          allowed_origins: ["HTTPS://Shop.Example.com:443/a", "https://*.example.com"]
        })

      assert changeset.valid?

      assert Ash.Changeset.get_attribute(changeset, :canonical_origin) ==
               "https://shop.example.com"

      assert Ash.Changeset.get_attribute(changeset, :allowed_origins) == [
               "https://shop.example.com",
               "https://*.example.com"
             ]

      generated_key = Ash.Changeset.get_attribute(changeset, :rum_site_key)
      assert WebProperty.valid_rum_site_key?(generated_key)
    end

    test "rejects out-of-bounds rum_sample_rate" do
      for invalid <- [-0.1, 1.01] do
        changeset =
          Ash.Changeset.for_create(WebProperty, :create, %{
            name: "Bad Rate",
            canonical_origin: "https://bad.example.com",
            rum_sample_rate: invalid
          })

        refute changeset.valid?
      end

      for valid <- [0.0, 0.25, 1.0] do
        changeset =
          Ash.Changeset.for_create(WebProperty, :create, %{
            name: "Good Rate",
            canonical_origin: "https://good.example.com",
            rum_sample_rate: valid
          })

        assert changeset.valid?
      end
    end

    test "rotate_rum_site_key changeset generates a fresh site key" do
      existing = %WebProperty{
        id: Ash.UUID.generate(),
        name: "Rotate Test",
        canonical_origin: "https://rotate.example.com",
        rum_site_key: "sr_rum_aaaaaaaaaaaaaaaaaaaaaaaa"
      }

      changeset = Ash.Changeset.for_update(existing, :rotate_rum_site_key, %{})
      assert changeset.valid?
      new_key = Ash.Changeset.get_attribute(changeset, :rum_site_key)
      assert WebProperty.valid_rum_site_key?(new_key)
      assert new_key != existing.rum_site_key
    end
  end

  describe "WebPropertyBinding kind validation" do
    test "validates required and forbidden attributes per binding_kind" do
      wp_id = Ash.UUID.generate()

      k8s_ok =
        Ash.Changeset.for_create(WebPropertyBinding, :create, %{
          web_property_id: wp_id,
          binding_kind: :k8s_public_endpoint,
          source: :k8s_discovery,
          cluster_id: "cluster-1",
          namespace: "web",
          resource_kind: "HTTPRoute",
          resource_name: "shop-route"
        })

      assert k8s_ok.valid?

      k8s_missing =
        Ash.Changeset.for_create(WebPropertyBinding, :create, %{
          web_property_id: wp_id,
          binding_kind: :k8s_public_endpoint,
          cluster_id: "cluster-1"
        })

      refute k8s_missing.valid?

      origin_ok =
        Ash.Changeset.for_create(WebPropertyBinding, :create, %{
          web_property_id: wp_id,
          binding_kind: :origin_device,
          device_uid: "sr:dev-1"
        })

      assert origin_ok.valid?

      origin_conflict =
        Ash.Changeset.for_create(WebPropertyBinding, :create, %{
          web_property_id: wp_id,
          binding_kind: :origin_device,
          device_uid: "sr:dev-1",
          otel_service_name: "web-api"
        })

      refute origin_conflict.valid?

      otel_ok =
        Ash.Changeset.for_create(WebPropertyBinding, :create, %{
          web_property_id: wp_id,
          binding_kind: :otel_service,
          source: :trace_correlation,
          otel_service_name: "checkout-frontend"
        })

      assert otel_ok.valid?
    end

    test "allows cluster-scoped k8s_public_endpoint with empty namespace and rejects nil namespace" do
      wp_id = Ash.UUID.generate()

      cluster_scoped =
        Ash.Changeset.for_create(WebPropertyBinding, :create, %{
          web_property_id: wp_id,
          binding_kind: :k8s_public_endpoint,
          source: :k8s_discovery,
          cluster_id: "cluster-1",
          namespace: "",
          resource_kind: "Gateway",
          resource_name: "public-gw"
        })

      assert cluster_scoped.valid?
      assert Ash.Changeset.get_attribute(cluster_scoped, :namespace) == ""

      nil_namespace =
        Ash.Changeset.for_create(WebPropertyBinding, :create, %{
          web_property_id: wp_id,
          binding_kind: :k8s_public_endpoint,
          source: :k8s_discovery,
          cluster_id: "cluster-1",
          namespace: nil,
          resource_kind: "Gateway",
          resource_name: "public-gw"
        })

      refute nil_namespace.valid?
    end

    test "WebPropertyBindingKind rejects empty strings on forbidden target attributes" do
      alias ServiceRadar.Inventory.Validations.WebPropertyBindingKind

      wp_id = Ash.UUID.generate()

      # Input coercion converts empty strings to nil on non-empty string attrs:
      k8s_coerced =
        Ash.Changeset.for_create(WebPropertyBinding, :create, %{
          web_property_id: wp_id,
          binding_kind: :k8s_public_endpoint,
          source: :k8s_discovery,
          cluster_id: "cluster-1",
          namespace: "web",
          resource_kind: "HTTPRoute",
          resource_name: "shop-route",
          device_uid: "",
          otel_service_name: ""
        })

      assert k8s_coerced.valid?
      assert is_nil(Ash.Changeset.get_attribute(k8s_coerced, :device_uid))
      assert is_nil(Ash.Changeset.get_attribute(k8s_coerced, :otel_service_name))

      # Empty strings placed in attributes or atomics (bypassing input coercion) must be
      # rejected by WebPropertyBindingKind so it matches the Postgres IS NULL constraint 1-to-1:
      k8s_empty_device =
        WebPropertyBinding
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:web_property_id, wp_id)
        |> Ash.Changeset.force_change_attribute(:binding_kind, :k8s_public_endpoint)
        |> Ash.Changeset.force_change_attribute(:cluster_id, "cluster-1")
        |> Ash.Changeset.force_change_attribute(:namespace, "web")
        |> Ash.Changeset.force_change_attribute(:resource_kind, "HTTPRoute")
        |> Ash.Changeset.force_change_attribute(:resource_name, "shop-route")
        |> Map.update!(:attributes, &Map.put(&1, :device_uid, ""))

      assert {:error, field: :device_uid, message: _} =
               WebPropertyBindingKind.validate(k8s_empty_device, [], %{})

      k8s_empty_otel =
        WebPropertyBinding
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:web_property_id, wp_id)
        |> Ash.Changeset.force_change_attribute(:binding_kind, :k8s_public_endpoint)
        |> Ash.Changeset.force_change_attribute(:cluster_id, "cluster-1")
        |> Ash.Changeset.force_change_attribute(:namespace, "web")
        |> Ash.Changeset.force_change_attribute(:resource_kind, "HTTPRoute")
        |> Ash.Changeset.force_change_attribute(:resource_name, "shop-route")
        |> Map.update!(:atomics, &Keyword.put(&1, :otel_service_name, ""))

      assert {:error, field: :otel_service_name, message: _} =
               WebPropertyBindingKind.atomic(k8s_empty_otel, [], %{})

      origin_empty_otel =
        WebPropertyBinding
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:web_property_id, wp_id)
        |> Ash.Changeset.force_change_attribute(:binding_kind, :origin_device)
        |> Ash.Changeset.force_change_attribute(:device_uid, "sr:dev-1")
        |> Map.update!(:attributes, &Map.put(&1, :otel_service_name, ""))

      assert {:error, field: :otel_service_name, message: _} =
               WebPropertyBindingKind.validate(origin_empty_otel, [], %{})

      otel_empty_device =
        WebPropertyBinding
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:web_property_id, wp_id)
        |> Ash.Changeset.force_change_attribute(:binding_kind, :otel_service)
        |> Ash.Changeset.force_change_attribute(:otel_service_name, "web-api")
        |> Map.update!(:attributes, &Map.put(&1, :device_uid, ""))

      assert {:error, field: :device_uid, message: _} =
               WebPropertyBindingKind.validate(otel_empty_device, [], %{})
    end
  end

  describe "ServiceCheck.web_property_id and Metrics attribution guard" do
    test "AgentConfigGenerator emits web_property_id when device_uid is nil" do
      wp_id = Ash.UUID.generate()

      check = %ServiceCheck{
        id: Ash.UUID.generate(),
        name: "Synthetic Storefront",
        check_type: :http,
        target: "https://shop.example.com/health",
        port: 443,
        enabled: true,
        interval_seconds: 60,
        timeout_seconds: 10,
        device_uid: nil,
        web_property_id: wp_id,
        config: %{"method" => "GET"},
        metadata: %{}
      }

      config = AgentConfigGenerator.check_to_config(check)
      assert config.check_type == "http"
      assert config.settings["web_property_id"] == wp_id
      refute Map.has_key?(config.settings, "device_uid")
    end

    test "Metrics.attribute_device_ids skips IP backfill for rows with web_property_id tag" do
      wp_id = Ash.UUID.generate()

      rows = [
        %{
          metric_name: "synthetic.journey.duration_ms",
          device_id: nil,
          target_device_ip: "203.0.113.25",
          tags: %{"web_property_id" => wp_id}
        }
      ]

      [attributed] = Metrics.attribute_device_ids(rows)
      assert is_nil(attributed.device_id)
    end
  end

  describe "WebPropertyDiscoveryWorker pure helpers" do
    test "endpoint_to_origin normalizes HTTPRoute/Ingress endpoints and skips internal cluster DNS" do
      assert {:ok, "https://shop.example.com"} =
               WebPropertyDiscoveryWorker.endpoint_to_origin(%{
                 hostname: "Shop.Example.COM",
                 port: 443,
                 protocol: "TCP",
                 route_kind: "HTTPRoute"
               })

      assert {:ok, "http://portal.example.com:8080"} =
               WebPropertyDiscoveryWorker.endpoint_to_origin(%{
                 hostname: "portal.example.com",
                 port: 8080,
                 protocol: "TCP",
                 route_kind: "Ingress"
               })

      assert :ignore =
               WebPropertyDiscoveryWorker.endpoint_to_origin(%{
                 hostname: "api.default.svc.cluster.local",
                 port: 443,
                 protocol: "TCP",
                 route_kind: "HTTPRoute"
               })

      assert :ignore =
               WebPropertyDiscoveryWorker.endpoint_to_origin(%{
                 hostname: "ssh.example.com",
                 port: 22,
                 protocol: "TCP",
                 route_kind: ""
               })

      assert :ignore =
               WebPropertyDiscoveryWorker.endpoint_to_origin(%{
                 hostname: "https://already.example.com",
                 port: 443,
                 protocol: "TCP",
                 route_kind: "HTTPRoute"
               })

      assert :ignore =
               WebPropertyDiscoveryWorker.endpoint_to_origin(%{
                 hostname: "bad host.example.com",
                 port: 443,
                 protocol: "TCP",
                 route_kind: "HTTPRoute"
               })

      assert {:ok, "https://[2001:db8::1]:8443"} =
               WebPropertyDiscoveryWorker.endpoint_to_origin(%{
                 hostname: "2001:db8::1",
                 port: 8443,
                 protocol: "TCP",
                 route_kind: "HTTPRoute"
               })
    end

    test "match_sole_origin_device requires strictly 1 unique live device" do
      assert :none = WebPropertyDiscoveryWorker.match_sole_origin_device([])
      assert {:ok, "sr:dev-1"} = WebPropertyDiscoveryWorker.match_sole_origin_device(["sr:dev-1"])

      assert {:ok, "sr:dev-1"} =
               WebPropertyDiscoveryWorker.match_sole_origin_device(["sr:dev-1", "sr:dev-1"])

      assert :ambiguous =
               WebPropertyDiscoveryWorker.match_sole_origin_device(["sr:dev-1", "sr:dev-2"])
    end

    test "detect_edge_provider identifies CDN ASNs, TLS issuers, Gateway, and direct" do
      assert "akamai" == WebPropertyDiscoveryWorker.detect_edge_provider([20_940], nil, nil)
      assert "cloudflare" == WebPropertyDiscoveryWorker.detect_edge_provider([13_335], nil, nil)

      assert "fastly" ==
               WebPropertyDiscoveryWorker.detect_edge_provider([], "Fastly TLS Authority", nil)

      assert "envoy_gateway" ==
               WebPropertyDiscoveryWorker.detect_edge_provider([], nil, "Gateway")

      assert "direct" == WebPropertyDiscoveryWorker.detect_edge_provider([], nil, "LoadBalancer")
    end
  end
end
