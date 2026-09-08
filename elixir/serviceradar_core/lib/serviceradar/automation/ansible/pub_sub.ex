defmodule ServiceRadar.Automation.Ansible.PubSub do
  @moduledoc """
  Phoenix.PubSub topics + helpers for live updates to Ansible LiveView
  pages.

  Two topics:

    * `"ansible-runs:instance"` — fires when *any* run in the deployment
      is updated. The runs index page subscribes here so the table can
      show new state transitions without a refresh.
    * `"ansible-run:<id>"` — fires only for one run. The run detail
      page subscribes here to live-tail.

  Each broadcast carries a `{:ansible_run_updated, run}` tuple. The run
  is the freshest read available; consumers typically refetch related
  collections (targets, plays, tasks) on receipt rather than try to
  reconcile diffs from the message.
  """

  @pubsub ServiceRadar.PubSub

  def runs_topic, do: "ansible-runs:instance"
  def run_topic(run_id) when is_binary(run_id), do: "ansible-run:" <> run_id

  def subscribe_runs do
    Phoenix.PubSub.subscribe(@pubsub, runs_topic())
  end

  def subscribe_run(run_id) when is_binary(run_id) do
    Phoenix.PubSub.subscribe(@pubsub, run_topic(run_id))
  end

  @doc """
  Broadcast an "updated" notification for `run` to both topics. Called
  by `EventIngestor` after applying an event batch / state transition.
  Silently no-ops if no PubSub is configured (so the bare core app
  can run without web-ng).
  """
  def broadcast_run_updated(%{id: id} = run) when is_binary(id) do
    msg = {:ansible_run_updated, run}
    _ = safe_broadcast(runs_topic(), msg)
    _ = safe_broadcast(run_topic(id), msg)
    :ok
  end

  def broadcast_run_updated(_), do: :ok

  defp safe_broadcast(topic, msg) do
    Phoenix.PubSub.broadcast(@pubsub, topic, msg)
  rescue
    _ -> :ok
  end
end
