defmodule ServiceRadar.Edge.StaticNatsPermissionProjection do
  @moduledoc """
  Projects one static NATS permission block into explicit infrastructure grants.

  NATS treats a missing or empty allow list as every subject, then applies
  deny. A stored managed grant treats an empty allow list as no subjects.
  Copying a legacy empty allow unchanged would deny a client that can
  publish or subscribe today.

  An empty or missing allow becomes `[">"]` and the deny list is kept.
  A non-empty allow is copied unchanged and is never widened. Both
  directions are required. This does not read a cluster, adopt a
  certificate, or enable broker authorization callout.
  """

  alias ServiceRadar.Edge.Validations.InfrastructureNatsPermissions

  @directions ["publish", "subscribe"]
  @entries ["allow", "deny"]

  @spec project(map()) :: {:ok, map()} | {:error, :invalid_permissions | :invalid_subject}
  def project(permissions) when is_map(permissions) do
    with {:ok, permissions} <- normalize(permissions, @directions, @directions),
         {:ok, publish} <- direction(permissions, "publish"),
         {:ok, subscribe} <- direction(permissions, "subscribe") do
      {:ok,
       %{
         "publish" => publish.allow,
         "subscribe" => subscribe.allow,
         "publish_deny" => publish.deny,
         "subscribe_deny" => subscribe.deny
       }}
    end
  end

  def project(_), do: {:error, :invalid_permissions}

  defp direction(permissions, name) do
    case Map.fetch!(permissions, name) do
      value when is_map(value) -> normalize_direction(value)
      _ -> {:error, :invalid_permissions}
    end
  end

  defp normalize_direction(value) do
    with {:ok, value} <- normalize(value, @entries, []) do
      allow = Map.get(value, "allow")
      deny = Map.get(value, "deny")

      with :ok <- subjects(allow), :ok <- subjects(deny) do
        {:ok, %{allow: explicit_allow(allow), deny: deny || []}}
      end
    end
  end

  defp explicit_allow(allow) when allow in [nil, []], do: [">"]
  defp explicit_allow(allow), do: allow

  defp normalize(map, allowed, required) do
    normalized = Map.new(map, fn {key, value} -> {to_string(key), value} end)

    cond do
      map_size(normalized) != map_size(map) ->
        {:error, :invalid_permissions}

      Enum.any?(Map.keys(normalized), &(&1 not in allowed)) ->
        {:error, :invalid_permissions}

      Enum.any?(required, &(not Map.has_key?(normalized, &1))) ->
        {:error, :invalid_permissions}

      true ->
        {:ok, normalized}
    end
  end

  defp subjects(nil), do: :ok
  defp subjects([]), do: :ok

  defp subjects(subjects) when is_list(subjects) do
    if Enum.all?(subjects, &InfrastructureNatsPermissions.valid_subject?/1),
      do: :ok,
      else: {:error, :invalid_subject}
  end

  defp subjects(_), do: {:error, :invalid_permissions}
end
