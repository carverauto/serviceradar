defmodule ServiceRadarAgentGateway.TlsDiagnosticLogger do
  @moduledoc """
  Structured diagnostics for edge gateway mTLS handshake and peer certificate failures.

  Provides an `:ssl` `verify_fun` callback and classification helpers so that
  expired, unknown-CA, and bad-cert peer errors log the peer certificate subject
  (`component_id` and `partition_id`), issuer, serial number, `not_after`, and
  normalized failure reason (`certificate_expired`, `unknown_ca`, `bad_cert`, etc.)
  while remaining strictly fail-closed.
  """

  alias ServiceRadarAgentGateway.ComponentIdentityResolver

  require Logger

  @doc """
  Fail-closed `:ssl` `verify_fun` callback that logs peer certificate metadata
  whenever OTP `:ssl` encounters a `:bad_cert` path validation error.
  """
  @spec ssl_verify(tuple() | binary(), term(), map()) ::
          {:valid, map()} | {:unknown, map()} | {:fail, term()}
  def ssl_verify(cert, {:bad_cert, reason}, _user_state) do
    _ = log_handshake_failure({:bad_cert, reason}, cert)
    {:fail, reason}
  end

  def ssl_verify(_cert, {:extension, _extension}, user_state) do
    {:unknown, user_state}
  end

  def ssl_verify(_cert, :valid, user_state) do
    {:valid, user_state}
  end

  def ssl_verify(_cert, :valid_peer, user_state) do
    {:valid, user_state}
  end

  @doc """
  Classifies a TLS handshake or peer certificate validation failure and extracts
  diagnostic metadata from the peer certificate when available.
  """
  @spec classify_handshake_failure(term(), binary() | tuple() | nil, keyword()) :: map()
  def classify_handshake_failure(reason_or_report, peer_cert \\ nil, opts \\ []) do
    meta = ComponentIdentityResolver.extract_cert_metadata(peer_cert)
    classified_reason = normalize_failure_reason(reason_or_report, meta, opts)

    %{
      reason: classified_reason,
      raw_reason: reason_or_report,
      subject: Map.get(meta, :subject),
      issuer: Map.get(meta, :issuer),
      component_id: Map.get(meta, :component_id),
      partition_id: Map.get(meta, :partition_id),
      serial: Map.get(meta, :serial),
      serial_number: Map.get(meta, :serial_number),
      fingerprint_sha256: Map.get(meta, :fingerprint_sha256),
      not_before: Map.get(meta, :not_before),
      not_after: Map.get(meta, :not_after),
      peer_ip: Keyword.get(opts, :peer_ip)
    }
  end

  @doc """
  Logs a structured warning for a TLS handshake or peer certificate failure and
  returns the classified diagnostic map.
  """
  @spec log_handshake_failure(term(), binary() | tuple() | nil, keyword()) :: map()
  def log_handshake_failure(reason_or_report, peer_cert \\ nil, opts \\ []) do
    diag = classify_handshake_failure(reason_or_report, peer_cert, opts)
    not_after_iso = format_datetime(diag.not_after)

    Logger.warning(
      "Edge mTLS peer certificate rejected: " <>
        "reason=#{diag.reason} " <>
        "subject=#{diag.subject || "unknown"} " <>
        "component_id=#{diag.component_id || "unknown"} " <>
        "partition_id=#{diag.partition_id || "unknown"} " <>
        "issuer=#{diag.issuer || "unknown"} " <>
        "serial=#{diag.serial || "unknown"} " <>
        "not_after=#{not_after_iso}"
    )

    diag
  end

  defp normalize_failure_reason(reason, meta, opts) do
    case classify_known_reason(reason) do
      :unknown ->
        infer_from_cert_metadata(meta, opts)

      known ->
        known
    end
  end

  defp classify_known_reason(:cert_expired), do: :certificate_expired
  defp classify_known_reason(:certificate_expired), do: :certificate_expired
  defp classify_known_reason(:certificate_not_yet_valid), do: :certificate_not_yet_valid
  defp classify_known_reason(:unknown_ca), do: :unknown_ca
  defp classify_known_reason(:revoked_certificate), do: :revoked_certificate
  defp classify_known_reason(:cert_revoked), do: :revoked_certificate
  defp classify_known_reason(:no_certificate), do: :no_certificate
  defp classify_known_reason(:selfsigned_peer), do: :bad_cert
  defp classify_known_reason(:invalid_issuer), do: :bad_cert
  defp classify_known_reason(:invalid_signature), do: :bad_cert
  defp classify_known_reason(:bad_cert), do: :bad_cert
  defp classify_known_reason(:invalid_certificate), do: :bad_cert
  defp classify_known_reason(:invalid_cn_format), do: :bad_cert
  defp classify_known_reason(:no_cn), do: :bad_cert

  defp classify_known_reason({:bad_cert, inner}), do: classify_bad_cert_reason(inner)
  defp classify_known_reason({:tls_alert, {alert, _}}), do: classify_known_reason(alert)
  defp classify_known_reason({:ssl_error, inner}), do: classify_known_reason(inner)

  defp classify_known_reason(text) when is_binary(text) do
    down = String.downcase(text)

    cond do
      String.contains?(down, "expired") -> :certificate_expired
      String.contains?(down, "unknown ca") or String.contains?(down, "unknown_ca") -> :unknown_ca
      String.contains?(down, "revoked") -> :revoked_certificate
      String.contains?(down, "bad certificate") or String.contains?(down, "bad_cert") -> :bad_cert
      true -> :unknown
    end
  end

  defp classify_known_reason(chars) when is_list(chars) do
    chars |> List.to_string() |> classify_known_reason()
  rescue
    _ -> :unknown
  end

  defp classify_known_reason(_), do: :unknown

  defp classify_bad_cert_reason(:cert_expired), do: :certificate_expired
  defp classify_bad_cert_reason(:unknown_ca), do: :unknown_ca
  defp classify_bad_cert_reason(:cert_revoked), do: :revoked_certificate
  defp classify_bad_cert_reason(_other), do: :bad_cert

  defp infer_from_cert_metadata(%{not_after: %DateTime{} = not_after}, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if DateTime.before?(now, not_after) do
      :bad_cert
    else
      :certificate_expired
    end
  end

  defp infer_from_cert_metadata(_meta, _opts), do: :bad_cert

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(_), do: "unknown"
end
