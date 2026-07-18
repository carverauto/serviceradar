defmodule ServiceRadarWebNG.Plugins.UploadSignatureTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.UploadSignature

  @moduletag :db_free

  test "canonical payload preserves empty manifest arrays" do
    manifest = %{
      "permissions" => %{
        "allowed_domains" => [],
        "allowed_ports" => [8006]
      }
    }

    assert UploadSignature.verification_payload(manifest, "ABCDEF") ==
             ~s({"content_hash":"abcdef","manifest":{"permissions":{"allowed_domains":[],"allowed_ports":[8006]}}})
  end

  test "canonical payload distinguishes empty manifest maps from arrays" do
    manifest = %{
      "capabilities" => [],
      "permissions" => %{}
    }

    assert UploadSignature.verification_payload(manifest, "ABCDEF") ==
             ~s({"content_hash":"abcdef","manifest":{"capabilities":[],"permissions":{}}})
  end
end
