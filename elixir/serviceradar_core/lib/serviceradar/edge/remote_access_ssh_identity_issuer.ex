defmodule ServiceRadar.Edge.RemoteAccessSSHIdentityIssuer do
  @moduledoc """
  Issues SSH certificates from a trusted SSO identity context.

  Browser request parameters may identify the session, target, public key, and
  requested Unix login account. Certificate principals and IdP claims must come
  from server-side target policy and the authenticated login context. This
  boundary strips caller-supplied claims before invoking certificate policy.
  """

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Events.AuditWriter

  @trusted_auth_methods [:oidc, :saml]
  @identity_claim_keys [:claims, "claims", :idp_claims, "idp_claims"]

  @spec issue(map() | struct(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(actor, request_attrs, opts \\ [])

  def issue(actor, request_attrs, opts) when is_map(request_attrs) do
    result =
      with {:ok, claims} <- authoritative_claims(actor, opts),
           :ok <- require_sso_identity(claims, opts) do
        attrs =
          request_attrs
          |> Map.drop(@identity_claim_keys)
          |> Map.put(:claims, claims)

        RemoteAccessSSHCertificates.issue(actor, attrs, opts)
      end

    write_audit(result, actor, request_attrs, opts)
    result
  end

  def issue(_actor, _request_attrs, _opts), do: {:error, :invalid_request}

  defp write_audit({:ok, envelope}, actor, _request_attrs, opts) do
    details =
      envelope
      |> Map.get(:audit, %{})
      |> Map.merge(%{
        result: "success",
        credential_custody_mode: "short_lived_certificate",
        credential_mode: Map.get(envelope, :credential_mode),
        session_id: Map.get(envelope, :session_id),
        agent_id: Map.get(envelope, :agent_id),
        gateway_id: Map.get(envelope, :gateway_id),
        protocol: Map.get(envelope, :protocol),
        target: Map.get(envelope, :target)
      })
      |> sanitize_details()

    write_audit_event(actor, details, opts)
  end

  defp write_audit({:error, reason}, actor, request_attrs, opts) do
    details =
      sanitize_details(%{
        result: "denied",
        credential_custody_mode: "short_lived_certificate",
        credential_mode: "ssh_certificate",
        failure_reason: format_reason(reason),
        session_id: request_value(request_attrs, "session_id"),
        agent_id: request_value(request_attrs, "agent_id"),
        gateway_id: request_value(request_attrs, "gateway_id"),
        protocol: request_value(request_attrs, "protocol") || "ssh",
        target: request_value(request_attrs, "target"),
        ssh_username: request_value(request_attrs, "username")
      })

    write_audit_event(actor, details, opts)
  end

  defp write_audit_event(actor, details, opts) do
    session_id = Map.get(details, :session_id) || "unknown-session"
    target_ref = target_ref(Map.get(details, :target))

    audit_opts = [
      action: :remote_access_ssh_certificate_issue,
      resource_type: "remote_access_ssh_certificate",
      resource_id: session_id,
      resource_name: target_ref,
      actor: actor,
      details: details,
      severity: audit_severity(details),
      message: "SSH remote-access certificate #{Map.fetch!(details, :result)}"
    ]

    case Keyword.get(opts, :audit_writer, AuditWriter) do
      {writer, writer_opts} -> writer.write_async(Keyword.merge(audit_opts, writer_opts))
      writer -> writer.write_async(audit_opts)
    end
  end

  defp sanitize_details(details) do
    details
    |> normalize_detail_values()
    |> CredentialRedactor.redact()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_detail_values(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_detail_values(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_detail_values(%Date{} = value), do: Date.to_iso8601(value)

  defp normalize_detail_values(%_struct{} = value), do: inspect(value)

  defp normalize_detail_values(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, normalize_detail_values(nested)} end)
  end

  defp normalize_detail_values(value) when is_list(value),
    do: Enum.map(value, &normalize_detail_values/1)

  defp normalize_detail_values(value), do: value

  defp audit_severity(%{result: "success"}), do: :medium
  defp audit_severity(_details), do: :high

  defp target_ref(target) when is_map(target) do
    request_value(target, "id") ||
      request_value(target, "device_uid") ||
      request_value(target, "uid") ||
      request_value(target, "host")
  end

  defp target_ref(_target), do: nil

  defp request_value(container, key) when is_map(container) do
    Map.get(container, key) || Map.get(container, safe_existing_atom(key))
  end

  defp request_value(_container, _key), do: nil

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)

  defp format_reason(reason) do
    reason
    |> inspect()
    |> String.slice(0, 500)
  end

  defp require_sso_identity(claims, opts) do
    if Keyword.get(opts, :require_sso?, true) do
      trusted_auth_methods = Keyword.get(opts, :trusted_auth_methods, @trusted_auth_methods)

      if session_auth_method(claims) in Enum.map(trusted_auth_methods, &normalize_atom/1) do
        :ok
      else
        {:error, :sso_identity_required}
      end
    else
      :ok
    end
  end

  defp authoritative_claims(actor, opts) do
    claims = Keyword.get(opts, :idp_claims) || Keyword.get(opts, :claims) || %{}

    if is_map(claims) do
      {:ok, Map.merge(stringify_keys(claims), actor_claims(actor))}
    else
      {:error, :invalid_identity_claims}
    end
  end

  defp actor_claims(actor) do
    %{
      "sub" => actor_field(actor, :external_id) || actor_field(actor, :id),
      "email" => actor_field(actor, :email),
      "name" => actor_field(actor, :display_name),
      "service_radar_user_id" => actor_field(actor, :id),
      "service_radar_role" => actor_field(actor, :role)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp session_auth_method(claims) do
    claims
    |> Map.get("service_radar_auth_method")
    |> normalize_atom()
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp normalize_atom(_value), do: nil

  defp actor_field(actor, key) when is_map(actor) and is_atom(key) do
    actor
    |> Map.get(key)
    |> string_value()
    |> Kernel.||(string_value(Map.get(actor, Atom.to_string(key))))
  end

  defp actor_field(_actor, _key), do: nil

  defp string_value(nil), do: nil

  defp string_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value), do: to_string(value)
end
