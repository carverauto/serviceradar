defmodule ServiceRadar.NATS.StaticIdentityGrants do
  @moduledoc """
  The broker's built-in client identities and their static permissions, as the
  certificate authorization callout grants them.

  The Helm chart defines every built-in identity once
  (`templates/_nats_static_users.tpl`) and renders that list twice: into the
  broker's static `verify_and_map` users, and into the
  `serviceradar-nats-static-users` ConfigMap that core reads from
  `SERVICERADAR_NATS_STATIC_USERS_FILE`. Each entry names a certificate subject
  and its `publish` and `subscribe` blocks with static NATS semantics.

  With the callout enabled the broker delegates every one of those identities to
  core. Admission is unchanged: the presented fingerprint must belong to an
  adopted, unrevoked component with a stored grant. Only the permissions differ.
  An infrastructure component whose certificate subject names a built-in identity
  is granted that identity's static block, projected by
  `ServiceRadar.Edge.StaticNatsPermissionProjection` exactly as adoption projects
  it. The grant therefore matches what the same certificate gets without the
  callout, and a subject a release adds to the chart reaches the callout grant
  without re-adopting the component. Host-enrolled components (agents, leaves,
  collectors) and any subject not in the list keep their stored grant.

  Subjects are compared as a set of attribute type and value pairs, as the
  broker's distinguished-name match does. No configured file, or a missing file,
  is an empty list. A file that does not parse is an error, and the caller keeps
  its previous list.
  """

  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.StaticNatsPermissionProjection

  @type subject_key :: [{String.t(), String.t()}]
  @type grants :: %{optional(subject_key()) => map()}

  @attribute_names %{
    {2, 5, 4, 3} => "CN",
    {2, 5, 4, 6} => "C",
    {2, 5, 4, 7} => "L",
    {2, 5, 4, 8} => "ST",
    {2, 5, 4, 10} => "O",
    {2, 5, 4, 11} => "OU"
  }

  @doc "Reads the configured static users file."
  @spec load(String.t() | nil) :: {:ok, grants()} | {:error, :invalid_static_users}
  def load(path \\ Application.get_env(:serviceradar, :nats_static_users_file))

  def load(nil), do: {:ok, %{}}
  def load(""), do: {:ok, %{}}

  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, :enoent} -> {:ok, %{}}
      {:error, _reason} -> {:error, :invalid_static_users}
    end
  end

  @doc "Parses the YAML list the chart renders."
  @spec parse(String.t()) :: {:ok, grants()} | {:error, :invalid_static_users}
  def parse(contents) when is_binary(contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, users} when is_list(users) ->
        Enum.reduce_while(users, {:ok, %{}}, fn user, {:ok, acc} ->
          case user_grant(user) do
            {:ok, key, grant} -> {:cont, {:ok, Map.put(acc, key, grant)}}
            :error -> {:halt, {:error, :invalid_static_users}}
          end
        end)

      _ ->
        {:error, :invalid_static_users}
    end
  end

  @doc """
  The static grant for an infrastructure component's presented certificate, or
  `nil` when the component type is not infrastructure or its subject is not a
  built-in identity.
  """
  @spec grant(grants(), String.t() | nil, binary()) :: map() | nil
  def grant(grants, component_type, certificate_der)
      when map_size(grants) > 0 and is_binary(certificate_der) do
    if is_binary(component_type) and ManagedComponent.infrastructure_type?(component_type) do
      case certificate_subject_key(certificate_der) do
        {:ok, key} -> Map.get(grants, key)
        :error -> nil
      end
    end
  end

  def grant(_grants, _component_type, _certificate_der), do: nil

  defp user_grant(%{"user" => subject, "publish" => publish, "subscribe" => subscribe})
       when is_binary(subject) do
    with {:ok, key} <- subject_key(subject),
         {:ok, projected} <-
           StaticNatsPermissionProjection.project(%{
             "publish" => publish,
             "subscribe" => subscribe
           }) do
      {:ok, key,
       %{
         publish: projected["publish"],
         subscribe: projected["subscribe"],
         publish_deny: projected["publish_deny"],
         subscribe_deny: projected["subscribe_deny"]
       }}
    else
      _ -> :error
    end
  end

  defp user_grant(_user), do: :error

  defp subject_key(subject) do
    pairs =
      subject
      |> String.split(",")
      |> Enum.map(fn part ->
        case String.split(part, "=", parts: 2) do
          [type, value] when value != "" -> {String.upcase(String.trim(type)), value}
          _ -> :error
        end
      end)

    if pairs != [] and :error not in pairs, do: {:ok, Enum.sort(pairs)}, else: :error
  end

  defp certificate_subject_key(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    {:rdnSequence, rdns} = elem(tbs, 6)

    pairs =
      for rdn <- rdns, {:AttributeTypeAndValue, oid, value} <- rdn do
        {Map.get(@attribute_names, oid, "OID." <> oid_string(oid)), attribute_value(value)}
      end

    {:ok, Enum.sort(pairs)}
  rescue
    _ -> :error
  end

  defp attribute_value({_string_type, value}), do: to_string(value)
  defp attribute_value(value), do: to_string(value)

  defp oid_string(oid), do: oid |> Tuple.to_list() |> Enum.join(".")
end
