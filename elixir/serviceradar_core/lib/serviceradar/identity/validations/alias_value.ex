defmodule ServiceRadar.Identity.Validations.AliasValue do
  @moduledoc """
  Address-typed aliases must pass `Identity.AliasPolicy`.

  `:ip` is what DIRE merges on. `:interface_ip` is not a merge key, but
  loopback and link-local are still worthless as a record of "this device
  has this address". Other alias types (service_id, mac) have their own
  value spaces and are left alone.

  This lives on the resource so a producer that forgets to call the policy
  still cannot persist `fe80::/10` as identity evidence. GitHub #4022:
  grep for the attribute, not the call site.

  It runs on every action that creates or activates an alias (detection,
  sightings, confirmation, reactivation), so an alias detected before its
  subnet was known cannot be confirmed once the subnet is (GitHub #5743).
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Identity.AliasPolicy

  @address_types [:ip, :interface_ip]

  @impl true
  def validate(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :alias_type)
    value = Ash.Changeset.get_attribute(changeset, :alias_value)
    device_id = Ash.Changeset.get_attribute(changeset, :device_id)
    metadata = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

    cond do
      type not in @address_types ->
        :ok

      AliasPolicy.valid_alias_ip_for_device?(value, device_id, metadata) ->
        :ok

      true ->
        {:error, field: :alias_value, message: "is not valid identity alias evidence"}
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
