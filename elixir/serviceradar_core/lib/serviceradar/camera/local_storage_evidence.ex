defmodule ServiceRadar.Camera.LocalStorageEvidence do
  @moduledoc """
  Evaluates retained local-storage evidence against an explicit trusted policy.

  This is a prerequisite for activation, not activation itself. The caller owns
  evidence authentication, the current activation/withdrawal decision and trusted
  time. A current result grants no capture, registration or playback authority.
  Health is a bounded qualification decision, not raw provider telemetry.
  """

  alias ServiceRadar.Camera.LocalStorageQualificationDocument

  @policy_fields [:revision, :profile_sha256, :max_report_validity_ms, :max_health_age_ms]
  @health_fields ~w(binding_id report_sha256 evidence_sha256 observed_at_ms status)
  @max_integer 9_223_372_036_854_775_807

  def evaluate(retained, policy, health, now_ms) do
    with :ok <- valid_policy(policy),
         :ok <- trusted_time(now_ms),
         {:ok, report} <- retained_report(retained),
         :ok <- matching_policy(report, policy),
         :ok <- passing_outcomes(report),
         :ok <- report_freshness(report, policy, now_ms),
         :ok <- health_evidence(health, retained, report),
         :ok <- health_freshness(health, policy, now_ms) do
      %{
        evidence_status: :current,
        valid_until_ms:
          min(report["expires_at_ms"], health["observed_at_ms"] + policy.max_health_age_ms)
      }
    else
      {:error, reason} -> %{evidence_status: :ineligible, reason: reason}
    end
  end

  defp valid_policy(policy) when is_map(policy) and map_size(policy) == 4 do
    if Enum.sort(Map.keys(policy)) == Enum.sort(@policy_fields) and
         token?(policy.revision) and digest?(policy.profile_sha256) and
         positive_integer?(policy.max_report_validity_ms) and
         positive_integer?(policy.max_health_age_ms),
       do: :ok,
       else: {:error, :invalid_policy}
  end

  defp valid_policy(_), do: {:error, :invalid_policy}

  defp trusted_time(now_ms) do
    if positive_integer?(now_ms), do: :ok, else: {:error, :invalid_trusted_time}
  end

  defp retained_report(%{report: document, report_sha256: digest}) do
    case LocalStorageQualificationDocument.attributes(document) do
      {:ok, %{report_sha256: ^digest}} -> {:ok, document}
      _ -> {:error, :invalid_report}
    end
  end

  defp retained_report(_), do: {:error, :invalid_report}

  defp matching_policy(report, policy) do
    if report["policy_revision"] == policy.revision and
         report["profile_sha256"] == policy.profile_sha256,
       do: :ok,
       else: {:error, :policy_mismatch}
  end

  defp passing_outcomes(report) do
    if Enum.all?(report["checks"], fn {_check, status} -> status == "passed" end),
      do: :ok,
      else: {:error, :required_outcome_not_passed}
  end

  defp report_freshness(report, policy, now_ms) do
    cond do
      report["expires_at_ms"] - report["issued_at_ms"] > policy.max_report_validity_ms ->
        {:error, :report_validity_exceeded}

      report["issued_at_ms"] > now_ms ->
        {:error, :report_from_future}

      now_ms >= report["expires_at_ms"] ->
        {:error, :report_expired}

      true ->
        :ok
    end
  end

  defp health_evidence(health, retained, report) when is_map(health) and map_size(health) == 5 do
    cond do
      Enum.sort(Map.keys(health)) != Enum.sort(@health_fields) or
        not digest?(health["evidence_sha256"]) or not positive_integer?(health["observed_at_ms"]) ->
        {:error, :invalid_health}

      health["binding_id"] != report["binding_id"] or
          health["report_sha256"] != retained.report_sha256 ->
        {:error, :health_mismatch}

      health["status"] == "degraded" ->
        {:error, :health_degraded}

      health["status"] == "unknown" ->
        {:error, :health_unknown}

      health["status"] != "healthy" ->
        {:error, :invalid_health}

      true ->
        :ok
    end
  end

  defp health_evidence(nil, _retained, _report), do: {:error, :health_unknown}
  defp health_evidence(_health, _retained, _report), do: {:error, :invalid_health}

  defp health_freshness(health, policy, now_ms) do
    cond do
      health["observed_at_ms"] > now_ms -> {:error, :health_from_future}
      now_ms - health["observed_at_ms"] >= policy.max_health_age_ms -> {:error, :health_expired}
      true -> :ok
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value in 1..@max_integer

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_), do: false

  defp token?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value)

  defp token?(_), do: false
end
