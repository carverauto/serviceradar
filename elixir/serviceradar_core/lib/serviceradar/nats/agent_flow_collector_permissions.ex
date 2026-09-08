defmodule ServiceRadar.NATS.AgentFlowCollectorPermissions do
  @moduledoc """
  Per-agent flow-collector NATS user permission template.

  This is the Elixir mirror of the Go helper
  `GenerateAgentFlowCollectorCreds` in
  `go/pkg/cli/nats_bootstrap.go`. It is the single source of truth on the
  Elixir side for the publish/subscribe ACL that an agent's flow-collector
  user JWT must carry.

  ## Why a separate module?

  Sub-issue 1 of the host-network-visibility / B-5 work mints these creds
  via the existing `ServiceRadar.NATS.AccountClient.generate_user_credentials/5`
  gRPC path rather than introducing a new RPC. Keeping the permission
  template (and the subject-token safety check) in one named module makes
  the parity contract with the Go helper auditable from a single file
  and lets the same shape be reused by the rotation worker (sub-issue
  follow-ups) without re-deriving the ACL.

  ## Trust model

  - The account seed lives only on core/Elixir
    (`Application.get_env(:serviceradar, :nats_account_seed)`).
  - The agent only ever receives the resulting `*.creds` file, never the
    seed itself. This mirrors the collector pattern (see
    `provision_collector_worker.ex`) and the explicit comment on the Go
    helper that the seed "should be... held by core and never written to
    agent disk in cleartext".
  """

  @typedoc """
  Output map used by `permissions/1`. Keys match the keyword list shape
  consumed by `ServiceRadar.NATS.AccountClient.generate_user_credentials/5`
  when passed as `permissions:`.
  """
  @type permissions :: %{
          publish_allow: [String.t()],
          publish_deny: [String.t()],
          subscribe_allow: [String.t()],
          subscribe_deny: [String.t()],
          allow_responses: boolean(),
          max_responses: non_neg_integer()
        }

  @doc """
  Build the NATS user-permission shape for an agent's flow-collector
  JWT, scoped to `agent_id`.

  Returns `{:error, :invalid_agent_id}` if `agent_id` would not be safe
  as a single NATS subject token (matches `isSafeSubjectToken/1` on the
  Go side and the `agent_id` validation in
  `rust/flow-collector/src/host_slice.rs`).
  """
  @spec permissions(String.t()) :: {:ok, permissions()} | {:error, :invalid_agent_id}
  def permissions(agent_id) when is_binary(agent_id) do
    if safe_subject_token?(agent_id) do
      {:ok, build_permissions(agent_id)}
    else
      {:error, :invalid_agent_id}
    end
  end

  def permissions(_), do: {:error, :invalid_agent_id}

  @doc """
  Returns the canonical NATS user name for an agent's flow-collector
  credential. Always mirrors the Go helper's `"flow-collector-" <> agent_id`.
  """
  @spec user_name(String.t()) :: String.t()
  def user_name(agent_id) when is_binary(agent_id), do: "flow-collector-" <> agent_id

  @doc """
  Returns `true` iff `token` is safe to embed as a single NATS subject
  token. The character set must match `isSafeSubjectToken/1` in
  `go/pkg/cli/nats_bootstrap.go` byte-for-byte: ASCII letters, ASCII
  digits, `-`, and `_`. Anything else (including `.`, `>`, `*`,
  whitespace, `/`) is rejected.
  """
  @spec safe_subject_token?(term()) :: boolean()
  def safe_subject_token?(token) when is_binary(token) and byte_size(token) > 0 do
    token
    |> :binary.bin_to_list()
    |> Enum.all?(&safe_char?/1)
  end

  def safe_subject_token?(_), do: false

  defp safe_char?(c) when c in ?a..?z, do: true
  defp safe_char?(c) when c in ?A..?Z, do: true
  defp safe_char?(c) when c in ?0..?9, do: true
  defp safe_char?(?-), do: true
  defp safe_char?(?_), do: true
  defp safe_char?(_), do: false

  defp build_permissions(agent_id) do
    %{
      publish_allow: [
        "flow.host-slice." <> agent_id,
        "$JS.API.>",
        "$JS.ACK.>",
        "_INBOX.>"
      ],
      publish_deny: ["$SYS.>", "flow.attributed.>"],
      subscribe_allow: [
        "$JS.API.>",
        "$JS.ACK.>",
        "_INBOX.>",
        "config.flow-collector." <> agent_id <> ".>"
      ],
      subscribe_deny: ["$SYS.>", "flow.host-slice.>", "flow.attributed.>"],
      allow_responses: true,
      max_responses: 16
    }
  end
end
