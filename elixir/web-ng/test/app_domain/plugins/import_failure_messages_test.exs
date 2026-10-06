defmodule ServiceRadarWebNG.Plugins.ImportFailureMessagesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.ImportFailureMessages

  @moduletag :db_free

  describe "reason_to_text/1" do
    test "an egress proxy 407 names the plugin registry and the fix" do
      assert text =
               ImportFailureMessages.reason_to_text(
                 {:could_not_establish_ssl_tunnel, {~c"HTTP/1.1", 407, ~c"Request rejected by proxy"}}
               )

      assert text =~ "egress proxy rejected the connection to registry.carverauto.dev"
      assert text =~ "HTTP 407"
      assert text =~ "proxy ACL"
    end

    test "a non-407 CONNECT rejection keeps the proxy status" do
      assert ImportFailureMessages.reason_to_text({:could_not_establish_ssl_tunnel, {~c"HTTP/1.1", 502, ~c"bad gateway"}}) =~
               "CONNECT tunnel (HTTP 502"
    end

    test "registry authentication failures read as credential problems" do
      assert ImportFailureMessages.reason_to_text({:oci_token_http_error, 401}) =~
               "rejected the credentials (HTTP 401)"

      assert ImportFailureMessages.reason_to_text({:oci_manifest_http_error, 403}) =~
               "rejected the credentials (HTTP 403)"
    end

    test "other registry and artifact statuses name the endpoint and status" do
      assert ImportFailureMessages.reason_to_text({:oci_manifest_http_error, 404}) =~
               "registry returned HTTP 404 for the manifest"

      assert ImportFailureMessages.reason_to_text({:artifact_http_error, 500}) =~
               "artifact download returned HTTP 500"
    end

    test "transport reasons name the failure class" do
      assert ImportFailureMessages.reason_to_text(:timeout) =~ "timed out"
      assert ImportFailureMessages.reason_to_text(:nxdomain) =~ "DNS"
      assert ImportFailureMessages.reason_to_text(:econnrefused) =~ "refused"
      assert ImportFailureMessages.reason_to_text(%Req.TransportError{reason: :timeout}) =~ "timed out"

      assert ImportFailureMessages.reason_to_text(%Req.TransportError{reason: {:tls_alert, :unknown_ca}}) =~
               "TLS connection"
    end

    test "binary reasons pass through" do
      assert ImportFailureMessages.reason_to_text("Release tag v9.9.9 was not found") ==
               "Release tag v9.9.9 was not found"
    end

    test "unknown shapes still fall back to the previous wording" do
      assert ImportFailureMessages.reason_to_text({:something_new, %{deep: true}}) ==
               "import was rejected"
    end
  end
end
