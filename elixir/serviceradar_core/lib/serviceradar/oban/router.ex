defmodule ServiceRadar.Oban.Router do
  @moduledoc """
  Routes Oban inserts to the Oban instance.

  In a single-deployment architecture, each instance has a single Oban instance.
  All jobs use the default Oban instance - no routing needed.
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
