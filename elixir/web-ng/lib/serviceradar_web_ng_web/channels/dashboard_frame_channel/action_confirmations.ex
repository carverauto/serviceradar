defmodule ServiceRadarWebNGWeb.DashboardFrameChannel.ActionConfirmations do
  @moduledoc """
  Host-owned confirmation for dashboard-launched actions that require it.

  A dashboard package is untrusted code, so a confirmation dialog the package
  draws proves nothing. When a package invokes an action whose descriptor has
  `requires_confirmation`, the frame channel does not dispatch. It records a
  pending confirmation here and asks the dashboard's LiveView to show a
  host-rendered dialog. Only the LiveView's reply, sent process to process and
  never through the browser renderer, can release the invocation.

  Each pending confirmation is:

    * bound to the viewer, the action, the target scope, the exact target set
      and a hash of the parsed input values (`binding/5`); a reply whose binding
      differs is rejected, so a confirmation cannot be replayed for other
      targets or other input;
    * short-lived (`ttl_ms/0`);
    * single use: `consume/4` and `decline/3` remove the entry whatever the
      outcome, including a mismatch, so a second reply finds nothing.

  The pending map lives in the channel process's assigns. These functions are
  pure over that map; the channel owns timers and pushes.
  """

  @ttl_ms 120_000
  @max_pending 4
  @sensitive_input ~r/pass(word|phrase)?|secret|token|api[_-]?key|private[_-]?key|credential/i

  def ttl_ms, do: @ttl_ms
  def max_pending, do: @max_pending

  @doc """
  Digest of everything a confirmation authorizes. Targets are compared as a set
  (order-insensitive); input values are hashed with deterministic encoding.
  """
  def binding(user_id, action_id, target_scope, targets, input_values) do
    term = {
      "dashboard-action-confirmation-v1",
      to_string(user_id),
      to_string(action_id),
      to_string(target_scope),
      canonical_targets(targets),
      input_hash(input_values)
    }

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  def input_hash(input_values) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(input_values || %{}, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Records a pending confirmation. `attrs` carries `:user_id`, `:action`,
  `:target_scope`, `:targets`, `:input_values` and optionally `:route_slug`.
  """
  def issue(pending, attrs, now_ms) when is_map(pending) and is_map(attrs) and is_integer(now_ms) do
    if map_size(pending) >= @max_pending do
      {:error, :too_many_pending_confirmations}
    else
      action = Map.fetch!(attrs, :action)
      user_id = attrs |> Map.fetch!(:user_id) |> to_string()
      target_scope = Map.fetch!(attrs, :target_scope)
      targets = Map.fetch!(attrs, :targets)
      input_values = Map.get(attrs, :input_values) || %{}
      id = new_id()

      entry = %{
        id: id,
        user_id: user_id,
        action: action,
        action_id: action.id,
        descriptor_id: Map.get(action, :descriptor_id),
        target_scope: target_scope,
        targets: targets,
        input_values: input_values,
        route_slug: Map.get(attrs, :route_slug),
        binding: binding(user_id, action.id, target_scope, targets, input_values),
        expires_at_ms: now_ms + @ttl_ms
      }

      {:ok, entry, Map.put(pending, id, entry)}
    end
  end

  @doc """
  Consumes a confirmed entry. `reply` carries the `:user_id` of the operator
  who confirmed and the `:binding` of the request the dialog displayed.
  """
  def consume(pending, id, reply, now_ms) when is_map(pending) and is_integer(now_ms) do
    case Map.pop(pending, to_string(id)) do
      {nil, pending} ->
        {:error, :confirmation_not_found, pending}

      {entry, rest} ->
        cond do
          now_ms >= entry.expires_at_ms -> {:error, :confirmation_expired, rest}
          not same_user?(entry, reply) -> {:error, :confirmation_mismatch, rest}
          not same_binding?(entry, reply) -> {:error, :confirmation_mismatch, rest}
          true -> {:ok, entry, rest}
        end
    end
  end

  @doc """
  Removes an entry the operator declined. Only the viewer the confirmation was
  issued for can decline it.
  """
  def decline(pending, id, reply) when is_map(pending) do
    case Map.fetch(pending, to_string(id)) do
      {:ok, entry} ->
        if same_user?(entry, reply),
          do: {:ok, entry, Map.delete(pending, entry.id)},
          else: {:error, :confirmation_mismatch, pending}

      :error ->
        {:error, :confirmation_not_found, pending}
    end
  end

  @doc "Removes an entry whose TTL elapsed. Returns `:error` if it already left."
  def expire(pending, id) when is_map(pending) do
    case Map.pop(pending, to_string(id)) do
      {nil, pending} -> {:error, pending}
      {entry, rest} -> {:ok, entry, rest}
    end
  end

  @doc """
  The request the LiveView renders. It carries only what the dialog shows plus
  the binding it must echo back; it never reaches the dashboard renderer.
  """
  def host_request(entry, channel_pid, now_ms) when is_pid(channel_pid) do
    action = entry.action

    %{
      id: entry.id,
      channel_pid: channel_pid,
      user_id: entry.user_id,
      binding: entry.binding,
      action_id: entry.action_id,
      label: Map.get(action, :label) || entry.action_id,
      description: Map.get(action, :description),
      provider_name: Map.get(action, :provider_name),
      safety_classification: Map.get(action, :safety_classification),
      target_scope: entry.target_scope,
      targets: Enum.map(entry.targets, &display_target/1),
      inputs: display_inputs(entry.input_values),
      route_slug: entry.route_slug,
      expires_at: DateTime.add(DateTime.utc_now(), max(entry.expires_at_ms - now_ms, 0), :millisecond)
    }
  end

  defp display_target(target) do
    %{
      device_uid: Map.get(target, :device_uid),
      interface_uid: Map.get(target, :interface_uid)
    }
  end

  defp display_inputs(input_values) when is_map(input_values) do
    input_values
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} ->
      key = to_string(key)
      {key, if(Regex.match?(@sensitive_input, key), do: :redacted, else: value)}
    end)
  end

  defp display_inputs(_input_values), do: []

  defp canonical_targets(targets) do
    targets
    |> List.wrap()
    |> Enum.map(fn target ->
      {to_string(Map.get(target, :kind) || ""), to_string(Map.get(target, :device_uid) || ""),
       to_string(Map.get(target, :interface_uid) || "")}
    end)
    |> Enum.sort()
  end

  defp same_user?(entry, reply), do: to_string(fetch(reply, :user_id)) == entry.user_id

  defp same_binding?(entry, reply) do
    case fetch(reply, :binding) do
      binding when is_binary(binding) -> Plug.Crypto.secure_compare(binding, entry.binding)
      _other -> false
    end
  end

  defp fetch(reply, key) when is_map(reply), do: Map.get(reply, key)
  defp fetch(_reply, _key), do: nil

  defp new_id, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
