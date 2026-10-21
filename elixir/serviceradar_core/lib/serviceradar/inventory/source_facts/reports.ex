defmodule ServiceRadar.Inventory.SourceFacts.Reports do
  @moduledoc """
  Platform inventory facts that an external system reports for a device through
  the source-facts API (`Device` actions `:report_source_fact` and
  `:retract_source_fact`).

  The caller names its source with a label. The fact is stored under
  `api:<label>` (`SourceFacts.api_source/1`), so it can never be mistaken for a
  built-in integration or plugin, or match one of their authority rows. The
  source instance is the caller itself, so callers cannot overwrite or withdraw
  each other's facts. From there a reported fact takes the same path as one from
  a sync update: per-source storage, promotion and disagreement detection in
  `SourceFacts.Reconciler`.
  """

  import Ecto.Query

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.SourceFacts
  alias ServiceRadar.Inventory.SourceFacts.Reconciler
  alias ServiceRadar.Repo

  @spec report(map(), term()) :: {:ok, map()} | {:error, Exception.t()}
  def report(arguments, actor) do
    with {:ok, instance} <- caller_instance(actor),
         {:ok, source} <- check(:source, SourceFacts.api_source(arguments.source)),
         :ok <- check(:fact_key, SourceFacts.reported_key(arguments.fact_key)),
         {:ok, fact} <-
           check(:value, SourceFacts.parse_reported(arguments.fact_key, arguments.value)),
         :ok <- live_device(arguments.device_uid) do
      :ok = Reconciler.report(arguments.device_uid, source, instance, fact)
      {:ok, result(arguments, source, instance)}
    end
  end

  @spec retract(map(), term()) :: {:ok, map()} | {:error, Exception.t()}
  def retract(arguments, actor) do
    with {:ok, instance} <- caller_instance(actor),
         {:ok, source} <- check(:source, SourceFacts.api_source(arguments.source)),
         :ok <- check(:fact_key, SourceFacts.reported_key(arguments.fact_key)),
         :ok <- live_device(arguments.device_uid) do
      :ok = Reconciler.retract(arguments.device_uid, source, instance, arguments.fact_key)
      {:ok, result(arguments, source, instance)}
    end
  end

  # A user-bound credential (browser session, API token or OAuth client) acts for
  # a user, and that user is the instance.
  defp caller_instance(%{role: :system, id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp caller_instance(%{id: id}) when not is_nil(id), do: {:ok, "user:#{id}"}

  defp caller_instance(_actor),
    do: invalid(:actor, "reporting a source fact needs an authenticated caller")

  # Facts are not recorded against a deleted device.
  defp live_device(device_uid) when is_binary(device_uid) do
    if Repo.exists?(from(d in Device, where: d.uid == ^device_uid and is_nil(d.deleted_at))) do
      :ok
    else
      invalid(:device_uid, "no live device with that uid")
    end
  end

  defp live_device(_device_uid), do: invalid(:device_uid, "device uid is required")

  defp check(_field, :ok), do: :ok
  defp check(_field, {:ok, value}), do: {:ok, value}
  defp check(field, {:error, message}), do: invalid(field, message)

  defp invalid(field, message),
    do: {:error, InvalidArgument.exception(field: field, message: message)}

  defp result(arguments, source, instance) do
    snapshot = Reconciler.snapshot(arguments.device_uid, source, instance, arguments.fact_key)

    %{
      uid: arguments.device_uid,
      fact_key: arguments.fact_key,
      source: source,
      source_instance: instance,
      fact: snapshot.fact,
      canonical: snapshot.canonical,
      disagreement_open: snapshot.disagreement_open
    }
  end
end
