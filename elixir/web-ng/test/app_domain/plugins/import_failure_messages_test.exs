defmodule ServiceRadarWebNG.Plugins.ImportFailureMessagesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.ImportFailureMessages

  @moduletag :db_free

  @tunnel_407 {:could_not_establish_ssl_tunnel, {~c"HTTP/1.1", 407, ~c"Request rejected by proxy"}}

  defp refused_407_text(host) do
    @tunnel_407
    |> ImportFailureMessages.with_refused_host(host)
    |> ImportFailureMessages.reason_to_text()
  end

  describe "reason_to_text/1" do
    test "an egress proxy 407 names the host it refused and the fix" do
      text = refused_407_text("github-releases.githubusercontent.com")

      assert text =~ "egress proxy rejected the connection to github-releases.githubusercontent.com (HTTP 407)"
      assert text =~ "allow github-releases.githubusercontent.com in the egress proxy ACL"
      refute text =~ "registry.carverauto.dev"

      assert refused_407_text("registry.carverauto.dev") =~
               "connection to registry.carverauto.dev (HTTP 407) - allow the plugin registry host in the egress proxy ACL"
    end

    test "an egress proxy 407 with no known host names no host" do
      text = ImportFailureMessages.reason_to_text(@tunnel_407)

      assert text =~ "the egress proxy refused the connection (HTTP 407)"
      refute text =~ "registry.carverauto.dev"
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

    test "ash invalid error extracts manifest schema error message" do
      invalid = %Ash.Error.Invalid{
        errors: [
          %Ash.Error.Changes.InvalidAttribute{
            field: :manifest,
            message: "properties.targets.items.properties.kind.type is required"
          }
        ]
      }

      assert ImportFailureMessages.reason_to_text(invalid) ==
               "manifest schema invalid: properties.targets.items.properties.kind.type is required"
    end

    test "invalid manifest and config schema tuples format schema path and reason" do
      assert ImportFailureMessages.reason_to_text({:invalid_manifest, ["id is required"]}) ==
               "manifest schema invalid: id is required"

      assert ImportFailureMessages.reason_to_text(
               {:invalid_config_schema, ["properties.targets.items.properties.kind.type is required"]}
             ) ==
               "config schema invalid: properties.targets.items.properties.kind.type is required"
    end

    test "invalid bundle wraps inner reason" do
      assert ImportFailureMessages.reason_to_text({:invalid_bundle, :bundle_too_large}) =~
               "plugin bundle is invalid"
    end

    test "unknown shapes still fall back to the previous wording" do
      assert ImportFailureMessages.reason_to_text({:something_new, %{deep: true}}) ==
               "import was rejected"
    end
  end
end
