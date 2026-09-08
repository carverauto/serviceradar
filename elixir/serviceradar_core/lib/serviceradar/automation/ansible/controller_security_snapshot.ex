defmodule ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot do
  @moduledoc """
  Canonical, secret-free controller authority frozen into each execution.

  A controller UUID alone is not an immutable security boundary: its network
  origin, assigned edge agent, TLS policy, or credential references can change
  while an AWX child is in flight. This snapshot makes those selectors part of
  the reviewed launch state and requires exact equality at every continuation.
  """

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @schema "serviceradar.awx_controller_security_snapshot.v1"

  @spec capture(map() | struct()) :: {:ok, map()} | {:error, term()}
  def capture(controller) when is_map(controller) do
    with true <- value(controller, :enabled) == true,
         id when is_binary(id) and id != "" <- value(controller, :id),
         name when is_binary(name) and name != "" <- value(controller, :name),
         agent_id when is_binary(agent_id) and agent_id != "" <- value(controller, :agent_id),
         {:ok, %{base_url: base_url}} <-
           AwxClient.broker_scope(value(controller, :base_url), "awx.fetch_job", %{"job_id" => 1}),
         {:ok, sync_ref} <- Controller.credential_secret_id_for(controller, :sync),
         {:ok, execution_ref} <- Controller.credential_secret_id_for(controller, :execution),
         {:ok, callback_ref} <- optional_callback_ref(controller) do
      {:ok,
       %{
         "schema" => @schema,
         "controller_id" => id,
         "name" => name,
         "base_url" => base_url,
         "agent_id" => agent_id,
         "enabled" => true,
         "insecure_skip_verify" => insecure_skip_verify?(controller),
         "credential_refs" => %{
           "sync" => sync_ref,
           "execution" => execution_ref,
           "callback" => callback_ref
         }
       }}
    else
      false -> {:error, :controller_disabled}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_controller_security_snapshot}
    end
  end

  def capture(_controller), do: {:error, :invalid_controller_security_snapshot}

  @spec verify(map() | struct(), map()) :: :ok | {:error, term()}
  def verify(controller, expected) when is_map(controller) and is_map(expected) do
    with {:ok, current} <- capture(controller),
         true <- stringify(expected) == current || {:error, :controller_security_snapshot_drift} do
      :ok
    else
      false -> {:error, :controller_security_snapshot_drift}
      {:error, _reason} = error -> error
      _ -> {:error, :controller_security_snapshot_drift}
    end
  end

  def verify(_controller, _expected), do: {:error, :controller_security_snapshot_required}

  @spec digest(map()) :: {:ok, String.t()} | {:error, term()}
  def digest(snapshot) when is_map(snapshot), do: CanonicalJSON.digest(stringify(snapshot))
  def digest(_snapshot), do: {:error, :invalid_controller_security_snapshot}

  defp optional_callback_ref(controller) do
    case Controller.credential_secret_id_for(controller, :callback) do
      {:ok, reference} -> {:ok, reference}
      {:error, {:controller_credential_missing, :callback}} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp insecure_skip_verify?(controller) do
    metadata = value(controller, :metadata) || %{}
    value(metadata, :insecure_skip_verify) == true
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
