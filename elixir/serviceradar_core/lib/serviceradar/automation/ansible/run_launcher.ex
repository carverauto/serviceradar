defmodule ServiceRadar.Automation.Ansible.RunLauncher do
  @moduledoc """
  Orchestration helper that turns a launch intent (playbook + target
  devices + extra_vars) into a `PlaybookRun` row and dispatches the
  AWX launch via `AwxClient`.

  Both the ad-hoc launch path (the LiveView Device Actions modal /
  `/ansible/launch`) and the schedule-driven path
  (`ScheduleEvaluatorWorker`) call this. Keeping the orchestration in
  one place ensures the two paths share validation, host-limit
  derivation, and dispatch behaviour.

  Steps:

    1. Validate the intent (playbook + at least one device).
    2. Load the playbook; resolve its controller (AWX-sourced only in
       v1).
    3. Load the target devices; verify all are ansible-managed and
       share one controller.
    4. Create the `PlaybookRun` (in `:pending`).
    5. Create one `PlaybookRunTarget` per device.
    6. Dispatch `awx.launch_job` via `AwxClient`, threading
       `playbook_run_id` through `context` so EventIngestor can
       correlate the result.

  `EventIngestor.handle_command_result` will receive the launch
  result and transition the run from `:pending` → `:launching` /
  `:failed`.
  """

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.PlaybookRunTarget
  alias ServiceRadar.Automation.Ansible.ScheduleEvaluatorWorker
  alias ServiceRadar.Inventory.Device

  require Logger

  @type intent :: %{
          required(:playbook_id) => String.t(),
          required(:device_uids) => [String.t()],
          optional(:extra_vars) => map(),
          optional(:schedule_id) => String.t() | nil,
          optional(:requested_by_actor_id) => String.t() | nil
        }

  @type error_reason ::
          :playbook_required
          | :devices_required
          | :unknown_playbook
          | :unknown_controller
          | :unknown_devices
          | :unmanaged_devices
          | :mixed_controllers
          | :git_sourced_not_supported_v1
          | :playbook_unbound
          | term()

  @doc """
  Launch one playbook against the given devices.

  Required keys in `intent`: `:playbook_id`, `:device_uids`.
  Optional: `:extra_vars`, `:schedule_id`, `:requested_by_actor_id`.

  Required opts: `:actor` (an Ash-acceptable actor — typically a
  `SystemActor.system(...)` or the logged-in user).

  Returns `{:ok, run}` on successful dispatch (the run is in
  `:pending` until EventIngestor moves it forward), or
  `{:error, reason}`.
  """
  @spec launch(intent(), keyword()) :: {:ok, PlaybookRun.t()} | {:error, error_reason()}
  def launch(intent, opts) when is_map(intent) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- validate_intent(intent),
         {:ok, playbook} <- load_playbook(intent.playbook_id, actor),
         {:ok, controller_id} <- resolve_controller_id(playbook),
         {:ok, controller} <- load_controller(controller_id, actor),
         {:ok, devices} <- load_devices(intent.device_uids, actor),
         :ok <- validate_devices(devices, intent.device_uids, controller_id),
         {:ok, run} <- create_run(intent, playbook, controller, actor),
         :ok <- create_targets(run, devices, actor),
         {:ok, _command} <- dispatch_launch(controller, playbook, run, devices, intent) do
      {:ok, run}
    end
  end

  ## Validation ---------------------------------------------------------------

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

  defp validate_devices(devices, requested_uids, controller_id) do
    cond do
      length(devices) != length(requested_uids) ->
        {:error, :unknown_devices}

      Enum.any?(devices, &(!device_ansible_managed?(&1))) ->
        {:error, :unmanaged_devices}

      Enum.any?(devices, &(device_controller_id(&1) != controller_id)) ->
        {:error, :mixed_controllers}

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

  ## Steps --------------------------------------------------------------------

  defp load_playbook(id, actor) do
    case Playbook.get_by_id(id, actor: actor) do
      {:ok, playbook} -> {:ok, playbook}
      _ -> {:error, :unknown_playbook}
    end
  end

  defp load_controller(id, actor) do
    case Controller.get_by_id(id, actor: actor) do
      {:ok, controller} -> {:ok, controller}
      _ -> {:error, :unknown_controller}
    end
  end

  defp load_devices(uids, actor) do
    devices =
      uids
      |> Enum.map(fn uid ->
        case Device.get_by_uid(uid, false, actor: actor) do
          {:ok, device} -> device
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, devices}
  end

  defp create_run(intent, playbook, controller, actor) do
    PlaybookRun.create_run(
      %{
        playbook_id: playbook.id,
        controller_id: controller.id,
        schedule_id: intent[:schedule_id],
        requested_extra_vars: intent[:extra_vars] || %{},
        requested_by_actor_id: intent[:requested_by_actor_id],
        host_limit: nil,
        metadata: run_metadata(intent)
      },
      actor: actor
    )
  end

  defp create_targets(run, devices, actor) do
    Enum.each(devices, fn device ->
      ref = ansible_inventory_ref(device)

      _ =
        PlaybookRunTarget.create_target(
          %{
            run_id: run.id,
            device_uid: device.uid,
            awx_host_id: integer_value(ref["host_id"] || ref[:host_id]),
            awx_host_name:
              host_name_string(ref["host_name"] || ref[:host_name]) || device.hostname || "",
            metadata: %{}
          },
          actor: actor
        )
    end)

    :ok
  end

  defp dispatch_launch(controller, playbook, run, devices, intent) do
    host_limit = ScheduleEvaluatorWorker.build_host_limit(devices)

    AwxClient.launch_job(
      controller,
      playbook.awx_job_template_id,
      %{
        extra_vars: intent[:extra_vars] || %{},
        host_limit: host_limit
      },
      source: launch_source(intent),
      context: launch_context(controller, run, intent)
    )
  end

  defp launch_source(%{schedule_id: id}) when is_binary(id), do: :automation
  defp launch_source(_), do: :on_demand

  defp launch_context(controller, run, intent) do
    base =
      maybe_put_context(
        %{
          "playbook_run_id" => run.id,
          "controller_id" => controller.id,
          "verb" => "awx.launch_job"
        },
        "northbound_invocation_id",
        intent[:northbound_invocation_id]
      )

    case intent[:schedule_id] do
      id when is_binary(id) -> Map.put(base, "schedule_id", id)
      _ -> base
    end
  end

  defp run_metadata(intent) do
    maybe_put_context(%{}, "northbound_invocation_id", intent[:northbound_invocation_id])
  end

  defp maybe_put_context(map, _key, nil), do: map
  defp maybe_put_context(map, _key, ""), do: map
  defp maybe_put_context(map, key, value), do: Map.put(map, key, value)

  ## Helpers ------------------------------------------------------------------

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp device_ansible_managed?(device) do
    ref = ansible_inventory_ref(device)

    Map.get(device, :ansible_managed) == true or
      Map.get(device, "ansible_managed") == true or
      Map.get(ref, "managed") == true or
      Map.get(ref, :managed) == true
  end

  defp device_controller_id(device) do
    ref = ansible_inventory_ref(device)
    Map.get(ref, "controller_id") || Map.get(ref, :controller_id)
  end

  defp ansible_inventory_ref(device) when is_map(device) do
    explicit =
      Map.get(device, :ansible_inventory_ref) ||
        Map.get(device, "ansible_inventory_ref") ||
        get_in(Map.get(device, :metadata) || %{}, ["ansible_inventory_ref"]) ||
        get_in(Map.get(device, "metadata") || %{}, ["ansible_inventory_ref"])

    explicit || awx_inventory_ref(device) || %{}
  end

  # Derive the ansible inventory ref straight from the AWX inventory-sync
  # metadata (`metadata.awx.*`) that the awx-inventory-sync plugin writes onto
  # every synced host. This is what makes a device the operator sees "ansible
  # managed" (and launchable) without a separate ingestion step: any device that
  # is a member of an AWX inventory is runnable against its controller.
  defp awx_inventory_ref(device) do
    metadata = Map.get(device, :metadata) || Map.get(device, "metadata") || %{}

    case Map.get(metadata, "awx") || Map.get(metadata, :awx) do
      %{} = awx ->
        host_id = Map.get(awx, "host_id") || Map.get(awx, :host_id)

        if is_nil(host_id) do
          nil
        else
          %{
            "managed" => true,
            "controller_id" => Map.get(awx, "controller_id") || Map.get(awx, :controller_id),
            "host_id" => host_id,
            "host_name" => Map.get(awx, "host_name") || Map.get(awx, :host_name)
          }
        end

      _ ->
        nil
    end
  end

  defp host_name_string(nil), do: nil
  defp host_name_string(""), do: nil
  defp host_name_string(s) when is_binary(s), do: s
  defp host_name_string(_), do: nil

  defp integer_value(v) when is_integer(v), do: v
  defp integer_value(_), do: nil
end
