defmodule ServiceRadar.Identity.SAMLAssertionCleanupWorker do
  @moduledoc """
  Deletes expired rows from the SAML assertion replay ledger
  (`ServiceRadar.Identity.SAMLConsumedAssertion`).

  A ledger row only matters while its assertion could still be accepted, which
  the assertion consumer bounds by the assertion's `NotOnOrAfter`. Rows are
  deleted once `not_on_or_after` is more than `grace_seconds` in the past
  (default 300). The grace period absorbs clock skew between the web node that
  validated the assertion and the database clock this sweep compares against:
  deleting a row while a skewed node still accepts its assertion would reopen
  the replay window the ledger exists to close.

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

  require Ash.Query
  require Logger

  @default_grace_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -grace_seconds(), :second)
    actor = SystemActor.system(:saml_assertion_cleanup)

    result =
      SAMLConsumedAssertion
      |> Ash.Query.filter(expr(not_on_or_after < ^cutoff))
      |> Ash.bulk_destroy(:destroy, %{},
        actor: actor,
        strategy: [:atomic, :stream],
        return_records?: false,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning("SAMLAssertionCleanupWorker: purge failed", reason: inspect(errors))
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
