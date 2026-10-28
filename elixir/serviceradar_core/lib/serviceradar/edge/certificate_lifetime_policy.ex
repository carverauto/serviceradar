defmodule ServiceRadar.Edge.CertificateLifetimePolicy do
  @moduledoc """
  Canonical leaf certificate lifetime policy for edge components and agents.

  Defines default (`90` days), minimum (`7` days), and maximum (`365` days)
  validity bounds along with the renewal lead window (`30` days, or `2/3` of
  certificate lifetime).
  """

  @default_validity_days 90
  @min_validity_days 7
  @max_validity_days 365
  @renewal_lead_days 30
  @seconds_per_day 86_400

  @spec default_validity_days() :: pos_integer()
  def default_validity_days, do: @default_validity_days

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
  Resolves and validates leaf certificate validity days from options.

  Reads `:validity_days` or `:cert_validity_days`, defaulting to `90` days.
  Rejects values outside `7..365` with `{:error, {:invalid_certificate_validity_days, value}}`
  unless `allow_short_test_lifetime: true` is passed (which permits `1..365` for
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
          @default_validity_days
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
end
