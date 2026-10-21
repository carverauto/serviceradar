defmodule ServiceRadar.Observability.PluginResultProvenanceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.PluginResultProvenance

  @module_hash String.duplicate("ab", 32)

  defp status(provenance), do: %{plugin_provenance: provenance}

  test "valid host-stamped fields are trimmed and kept" do
    assert %{
             "assignment_id" => "assignment-1",
             "plugin_id" => "example-check",
             "plugin_package_id" => "example-check-package-2",
             "plugin_version" => "2.0.0",
             "content_hash" => @module_hash
           } ==
             PluginResultProvenance.from_status(
               status(%{
                 assignment_id: " assignment-1 ",
                 plugin_id: "example-check",
                 plugin_package_id: "example-check-package-2",
                 plugin_version: "2.0.0",
                 content_hash: @module_hash
               })
             )
  end

  test "a text field carrying any control character is dropped" do
    for control <- ["\e[31m", "\b", "\n", "\r", "\t", <<0>>, <<0x7F>>, "\u0085"] do
      provenance =
        PluginResultProvenance.from_status(
          status(%{plugin_id: "example-check", plugin_version: "2.0.0" <> control <> "x"})
        )

      assert provenance == %{"plugin_id" => "example-check"},
             "expected #{inspect(control)} to be rejected, got #{inspect(provenance)}"
    end
  end

  test "oversized, blank and invalid UTF-8 text fields are dropped" do
    assert nil ==
             PluginResultProvenance.from_status(
               status(%{
                 assignment_id: String.duplicate("a", 256),
                 plugin_id: "   ",
                 plugin_version: <<0xFF, 0xFE>>
               })
             )

    assert %{"assignment_id" => boundary} =
             PluginResultProvenance.from_status(
               status(%{assignment_id: String.duplicate("a", 255)})
             )

    assert byte_size(boundary) == 255
  end

  test "content_hash must be lowercase 64-hex" do
    for bad <- [
          String.upcase(@module_hash),
          String.duplicate("ab", 31),
          @module_hash <> "\n",
          "zz"
        ] do
      assert nil == PluginResultProvenance.from_status(status(%{content_hash: bad}))
    end
  end

  test "agents that send no provenance yield nil" do
    assert nil == PluginResultProvenance.from_status(%{})
    assert nil == PluginResultProvenance.from_details(nil)
    assert nil == PluginResultProvenance.from_details(~s({"status":"OK"}))
  end

  test "from_details prefers the server-authored marker over a payload's downstream_ingest" do
    details =
      Jason.encode!(%{
        "_serviceradar_plugin_result" => %{
          "provenance" => %{"plugin_package_id" => "real-package"}
        },
        "downstream_ingest" => %{"provenance" => %{"plugin_package_id" => "forged-package"}}
      })

    assert %{"plugin_package_id" => "real-package"} ==
             PluginResultProvenance.from_details(details)
  end
end
