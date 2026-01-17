defmodule ServiceRadar.Oban.Router do
  @moduledoc """
  Routes Oban inserts to the Oban instance.

  In a tenant-instance architecture, each instance has a single Oban instance.
  All jobs use the default Oban instance - no tenant routing needed.
  """

  def insert(changeset, opts \\ []) do
    Oban.insert(changeset, opts)
  end

  def insert!(changeset, opts \\ []) do
    Oban.insert!(changeset, opts)
  end

  def insert_all(changesets, opts \\ []) do
    Oban.insert_all(changesets, opts)
  end
end
