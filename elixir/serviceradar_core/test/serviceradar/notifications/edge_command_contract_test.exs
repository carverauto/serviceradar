defmodule ServiceRadar.Notifications.EdgeCommandContractTest do
  @moduledoc """
  The edge notification command is a CROSS-LANGUAGE contract.

  `ServiceRadar.Notifications.Dispatcher` stamps an envelope schema on every
  `plugin.run_action` payload it dispatches to an agent, and `go/pkg/agent`
  keys its `notify:v1` capability gate on that exact string. If the two ever
  disagree the failure is silent and bad: the agent stops RECOGNISING
  notification traffic, so it stops gating it, and a capability that reads as
  enforced is not.

  There is no shared codegen for this one string, so this test is the seam.
  It reads the Go source directly rather than asserting a copy of the literal,
  because a copy would drift in exactly the same way the constant would.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Plugins.Manifest

  @go_notify_path Path.expand(
                    "../../../../../go/pkg/agent/plugin_runtime_notify.go",
                    __DIR__
                  )

  @external_resource @go_notify_path

  test "the agent and the dispatcher name the same envelope schema" do
    source = File.read!(@go_notify_path)

    assert [[_line, schema]] =
             Regex.scan(
               ~r/notificationDeliveryEnvelopeSchema\s*=\s*"([^"]+)"/,
               source
             )

    assert schema == Dispatcher.edge_command_schema(),
           """
           go/pkg/agent/plugin_runtime_notify.go declares #{inspect(schema)} but \
           ServiceRadar.Notifications.Dispatcher declares \
           #{inspect(Dispatcher.edge_command_schema())}. The agent gates notify:v1 \
           on this string; a mismatch disables the gate.
           """
  end

  test "the agent gates on the capability the manifest validator allows" do
    source = File.read!(@go_notify_path)

    assert String.contains?(source, "deliversNotifications"),
           "the notify:v1 gate must exist in go/pkg/agent, not only in the Elixir allowlist"

    assert Manifest.notify_capability() == "notify:v1"

    capability_source =
      "../../../../../go/pkg/agent/plugin_runtime.go"
      |> Path.expand(__DIR__)
      |> File.read!()

    # Matched by regex rather than by literal so gofmt's alignment of the const
    # block cannot fail this test for a whitespace change.
    assert [[_line, capability]] =
             Regex.scan(~r/pluginCapabilityNotify\s*=\s*"([^"]+)"/, capability_source)

    assert capability == Manifest.notify_capability(),
           "go/pkg/agent must spell the capability exactly as the manifest allowlist does"
  end

  test "the agent serves exactly the injection modes the manifest allows" do
    # tasks 3.2.4. Two independent allowlists guard the same thing: the manifest
    # validator refuses a plugin.yaml declaring a mode outside the canonical set,
    # and the agent refuses a DISPATCH declaring one. If they drift, a plugin
    # author learns a spelling one surface accepts and the other rejects, and the
    # failure lands at delivery time on an alert nobody gets paged for.
    #
    # The list is closed for a reason worth restating: none of the six rewrites
    # a URL PATH. That is why a Slack or Discord incoming webhook cannot run on
    # the `:edge_agent` route at all, and why a `url_path` mode must be added to
    # the HOST first if it is ever added.
    source = File.read!(@go_notify_path)

    [[_block, body]] =
      Regex.scan(
        ~r/notificationCredentialInjectionModes\s*=\s*map\[string\]struct\{\}\{(.*?)\n\}/s,
        source
      )

    go_modes =
      ~r/"([a-z0-9_]+)"/
      |> Regex.scan(body)
      |> Enum.map(fn [_match, mode] -> mode end)
      |> Enum.sort()

    assert go_modes == Enum.sort(Manifest.allowed_credential_injection_modes()),
           """
           go/pkg/agent serves #{inspect(go_modes)} but the manifest validator allows \
           #{inspect(Enum.sort(Manifest.allowed_credential_injection_modes()))}.
           """

    refute "url_path" in go_modes,
           "a URL-path injection mode is out of scope for v1 (design Security)"
  end
end
