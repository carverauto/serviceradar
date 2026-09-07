defmodule ServiceRadarWebNGWeb.Channels.RemoteAccessHostKeyFailure do
  @moduledoc """
  Classifies an agent-reported SSH host-key verification failure.

  The agent has no structured channel back to the browser: a failed open is a
  console `error`/`close` frame whose only payload is a reason string. The edge
  connector (`go/pkg/agent/remoteaccess/ssh_host_key.go`) therefore emits a
  fixed sentence shape for the two host-key outcomes an operator can act on,
  and this module is the single place that reads it back.

  Only `:unknown` — the target has no entry in the agent known-hosts store —
  may be offered for acceptance. `:mismatch` means a host that was already
  trusted offered a different key, which is the man-in-the-middle case and must
  stay a hard close.
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

  @type t :: %{
          required(:state) => String.t(),
          required(:target) => String.t(),
          required(:algorithm) => String.t(),
          required(:fingerprint) => String.t()
        }

  @doc """
  Returns the host-key trust decision a close reason describes, or `nil` when
  the reason is not a host-key verification failure.
  """
  @spec classify(term()) :: t() | nil
  def classify(reason) when is_binary(reason) do
    match(@unknown_pattern, "unknown", reason) || match(@mismatch_pattern, "mismatch", reason)
  end

  def classify(_reason), do: nil

  defp match(pattern, state, reason) do
    case Regex.named_captures(pattern, reason) do
      nil -> nil
      captures -> describe(state, captures)
    end
  end

  defp describe(state, %{"target" => target, "algorithm" => algorithm, "fingerprint" => fingerprint}) do
    %{
      state: state,
      target: target,
      algorithm: algorithm,
      fingerprint: fingerprint
    }
  end
end
