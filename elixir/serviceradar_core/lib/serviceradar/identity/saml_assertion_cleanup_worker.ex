defmodule ServiceRadar.Identity.SAMLAssertionCleanupWorker do
  @moduledoc """
  Deletes expired rows from the two SAML login tables:

  - the assertion replay ledger (`ServiceRadar.Identity.SAMLConsumedAssertion`),
    once `not_on_or_after` has passed;
  - SP-initiated logins that were never completed
    (`ServiceRadar.Identity.SAMLPendingRequest`), once `expires_at` has passed.
    The assertion consumer rejects an expired pending request anyway; this only
    reclaims the rows.

  Both use the same cutoff: now minus `grace_seconds` (default 300). The grace
  period absorbs clock skew between the web node that validated an assertion
  and the database clock this sweep compares against: deleting a ledger row
  while a skewed node still accepts its assertion would reopen the replay
  window the ledger exists to close.

  Idempotent and argument-free. Scheduled from the Oban crontab in
  `serviceradar_core_elx/config/runtime.exs` (mirrored in this project's
  runtime.exs).
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.SAMLConsumedAssertion
  alias ServiceRadar.Identity.SAMLPendingRequest

  require Ash.Query
  require Logger

  @default_grace_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -grace_seconds(), :second)
    actor = SystemActor.system(:saml_assertion_cleanup)

    consumed = Ash.Query.filter(SAMLConsumedAssertion, expr(not_on_or_after < ^cutoff))
    pending = Ash.Query.filter(SAMLPendingRequest, expr(expires_at < ^cutoff))

    with :ok <- purge(consumed, actor) do
      purge(pending, actor)
    end
  end

  defp purge(query, actor) do
    result =
      Ash.bulk_destroy(query, :destroy, %{},
        actor: actor,
        strategy: [:atomic, :stream],
        return_records?: false,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning("SAMLAssertionCleanupWorker: purge failed",
          resource: inspect(query.resource),
          reason: inspect(errors)
        )

        {:error, errors}
    end
  end

  defp grace_seconds do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    case Keyword.get(config, :grace_seconds) do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds
      _ -> @default_grace_seconds
    end
  end
end
