defmodule ServiceRadar.Automation.Ansible.SecureLaunchService do
  @moduledoc """
  ServiceRadar-owned entry point for human-initiated AWX execution.

  Callers provide only a current human actor, canonical device UIDs, a catalog
  playbook ID, and binding-declared input values. The service resolves current
  membership and approval state on every submit, canonicalizes the reviewed
  non-secret inputs, and delegates the exact durable membership IDs to
  `SecureChildLauncher`.

  It deliberately accepts no host name, address, AWX limit, credential,
  callback policy, or raw `extra_vars` override.
  """

  alias ServiceRadar.Automation.Ansible.SecureChildLauncher
  alias ServiceRadar.Automation.Ansible.SecureLaunchResolver
  alias ServiceRadar.Automation.Ansible.VariableSchema

  @type launch_opts :: [
          mode: :run | :check,
          request_source: String.t() | atom(),
          now: DateTime.t(),
          resolver: module(),
          resolver_adapter: module(),
          launcher: module(),
          launcher_adapter: module()
        ]

  @doc "Resolves current target, binding, and typed-input readiness for display."
  @spec prepare(map(), [String.t()], String.t(), keyword()) ::
          {:ok, SecureLaunchResolver.resolution()} | {:error, term()}
  def prepare(actor, device_uids, playbook_id, opts \\ []) when is_list(opts) do
    resolver = Keyword.get(opts, :resolver, SecureLaunchResolver)
    resolver.resolve(actor, device_uids, playbook_id, resolver_opts(opts))
  end

  @doc "Re-resolves and launches one exact child using the current human actor."
  @spec launch(map(), [String.t()], String.t(), map(), launch_opts()) ::
          {:ok, map()} | {:error, term()}
  def launch(actor, device_uids, playbook_id, input_params, opts \\ [])

  def launch(actor, device_uids, playbook_id, input_params, opts)
      when is_map(input_params) and is_list(opts) do
    mode = Keyword.get(opts, :mode, :run)
    request_source = Keyword.get(opts, :request_source, :serviceradar_ui)
    launcher = Keyword.get(opts, :launcher, SecureChildLauncher)

    with {:ok, resolution} <- prepare(actor, device_uids, playbook_id, opts),
         :ok <- approved_mode(resolution, mode),
         {:ok, inputs} <-
           VariableSchema.validated_non_secret_inputs(resolution.variables, input_params) do
      launcher.launch(
        %{
          actor: actor,
          membership_ids: resolution.membership_ids,
          playbook_id: resolution.playbook_id,
          job_template_id: resolution.job_template_id,
          mode: mode,
          inputs: inputs,
          request_source: request_source
        },
        launcher_opts(opts)
      )
    end
  end

  def launch(_actor, _device_uids, _playbook_id, _input_params, _opts),
    do: {:error, :invalid_secure_launch_request}

  defp approved_mode(%{run_mode_supported: true}, :run), do: :ok
  defp approved_mode(%{check_mode_supported: true}, :check), do: :ok

  defp approved_mode(_resolution, mode) when mode in [:run, :check],
    do: {:error, :binding_mode_not_approved}

  defp approved_mode(_resolution, _mode), do: {:error, :invalid_launch_mode}

  defp resolver_opts(opts) do
    []
    |> maybe_put(:adapter, Keyword.get(opts, :resolver_adapter))
    |> maybe_put(:now, Keyword.get(opts, :now))
  end

  defp launcher_opts(opts) do
    []
    |> maybe_put(:adapter, Keyword.get(opts, :launcher_adapter))
    |> maybe_put(:now, Keyword.get(opts, :now))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
