defmodule ServiceRadar.AgentConfig.Compilers.VisibilityCompilerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AgentConfig.Compilers.VisibilityCompiler
  alias ServiceRadar.Inventory.VisibilityProfile

  @device_uid "sr:00000000-0000-0000-0000-000000000001"

  describe "module structure" do
    @tag :visibility
    test "implements Compiler behaviour" do
      behaviours = VisibilityCompiler.__info__(:attributes)[:behaviour] || []
      assert ServiceRadar.AgentConfig.Compiler in behaviours
    end

    @tag :visibility
    test "config_type returns :visibility" do
      assert VisibilityCompiler.config_type() == :visibility
    end

    @tag :visibility
    test "source_resources returns expected modules" do
      assert VisibilityProfile in VisibilityCompiler.source_resources()
    end
  end

  describe "disabled_config/0" do
    @tag :visibility
    test "returns no device bindings" do
      config = VisibilityCompiler.disabled_config()

      assert config["enabled"] == false
      assert config["capture_interfaces"] == []
      assert config["binary_overrides"] == %{}
      assert config["device_bindings"] == []
      assert config["dpi"] == %{"enabled" => false, "protocols" => []}
      assert config["flow_attribution"] == %{"tcp" => false, "udp" => false, "quic" => false}
      assert config["process_snapshot_interval_s"] == 0
      assert config["default_sample_interval_ms"] == 0
    end
  end

  describe "validate/1" do
    @tag :visibility
    test "valid disabled config passes validation" do
      assert :ok = VisibilityCompiler.validate(VisibilityCompiler.disabled_config())
    end

    @tag :visibility
    test "missing enabled fails validation" do
      assert {:error, "Config missing 'enabled' key"} =
               VisibilityCompiler.validate(%{"device_bindings" => []})
    end

    @tag :visibility
    test "non-list device bindings fail validation" do
      assert {:error, "Config 'device_bindings' must be a list"} =
               VisibilityCompiler.validate(%{"enabled" => true, "device_bindings" => %{}})
    end
  end

  describe "compile/3" do
    @tag :visibility
    test "uses the resolved higher-priority profile binding" do
      profiles = [
        profile("Low Priority", 10, %{"tcp" => true, "tls" => false, "http" => false}),
        profile("High Priority", 100, %{"tcp" => false, "tls" => true, "http" => true})
      ]

      {:ok, config} =
        VisibilityCompiler.compile("default", "agent-1",
          actor: %{},
          device_uid: @device_uid,
          profile_resolver: fn _device_uid, _actor ->
            {:ok, Enum.max_by(profiles, & &1.priority)}
          end,
          device_ip_resolver: fn _device_uid, _actor -> {:ok, "192.0.2.10"} end
        )

      assert config["enabled"] == true
      assert config["default_sample_interval_ms"] == 60_000
      assert config["capture_interfaces"] == ["eth0"]
      assert config["dpi"] == %{"enabled" => false, "protocols" => []}
      assert config["flow_attribution"] == %{"tcp" => false, "udp" => false, "quic" => false}
      assert config["process_snapshot_interval_s"] == 0

      assert [
               %{
                 "ip" => "192.0.2.10",
                 "profile_name" => "High Priority",
                 "fingerprint" => %{"tcp" => false, "tls" => true, "http" => true},
                 "dpi" => %{"enabled" => false, "protocols" => []},
                 "sample_interval_ms" => 60_000
               }
             ] = config["device_bindings"]
    end

    @tag :visibility
    test "blank-target profile can compile as the default device scope" do
      default_profile = profile("Default Scope", 0, %{"tcp" => true}, target_query: nil)

      {:ok, config} =
        VisibilityCompiler.compile("default", "agent-1",
          actor: %{},
          device_uid: @device_uid,
          profile_resolver: fn _device_uid, _actor -> {:ok, default_profile} end,
          device_ip_resolver: fn _device_uid, _actor -> {:ok, "198.51.100.8"} end
        )

      [binding] = config["device_bindings"]
      assert binding["profile_name"] == "Default Scope"
      assert binding["ip"] == "198.51.100.8"
      assert binding["fingerprint"] == %{"tcp" => true, "tls" => false, "http" => false}
    end

    @tag :visibility
    test "omits bindings when no profile matches" do
      {:ok, config} =
        VisibilityCompiler.compile("default", "agent-1",
          actor: %{},
          device_uid: @device_uid,
          profile_resolver: fn _device_uid, _actor -> {:ok, nil} end,
          device_ip_resolver: fn _device_uid, _actor -> {:ok, "203.0.113.25"} end
        )

      assert config["enabled"] == false
      assert config["device_bindings"] == []
    end

    @tag :visibility
    test "omits bindings when the device has no canonical IP" do
      {:ok, config} =
        VisibilityCompiler.compile("default", "agent-1",
          actor: %{},
          device_uid: @device_uid,
          profile_resolver: fn _device_uid, _actor -> {:ok, profile("Profile", 1)} end,
          device_ip_resolver: fn _device_uid, _actor -> {:ok, nil} end
        )

      assert config["enabled"] == false
      assert config["device_bindings"] == []
    end
  end

  describe "compile_profile/3" do
    @tag :visibility
    test "normalizes DPI protocol list and aliases" do
      config =
        VisibilityCompiler.compile_profile(
          profile("DPI Visibility", 20, %{"tcp" => true},
            dpi: %{"enabled" => true, "protocols" => ["DNS", "http/1.x", "unknown"], :ssh => true}
          ),
          "10.1.2.3"
        )

      assert config["dpi"] == %{"enabled" => true, "protocols" => ["dns", "http1", "ssh"]}

      assert [
               %{
                 "dpi" => %{"enabled" => true, "protocols" => ["dns", "http1", "ssh"]}
               }
             ] = config["device_bindings"]
    end

    @tag :visibility
    test "normalizes flow attribution and process snapshot controls" do
      config =
        VisibilityCompiler.compile_profile(
          profile("Attribution Visibility", 30, %{"tcp" => true},
            flow_attribution: %{"tcp" => true, :udp => true, "quic" => false},
            process_snapshot_interval_s: 120
          ),
          "10.1.2.3"
        )

      assert config["flow_attribution"] == %{"tcp" => true, "udp" => true, "quic" => false}
      assert config["process_snapshot_interval_s"] == 120
    end

    @tag :visibility
    test "normalizes fingerprint and operator supplied sidecar settings" do
      config =
        VisibilityCompiler.compile_profile(
          profile("Production Visibility", 20, %{"tcp" => true, :tls => true}),
          "10.1.2.3",
          binary_override_path: " /opt/serviceradar/netprobe "
        )

      assert config["capture_interfaces"] == ["eth0"]
      assert config["binary_overrides"] == %{"path" => "/opt/serviceradar/netprobe"}

      assert [
               %{
                 "ip" => "10.1.2.3",
                 "profile_name" => "Production Visibility",
                 "fingerprint" => %{"tcp" => true, "tls" => true, "http" => false}
               }
             ] = config["device_bindings"]
    end
  end

  defp profile(
         name,
         priority,
         fingerprint \\ %{"tcp" => true, "tls" => true, "http" => true},
         opts \\ []
       ) do
    %VisibilityProfile{
      id: Ecto.UUID.generate(),
      name: name,
      enabled: Keyword.get(opts, :enabled, true),
      target_query: Keyword.get(opts, :target_query, "in:devices"),
      priority: priority,
      fingerprint: fingerprint,
      dpi: Keyword.get(opts, :dpi),
      flow_attribution: Keyword.get(opts, :flow_attribution),
      process_snapshot_interval_s: Keyword.get(opts, :process_snapshot_interval_s),
      capture_interfaces: Keyword.get(opts, :capture_interfaces, ["eth0"]),
      sample_interval_ms: Keyword.get(opts, :sample_interval_ms, 60_000),
      retention_days: 30,
      partition_id: "default"
    }
  end
end
