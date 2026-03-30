defmodule ServiceRadar.Identity.AccessCredentialChanges do
  @moduledoc false

  @type init_secret_opt ::
          {:argument, atom()}
          | {:hash_attribute, atom()}
          | {:prefix_attribute, atom()}
          | {:hash_fun, (String.t() -> String.t())}
          | {:timestamp_attribute, atom() | nil}

  @spec init_secret(Ash.Changeset.t(), [init_secret_opt()]) :: Ash.Changeset.t()
  def init_secret(changeset, opts) do
    argument = Keyword.fetch!(opts, :argument)
    hash_attribute = Keyword.fetch!(opts, :hash_attribute)
    prefix_attribute = Keyword.fetch!(opts, :prefix_attribute)
    hash_fun = Keyword.fetch!(opts, :hash_fun)
    timestamp_attribute = Keyword.get(opts, :timestamp_attribute)
    raw_secret = Ash.Changeset.get_argument(changeset, argument)
    timestamp = DateTime.utc_now()

    changeset
    |> Ash.Changeset.change_attribute(hash_attribute, hash_fun.(raw_secret))
    |> Ash.Changeset.change_attribute(prefix_attribute, String.slice(raw_secret, 0, 8))
    |> maybe_change_timestamp(timestamp_attribute, timestamp)
    |> Ash.Changeset.change_attribute(:enabled, true)
    |> Ash.Changeset.change_attribute(:use_count, 0)
  end

  @spec revoke(Ash.Changeset.t(), keyword()) :: Ash.Changeset.t()
  def revoke(changeset, opts \\ []) do
    changeset
    |> Ash.Changeset.change_attribute(:revoked_at, DateTime.utc_now())
    |> maybe_change_revoked_by(Keyword.get(opts, :revoked_by))
    |> Ash.Changeset.change_attribute(:enabled, false)
  end

  defp maybe_change_revoked_by(changeset, nil), do: changeset

  defp maybe_change_revoked_by(changeset, revoked_by) do
    Ash.Changeset.change_attribute(changeset, :revoked_by, revoked_by)
  end

  defp maybe_change_timestamp(changeset, nil, _timestamp), do: changeset

  defp maybe_change_timestamp(changeset, attribute, timestamp) do
    Ash.Changeset.change_attribute(changeset, attribute, timestamp)
  end
end
