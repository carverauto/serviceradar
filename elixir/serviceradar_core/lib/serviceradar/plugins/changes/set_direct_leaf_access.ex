defmodule ServiceRadar.Plugins.Changes.SetDirectLeafAccess do
  @moduledoc """
  Records the direct-leaf subject contract whenever an add-on assignment changes.

  This change does not issue credentials. A direct assignment is marked
  `pending` only when its subject scope or selected edge site changes; an
  unchanged ready identity remains usable while unrelated add-on settings
  change. Relay assignments clear all direct access metadata.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Edge.DirectLeafIdentityIssuer
  alias ServiceRadar.Edge.DirectLeafScope

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    params = Ash.Changeset.get_attribute(changeset, :params) || %{}

    if direct?(params) do
      set_direct_access_metadata(changeset, params)
    else
      previous_status = Map.get(changeset.data, :direct_access_status, :not_requested)

      generation =
        if previous_status == :not_requested,
          do: current_generation(changeset),
          else: current_generation(changeset) + 1

      changeset
      |> Ash.Changeset.change_attribute(:direct_subject_scope, %{})
      |> Ash.Changeset.change_attribute(:direct_access_status, :not_requested)
      |> Ash.Changeset.change_attribute(:direct_access_generation, generation)
      |> Ash.Changeset.change_attribute(:direct_access_expires_at, nil)
      |> Ash.Changeset.change_attribute(:direct_access_revoked_at, nil)
      |> Ash.Changeset.change_attribute(:direct_access_error, nil)
      |> clear_identity_material()
      |> revoke_previous_identity(changeset.data, "direct leaf transport disabled")
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp set_direct_access_metadata(changeset, params) do
    {scope, error} =
      case DirectLeafScope.build(params) do
        {:ok, scope} -> {scope, nil}
        {:error, reason} -> {%{}, Atom.to_string(reason)}
      end

    if unchanged_identity_contract?(changeset, scope) and is_nil(error) do
      changeset
    else
      generation = next_generation(changeset, scope)

      changeset
      |> Ash.Changeset.change_attribute(:direct_subject_scope, scope)
      |> Ash.Changeset.change_attribute(:direct_access_status, :pending)
      |> Ash.Changeset.change_attribute(:direct_access_generation, generation)
      |> Ash.Changeset.change_attribute(:direct_access_expires_at, nil)
      |> Ash.Changeset.change_attribute(:direct_access_revoked_at, nil)
      |> Ash.Changeset.change_attribute(:direct_access_error, error)
      |> clear_identity_material()
      |> revoke_previous_identity(changeset.data, "direct leaf identity rotated")
    end
  end

  defp direct?(params) when is_map(params) do
    params
    |> map_value(:output)
    |> map_value(:backend)
    |> normalize_backend() == :jetstream
  end

  defp direct?(_params), do: false

  defp next_generation(changeset, scope) do
    previous_generation = current_generation(changeset)
    previous_scope = Map.get(changeset.data, :direct_subject_scope, %{}) || %{}
    previous_site = Map.get(changeset.data, :edge_site_id)
    current_site = current_site(changeset)

    if previous_scope == scope and previous_site == current_site,
      do: previous_generation,
      else: previous_generation + 1
  end

  defp current_generation(changeset),
    do: Map.get(changeset.data, :direct_access_generation, 0) || 0

  defp unchanged_identity_contract?(changeset, scope) do
    Map.get(changeset.data, :direct_subject_scope, %{}) == scope and
      Map.get(changeset.data, :edge_site_id) == current_site(changeset) and
      Map.get(changeset.data, :direct_access_status, :not_requested) in [:ready, :pending]
  end

  defp current_site(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :edge_site_id) do
      Ash.Changeset.get_attribute(changeset, :edge_site_id)
    else
      Map.get(changeset.data, :edge_site_id)
    end
  end

  defp clear_identity_material(changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:encrypted_direct_certificate_pem, nil)
    |> Ash.Changeset.force_change_attribute(:encrypted_direct_private_key_pem, nil)
    |> Ash.Changeset.force_change_attribute(:encrypted_direct_ca_chain_pem, nil)
    |> Ash.Changeset.change_attribute(:direct_certificate_fingerprint, nil)
    |> Ash.Changeset.change_attribute(:direct_identity_component_id, nil)
    |> Ash.Changeset.change_attribute(:direct_identity_partition_id, nil)
  end

  defp revoke_previous_identity(changeset, previous, reason) do
    if previous_identity?(previous) do
      previous = Map.put(previous, :agent_uid, Map.get(previous, :agent_uid))

      AfterAction.after_action(changeset, fn _record ->
        case DirectLeafIdentityIssuer.revoke(previous, reason: reason) do
          :ok ->
            :ok

          {:error, revoke_error} ->
            Logger.warning(
              "Direct-leaf identity revocation could not reach the gateway: " <>
                "assignment=#{Map.get(previous, :id)} reason=#{inspect(revoke_error)}"
            )
        end
      end)
    else
      changeset
    end
  end

  defp previous_identity?(previous) when is_map(previous) do
    is_binary(Map.get(previous, :direct_certificate_fingerprint)) or
      is_binary(Map.get(previous, :direct_identity_component_id))
  end

  defp previous_identity?(_previous), do: false

  defp normalize_backend(:jetstream), do: :jetstream
  defp normalize_backend("jetstream"), do: :jetstream
  defp normalize_backend(_backend), do: :agent

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil
end
