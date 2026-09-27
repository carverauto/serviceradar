defmodule ServiceRadar.Plugins.Validations.ProducerSchedulePackageApproved do
  @moduledoc """
  An enabled producer schedule may only reference an approved package.

  Disabling stays allowed: reconciliation disarms schedules after a package is
  revoked or superseded, and that update has to succeed.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Plugins.Validations.AddonPackageApproved
  alias ServiceRadar.Plugins.Validations.PackageApproved

  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def validate(changeset, opts, context) do
    if Ash.Changeset.get_attribute(changeset, :enabled) == true do
      case producer_kind(changeset) do
        :native_addon -> AddonPackageApproved.validate(changeset, opts, context)
        :wasm_plugin -> PackageApproved.validate(changeset, opts, context)
        _other -> {:error, field: :producer_kind, message: "producer package must be approved"}
      end
    else
      :ok
    end
  end

  defp producer_kind(changeset) do
    Ash.Changeset.get_attribute(changeset, :producer_kind) ||
      Map.get(changeset.data, :producer_kind)
  end
end
