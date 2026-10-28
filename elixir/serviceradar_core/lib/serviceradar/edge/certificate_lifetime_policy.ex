defmodule ServiceRadar.Edge.CertificateLifetimePolicy do
  @moduledoc """
  Canonical leaf certificate lifetime policy for edge components and agents.

  Defines the default validity (`90` days unless the deployment overrides it),
  minimum (`7` days), and maximum (`365` days) bounds along with the renewal
  lead window (`30` days, or `2/3` of certificate lifetime).

  A deployment sets its default with the `AGENT_CERT_VALIDITY_DAYS` environment
  variable (Helm `certs.agentValidityDays`). Each release that issues or
  validates agent certificates (core, web-ng, agent-gateway) parses it at boot
  with `parse_default_validity_days!/1` into the `:serviceradar_core,
  :agent_cert_validity_days` application setting, so every issuance path
  resolves the same default.
  """

  @builtin_default_validity_days 90
  @min_validity_days 7
  @max_validity_days 365
  @renewal_lead_days 30
  @seconds_per_day 86_400

  @doc """
  The deployment's default leaf certificate validity in days.
  """
  @spec default_validity_days() :: pos_integer()
  def default_validity_days do
    Application.get_env(
      :serviceradar_core,
      :agent_cert_validity_days,
      @builtin_default_validity_days
    )
  end

  @spec min_validity_days() :: pos_integer()
  def min_validity_days, do: @min_validity_days

  @spec max_validity_days() :: pos_integer()
  def max_validity_days, do: @max_validity_days

  @spec renewal_lead_days() :: pos_integer()
  def renewal_lead_days, do: @renewal_lead_days

  @spec renewal_fraction() :: {pos_integer(), pos_integer()}
  def renewal_fraction, do: {2, 3}

  @spec seconds_per_day() :: pos_integer()
  def seconds_per_day, do: @seconds_per_day

  @doc """
  Parses the `AGENT_CERT_VALIDITY_DAYS` value read by `config/runtime.exs`.

  An unset or blank value selects the built-in `90`-day default. Anything other
  than an integer within `7..365` raises `ArgumentError`, so a misconfigured
  deployment fails at boot instead of at the first package issuance.
  """
  @spec parse_default_validity_days!(String.t() | nil) :: pos_integer()
  def parse_default_validity_days!(nil), do: @builtin_default_validity_days

  def parse_default_validity_days!(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> @builtin_default_validity_days
      trimmed -> parse_bounded_days!(trimmed, raw)
    end
  end

  defp parse_bounded_days!(trimmed, raw) do
    case Integer.parse(trimmed) do
      {days, ""} when days >= @min_validity_days and days <= @max_validity_days ->
        days

      _invalid ->
        raise ArgumentError,
              "AGENT_CERT_VALIDITY_DAYS must be an integer from #{@min_validity_days} " <>
                "to #{@max_validity_days} days, got: #{inspect(raw)}"
    end
  end

  @doc """
  Resolves and validates leaf certificate validity days from options.

  Reads `:validity_days` or `:cert_validity_days`, defaulting to
  `default_validity_days/0`. Rejects values outside `7..365` with
  `{:error, {:invalid_certificate_validity_days, value}}` unless
  `allow_short_test_lifetime: true` is passed (which permits `1..365` for
  explicit short-lifetime tests).
  """
  @spec resolve_validity_days(keyword()) ::
          {:ok, pos_integer()} | {:error, {:invalid_certificate_validity_days, term()}}
  def resolve_validity_days(opts \\ []) when is_list(opts) do
    raw_days =
      cond do
        Keyword.has_key?(opts, :validity_days) and not is_nil(Keyword.get(opts, :validity_days)) ->
          Keyword.get(opts, :validity_days)

        Keyword.has_key?(opts, :cert_validity_days) and
            not is_nil(Keyword.get(opts, :cert_validity_days)) ->
          Keyword.get(opts, :cert_validity_days)

        true ->
          default_validity_days()
      end

    min_days =
      if Keyword.get(opts, :allow_short_test_lifetime, false) == true do
        1
      else
        @min_validity_days
      end

    if is_integer(raw_days) and raw_days >= min_days and raw_days <= @max_validity_days do
      {:ok, raw_days}
    else
      {:error, {:invalid_certificate_validity_days, raw_days}}
    end
  end

  @doc """
  Resolves and validates leaf certificate validity in seconds.
  """
  @spec resolve_validity_seconds(keyword()) ::
          {:ok, pos_integer()} | {:error, {:invalid_certificate_validity_days, term()}}
  def resolve_validity_seconds(opts \\ []) when is_list(opts) do
    with {:ok, days} <- resolve_validity_days(opts) do
      {:ok, days * @seconds_per_day}
    end
  end

  @doc """
  Returns the `notAfter` instant of the first certificate in a PEM string.
  """
  @spec certificate_not_after(String.t()) :: {:ok, DateTime.t()} | :error
  def certificate_not_after(certificate_pem) when is_binary(certificate_pem) do
    with [{:Certificate, der, :not_encrypted} | _] <- :public_key.pem_decode(certificate_pem),
         {:Certificate, tbs, _algorithm, _signature} <- :public_key.der_decode(:Certificate, der),
         {:Validity, _not_before, not_after} <- elem(tbs, 5) do
      asn1_time_to_datetime(not_after)
    else
      _ -> :error
    end
  rescue
    # A PEM block whose body is not a DER certificate raises from the decoder.
    _ -> :error
  end

  def certificate_not_after(_certificate_pem), do: :error

  # RFC 5280: UTCTime is YYMMDDHHMMSSZ with years 50-99 meaning 19xx;
  # GeneralizedTime is YYYYMMDDHHMMSSZ.
  defp asn1_time_to_datetime({:utcTime, time}) do
    <<yy::binary-2, rest::binary>> = to_string(time)
    century = if String.to_integer(yy) >= 50, do: "19", else: "20"
    asn1_time_to_datetime({:generalTime, century <> yy <> rest})
  end

  defp asn1_time_to_datetime({:generalTime, time}) do
    <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">> =
      to_string(time)

    with {:ok, naive} <- NaiveDateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}") do
      DateTime.from_naive(naive, "Etc/UTC")
    end
  end
end
