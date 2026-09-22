defmodule ServiceRadarWebNGWeb.Channels.RemoteAccessHostKeyFailure do
  @moduledoc """
  Classifies an agent-reported SSH host-key verification failure.

  The agent has no structured channel back to the browser: a failed open is a
  console `error`/`close` frame whose only payload is a reason string. The edge
  connector (`go/pkg/agent/remoteaccess/ssh_host_key.go`) therefore emits a
  fixed sentence shape for the two host-key outcomes an operator can act on,
  and this module is the single place that reads it back.

  Only `:unknown` — the target has no entry in the agent known-hosts store —
  may be offered for acceptance. `:mismatch` means the offered key differs from
  a pinned key, or the retry differs from the approved target and fingerprint.
  It can indicate interception and must stay a hard close.

  ## Agents that predate the sentence shape

  `ssh_host_key.go` arrived in agent 1.4.52. Every older agent reports the bare
  `x/crypto/ssh/knownhosts` text instead — `knownhosts: key is unknown` or
  `knownhosts: key mismatch` — which names neither the target nor the offered
  key. Those reasons are classified too, with `reviewable: false`, because an
  agent fleet upgrades on its own schedule and the alternative is the opaque
  hard close this module exists to replace.

  `reviewable` is the whole distinction and the console must honor it: a
  `reviewable: false` decision carries no fingerprint, so accepting it is
  trust-on-first-use without review — the same trust the operator would extend
  by running `ssh-keyscan` against the target and pinning the result — and not
  the reviewed acceptance a fingerprint-bearing decision offers. A revoked key
  (`knownhosts: key is revoked`) is deliberately unmatched: it is never
  offerable and stays a hard close.
  """

  @unknown_pattern ~r/
    ssh\shost\skey\sis\snot\strusted:\s
    (?<target>\S+)\soffered\s
    (?<algorithm>\S+)\s
    (?<fingerprint>SHA256:[A-Za-z0-9+\/=]+)
  /x

  @mismatch_pattern ~r/
    ssh\shost\skey\sdoes\snot\smatch\sthe\strusted\sentry:\s
    (?<target>\S+)\soffered\s
    (?<algorithm>\S+)\s
    (?<fingerprint>SHA256:[A-Za-z0-9+\/=]+)
  /x

  @legacy_unknown_pattern ~r/knownhosts:\s+key\s+is\s+unknown/
  @legacy_mismatch_pattern ~r/knownhosts:\s+key\s+mismatch/

  @type t :: %{
          required(:state) => String.t(),
          required(:reviewable) => boolean(),
          required(:target) => String.t() | nil,
          required(:algorithm) => String.t() | nil,
          required(:fingerprint) => String.t() | nil
        }

  @doc """
  Returns the host-key trust decision a close reason describes, or `nil` when
  the reason is not a host-key verification failure.
  """
  @spec classify(term()) :: t() | nil
  def classify(reason) when is_binary(reason) do
    match(@unknown_pattern, "unknown", reason) ||
      match(@mismatch_pattern, "mismatch", reason) ||
      legacy_match(@legacy_unknown_pattern, "unknown", reason) ||
      legacy_match(@legacy_mismatch_pattern, "mismatch", reason)
  end

  def classify(_reason), do: nil

  defp match(pattern, state, reason) do
    case Regex.named_captures(pattern, reason) do
      nil -> nil
      captures -> describe(state, captures)
    end
  end

  defp legacy_match(pattern, state, reason) do
    if Regex.match?(pattern, reason) do
      %{state: state, reviewable: false, target: nil, algorithm: nil, fingerprint: nil}
    end
  end

  defp describe(state, %{"target" => target, "algorithm" => algorithm, "fingerprint" => fingerprint}) do
    %{
      state: state,
      reviewable: true,
      target: target,
      algorithm: algorithm,
      fingerprint: fingerprint
    }
  end
end
