defmodule ServiceRadarWebNG.FieldSurveyStreamLimiter do
  @moduledoc """
  In-memory concurrency guard for FieldSurvey ingest WebSocket streams.
  """

  use GenServer

  @max_streams_per_user 6
  @max_streams_per_session 3

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec acquire(String.t(), String.t()) ::
          {:ok, reference()} | {:error, :too_many_user_streams | :too_many_session_streams}
  def acquire(user_id, session_id) do
    GenServer.call(__MODULE__, {:acquire, to_string(user_id), session_id})
  end

  @spec release(reference() | nil) :: :ok
  def release(nil), do: :ok

  def release(token) when is_reference(token) do
    GenServer.cast(__MODULE__, {:release, token})
  end

  @impl true
  def init(_opts) do
    {:ok, %{tokens: %{}, user_counts: %{}, session_counts: %{}}}
  end

  @impl true
  def handle_call({:acquire, user_id, session_id}, _from, state) do
    session_key = {user_id, session_id}
    user_count = Map.get(state.user_counts, user_id, 0)
    session_count = Map.get(state.session_counts, session_key, 0)

    cond do
      user_count >= @max_streams_per_user ->
        {:reply, {:error, :too_many_user_streams}, state}

      session_count >= @max_streams_per_session ->
        {:reply, {:error, :too_many_session_streams}, state}

      true ->
        token = make_ref()

        {:reply, {:ok, token},
         %{
           state
           | tokens: Map.put(state.tokens, token, {user_id, session_key}),
             user_counts: Map.update(state.user_counts, user_id, 1, &(&1 + 1)),
             session_counts: Map.update(state.session_counts, session_key, 1, &(&1 + 1))
         }}
    end
  end

  @impl true
  def handle_cast({:release, token}, state) do
    {:noreply, release_token(state, token)}
  end

  defp release_token(%{tokens: tokens} = state, token) do
    case Map.pop(tokens, token) do
      {nil, _tokens} ->
        state

      {{user_id, session_key}, tokens} ->
        %{state | tokens: tokens}
        |> decrement(:user_counts, user_id)
        |> decrement(:session_counts, session_key)
    end
  end

  defp decrement(state, field, key) do
    update_in(state, [field], fn counts ->
      case Map.get(counts, key, 0) - 1 do
        count when count > 0 -> Map.put(counts, key, count)
        _ -> Map.delete(counts, key)
      end
    end)
  end
end
