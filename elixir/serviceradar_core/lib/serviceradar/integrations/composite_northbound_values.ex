defmodule ServiceRadar.Integrations.CompositeNorthboundValues do
  @moduledoc """
  Composite check values to publish northbound for a set of devices.

  Returns a map keyed by device UID, and **a device with no result is absent
  from it**. That is the whole design: the spec forbids sending a placeholder
  for a device outside the check's scope, and making absence the natural
  representation means omission cannot be forgotten by a later step. A map with
  `nil` values would put that obligation on every caller instead.

  Only enabled checks produce values. A draft's result rows are whatever the
  last preview or prior enablement left behind and nothing maintains them on a
  schedule, so exporting them would publish a number that silently stops moving.
  """

  import Ecto.Query

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Repo

  require Logger

  @type export :: %{
          check_slug: String.t(),
          value_form: :verdict | :status,
          custom_field: String.t()
        }

  @doc """
  `%{device_uid => value}` for the export's check, over `device_uids`.

  `opts` are Ash options — `actor:` for a background run.

  Returns `%{}` rather than raising for every "cannot answer" case: an unknown
  slug, a disabled check, an empty device list, or a read failure. A northbound
  run that cannot resolve the composite selection should still publish
  availability, not fail outright.
  """
  @spec for_devices(export() | nil, [String.t()], keyword()) :: %{String.t() => String.t()}
  def for_devices(export, device_uids, opts \\ [])

  def for_devices(nil, _device_uids, _opts), do: %{}
  def for_devices(_export, [], _opts), do: %{}

  def for_devices(%{check_slug: slug, value_form: form}, device_uids, opts)
      when is_binary(slug) and form in [:verdict, :status] do
    case enabled_check(slug, opts) do
      {:ok, check} -> load(check, form, Enum.uniq(device_uids))
      :error -> %{}
    end
  end

  def for_devices(_export, _device_uids, _opts), do: %{}

  defp enabled_check(slug, opts) do
    case CompositeCheck.get_by_slug(slug, opts) do
      {:ok, %{state: :enabled} = check} -> {:ok, check}
      _other -> :error
    end
  end

  # One query for the whole run. Reading per batch would be an N+1 in the number
  # of batches, which grows with the device population the export covers.
  defp load(check, form, device_uids) do
    DeviceCompositeCheckResult
    |> where([r], r.check_id == ^check.id and r.device_uid in ^device_uids)
    |> select([r], {r.device_uid, r.verdict, r.status})
    |> Repo.all()
    |> Map.new(fn {uid, verdict, status} -> {uid, value(form, verdict, status)} end)
  rescue
    exception ->
      # Degrading to "no composite values" keeps availability publishing, but a
      # silent degrade is indistinguishable from a check that legitimately has
      # no results — so it is logged rather than swallowed.
      Logger.warning("composite northbound values unavailable",
        check_id: check.id,
        reason: Exception.message(exception)
      )

      %{}
  end

  defp value(:verdict, verdict, _status), do: verdict
  defp value(:status, _verdict, status), do: to_string(status)
end
