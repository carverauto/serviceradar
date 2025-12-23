defmodule ServiceRadarWebNG.Edge.ComponentTemplatesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Edge.ComponentTemplates

  describe "list/3" do
    test "returns empty list when datasvc not configured" do
      # By default in tests, datasvc is not configured
      assert {:ok, []} = ComponentTemplates.list("checker", "mtls")
    end

    test "returns empty list for poller component type" do
      assert {:ok, []} = ComponentTemplates.list("poller", "mtls")
    end

    test "returns empty list for insecure security mode" do
      assert {:ok, []} = ComponentTemplates.list("checker", "insecure")
    end
  end

  describe "get/2" do
    test "returns nil when datasvc not configured" do
      assert {:ok, nil} = ComponentTemplates.get("templates/checkers/mtls/sysmon.json")
    end
  end

  describe "available_component_types/0" do
    test "returns list of component types" do
      types = ComponentTemplates.available_component_types()
      assert is_list(types)
      assert "checker" in types
      assert "poller" in types
    end
  end

  describe "available_security_modes/0" do
    test "returns list of security modes" do
      modes = ComponentTemplates.available_security_modes()
      assert is_list(modes)
      assert "mtls" in modes
      assert "insecure" in modes
    end
  end

  describe "available?/0" do
    test "returns false when datasvc not configured" do
      refute ComponentTemplates.available?()
    end
  end
end
