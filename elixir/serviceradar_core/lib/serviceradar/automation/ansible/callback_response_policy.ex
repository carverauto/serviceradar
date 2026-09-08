defmodule ServiceRadar.Automation.Ansible.CallbackResponsePolicy do
  @moduledoc false

  alias ServiceRadar.Automation.Ansible.UnavailableCallbackResponsePolicyProvider
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @provider_config :automation_callback_response_policy_provider

  @type snapshot :: %{targets: [map()], digest: binary()}

  @spec snapshot(map(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(context, opts \\ [])

  def snapshot(context, opts) when is_map(context) and is_list(opts) do
    expected_targets = value(context, :targets)

    with {:ok, provider} <- provider(opts),
         {:ok, supplied} <- safe_snapshot(provider, context),
         {:ok, targets} <- exact_targets(supplied),
         {:ok, targets} <- normalize_json(targets),
         true <-
           (is_list(expected_targets) and expected_targets != []) ||
             {:error, :callback_response_target_scope_mismatch},
         :ok <- exact_target_scope(targets, expected_targets),
         targets = Enum.sort_by(targets, &target_sort_key/1),
         {:ok, digest} <- CanonicalJSON.digest(%{"targets" => targets}) do
      {:ok, %{targets: targets, digest: digest}}
    else
      false -> {:error, :callback_response_target_scope_mismatch}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :callback_response_policy_unavailable}
  catch
    _, _ -> {:error, :callback_response_policy_unavailable}
  end

  def snapshot(_context, _opts), do: {:error, :invalid_callback_response_policy_context}

  defp provider(opts) do
    provider =
      Keyword.get(opts, :provider) ||
        Application.get_env(
          :serviceradar_core,
          @provider_config,
          UnavailableCallbackResponsePolicyProvider
        )

    with true <- is_atom(provider),
         {:module, ^provider} <- Code.ensure_loaded(provider),
         true <- function_exported?(provider, :snapshot, 1) do
      {:ok, provider}
    else
      _ -> {:error, :callback_response_policy_unavailable}
    end
  end

  defp safe_snapshot(provider, context) do
    case provider.snapshot(context) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_callback_response_policy_snapshot}
    end
  rescue
    _ -> {:error, :callback_response_policy_unavailable}
  catch
    _, _ -> {:error, :callback_response_policy_unavailable}
  end

  defp exact_targets(snapshot) do
    with {:ok, snapshot} <- normalize_json(snapshot),
         true <- Map.keys(snapshot) == ["targets"],
         targets when is_list(targets) and targets != [] <- snapshot["targets"] do
      {:ok, targets}
    else
      _ -> {:error, :invalid_callback_response_policy_snapshot}
    end
  end

  defp exact_target_scope(targets, expected) when length(targets) == length(expected) do
    actual = targets |> Enum.map(&target_scope/1) |> Enum.sort()
    expected = expected |> Enum.map(&target_scope/1) |> Enum.sort()

    if Enum.all?(actual, &valid_target_scope?/1) and actual == expected,
      do: :ok,
      else: {:error, :callback_response_target_scope_mismatch}
  end

  defp exact_target_scope(_targets, _expected),
    do: {:error, :callback_response_target_scope_mismatch}

  defp target_scope(target) do
    identity = value(target, :target_identity) || %{}

    {
      text(value(identity, :controller_id)),
      scalar_id(value(identity, :inventory_id)),
      scalar_id(value(identity, :awx_host_id)),
      text(value(identity, :canonical_device_uid)),
      text(value(target, :inventory_hostname)),
      text(value(target, :inventory_address))
    }
  end

  defp valid_target_scope?({controller_id, inventory_id, awx_host_id, device_uid, host, address}) do
    Enum.all?([controller_id, inventory_id, awx_host_id, device_uid, host, address], &present?/1)
  end

  defp target_sort_key(target), do: target_scope(target)

  defp normalize_json(nil), do: {:ok, nil}
  defp normalize_json(true), do: {:ok, true}
  defp normalize_json(false), do: {:ok, false}
  defp normalize_json(value) when is_binary(value) or is_integer(value), do: {:ok, value}

  defp normalize_json(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case normalize_json(value) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_json(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) ->
          {:halt, {:error, :invalid_callback_response_policy_snapshot}}

        Map.has_key?(normalized, key) ->
          {:halt, {:error, :invalid_callback_response_policy_snapshot}}

        true ->
          case normalize_json(value) do
            {:ok, value} -> {:cont, {:ok, Map.put(normalized, key, value)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp normalize_json(_value), do: {:error, :invalid_callback_response_policy_snapshot}

  defp scalar_id(value) when is_integer(value) and value > 0, do: Integer.to_string(value)
  defp scalar_id(value), do: text(value)

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(_value), do: nil

  defp present?(value), do: is_binary(value) and value != ""

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
