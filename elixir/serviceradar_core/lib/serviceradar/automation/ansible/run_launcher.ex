defmodule ServiceRadar.Automation.Ansible.RunLauncher do
  @moduledoc """
  Fail-closed compatibility seam for the retired legacy AWX launcher.

  The former implementation persisted arbitrary `extra_vars`, selected targets
  from mutable device metadata, ignored individual target persistence errors,
  and could dispatch an empty or hostname-derived AWX limit. All callers must
  migrate to `HardenedLaunchPlan` plus `HardenedRunLauncher`; this module never
  falls back to the legacy behavior.
  """

  alias ServiceRadar.Automation.Ansible.PlaybookRun

  @type intent :: %{
          required(:playbook_id) => String.t(),
          required(:device_uids) => [String.t()]
        }

  @type error_reason ::
          :hardened_awx_targeting_required
          | :playbook_required
          | :devices_required
          | :git_sourced_not_supported_v1
          | :playbook_unbound

  @doc """
  Rejects the legacy launch surface without creating a run or contacting AWX.

  `opts` remains accepted so existing UI, API, northbound, and schedule callers
  fail closed while they are migrated to the immutable planner.
  """
  @spec launch(intent(), keyword()) :: {:ok, PlaybookRun.t()} | {:error, error_reason()}
  def launch(_intent, _opts), do: apply(__MODULE__, :legacy_launch_disabled, [])

  @doc false
  def legacy_launch_disabled, do: {:error, :hardened_awx_targeting_required}

  @doc false
  @spec validate_intent(intent()) :: :ok | {:error, error_reason()}
  def validate_intent(intent) do
    cond do
      blank?(intent[:playbook_id]) ->
        {:error, :playbook_required}

      not is_list(intent[:device_uids]) or intent[:device_uids] == [] ->
        {:error, :devices_required}

      true ->
        :ok
    end
  end

  @doc false
  @spec resolve_controller_id(map()) :: {:ok, String.t()} | {:error, error_reason()}
  def resolve_controller_id(%{source_type: :awx, controller_id: id}) when is_binary(id),
    do: {:ok, id}

  def resolve_controller_id(%{source_type: :git}), do: {:error, :git_sourced_not_supported_v1}
  def resolve_controller_id(_), do: {:error, :playbook_unbound}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
