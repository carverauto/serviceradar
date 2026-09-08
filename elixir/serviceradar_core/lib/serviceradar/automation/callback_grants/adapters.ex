defmodule ServiceRadar.Automation.CallbackGrants.Store do
  @moduledoc """
  Atomic persistence boundary for callback grant lifecycle operations.

  `activate/6` and `consume_once/7` must lock the grant, invoke the supplied
  authorization function against that locked record, and commit the state/use
  row/immutable response body or reference/budget/success audit in one
  transaction. The lifecycle passes only a keyed idempotency verifier to
  `consume_once/7`; implementations must never persist a plaintext bearer or
  idempotency key, or include either keyed verifier in audit data.
  """

  @type context :: term()
  @type authorization_hook :: (map() -> :ok | {:error, term()})

  @callback create_pending(map(), map(), context()) :: {:ok, map()} | {:error, term()}
  @callback fetch(binary(), context()) :: {:ok, map()} | {:error, term()}

  @callback bind_credential(
              binary(),
              pos_integer(),
              authorization_hook(),
              map(),
              DateTime.t(),
              context()
            ) :: {:ok, :bound | :existing, map()} | {:error, term()}

  @callback bind_job(
              binary(),
              map(),
              authorization_hook(),
              map(),
              DateTime.t(),
              context()
            ) :: {:ok, :bound | :existing, map()} | {:error, term()}

  @callback activate(binary(), map(), authorization_hook(), map(), DateTime.t(), context()) ::
              {:ok, :activated | :existing, map()} | {:error, term()}

  @callback consume_once(
              binary(),
              map(),
              binary(),
              authorization_hook(),
              map(),
              DateTime.t(),
              context()
            ) ::
              {:ok, :committed | :replay, binary(), map()} | {:error, term()}

  @callback transition_terminal(
              binary(),
              :revoked | :expired,
              binary(),
              map(),
              DateTime.t(),
              context()
            ) :: {:ok, map()} | {:error, term()}

  @callback transition_terminal_with_cleanup_binding(
              binary(),
              :revoked,
              binary(),
              map(),
              map(),
              DateTime.t(),
              context()
            ) :: {:ok, map()} | {:error, term()}

  @callback record_cleanup(binary(), map(), map(), context()) :: :ok | {:error, term()}
  @callback reconcile_cleanup_result(binary(), map(), context()) ::
              :ok | {:error, term()}
  @callback record_audit(map(), context()) :: :ok | {:error, term()}

  @optional_callbacks transition_terminal_with_cleanup_binding: 7,
                      record_cleanup: 4,
                      reconcile_cleanup_result: 3,
                      record_audit: 2
end

defmodule ServiceRadar.Automation.CallbackGrants.Authorizer do
  @moduledoc """
  Supplies current, principal-derived authority for intersection checks.

  A SystemActor may invoke transport code, but this adapter must resolve the
  human or owned service principal captured on the grant. It must not derive
  authority from the worker or transport actor.
  """

  @callback current_authority(
              :issue | :bind_credential | :bind_job | :activate | :use | :replay,
              map(),
              term()
            ) ::
              {:ok, map()} | {:error, term()}
end

defmodule ServiceRadar.Automation.CallbackGrants.Cleanup do
  @moduledoc """
  Best-effort external cleanup boundary used after callback authority has been
  atomically removed or consumed. The optional `delete_activated/2` callback is
  the bounded exception: it may only queue credential deletion after exact job
  and host-scope activation proof, without consuming the running callback.

  Adapters delete/detach the ephemeral credential for `:consumed`. For
  `:revoked`, `:expired`, or `:job_terminal`, they also cancel the AWX child
  when it is still running. Failures are returned as secret-free status maps so
  the store can durably retain orphan risk without re-enabling the grant.
  """

  @callback cleanup(map(), :consumed | :revoked | :expired | :job_terminal, term()) ::
              {:ok, map()} | {:error, map()}

  @callback delete_activated(map(), term()) :: {:ok, map()} | {:error, map()}

  @optional_callbacks delete_activated: 2
end

defmodule ServiceRadar.Automation.CallbackGrants.NoopCleanup do
  @moduledoc false
  @behaviour ServiceRadar.Automation.CallbackGrants.Cleanup

  @impl true
  def cleanup(_grant, mode, _context),
    do: {:ok, %{credential_cleanup: :not_configured, job_cleanup: job_cleanup(mode)}}

  defp job_cleanup(:consumed), do: :not_required
  defp job_cleanup(_mode), do: :not_configured
end
