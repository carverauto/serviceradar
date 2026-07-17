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
end
