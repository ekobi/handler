defmodule Handler.Pool.State do
  @moduledoc false
  alias __MODULE__
  alias Handler.Pool
  alias Handler.Pool.{InsufficientMemory, NoWorkersAvailable}
  import Handler.Opts

  defstruct running_workers: 0,
            bytes_committed: 0,
            workers: %{},
            pool: nil

  @type t :: %State{
          running_workers: non_neg_integer(),
          bytes_committed: non_neg_integer(),
          workers: %{
            reference() => worker()
          },
          pool: %Handler.Pool{}
        }
  @type worker :: local_worker() | delegated_worker()
  @type local_worker :: %{
          bytes_committed: non_neg_integer(),
          from_pid: pid(),
          task_name: String.t() | nil,
          task_pid: pid()
        }
  @type delegated_worker :: %{
          bytes_committed: non_neg_integer(),
          from_pid: pid(),
          task_name: String.t() | nil,
          delegated_to: Pool.pool()
        }

  @type exception :: %InsufficientMemory{} | %NoWorkersAvailable{}

  @spec cleanup_commitments(t(), reference()) :: t()
  def cleanup_commitments(state, ref) do
    %State{workers: workers} = state

    case Map.get(workers, ref) do
      %{bytes_committed: bytes_committed} ->
        workers = Map.delete(workers, ref)

        %{
          state
          | workers: workers,
            running_workers: state.running_workers - 1,
            bytes_committed: state.bytes_committed - bytes_committed
        }

      nil ->
        raise "Received an un-tracked reference"
    end
  end

  @doc """
  Try to start a job on a worker from the pool. If there is not enough
  memory or all the workers are busy, return `{:reject, t:exception()}`.
  """
  @spec start_worker(t(), fun, Pool.opts(), pid()) ::
          {:ok, t(), reference()} | {:reject, exception()}
  def start_worker(state, fun, opts, from_pid) do
    bytes_requested = max_heap_bytes(opts)

    with :ok <- check_committed_resources(state, bytes_requested),
         {:ok, ref, worker} <- kickoff_new_task(state, fun, opts, from_pid) do
      new_state = commit_resources(state, ref, worker)
      {:ok, new_state, ref}
    end
  end

  @spec kill_worker(t(), String.t(), term()) :: {:ok, t(), non_neg_integer()}
  def kill_worker(state, task_name, exception) do
    Enum.reduce(state.workers, {:ok, state, 0}, fn
      {ref, %{task_pid: task_pid, task_name: ^task_name}}, {:ok, state, number_killed} ->
        state = shutdown_and_cleanup(state, ref, task_pid, exception)
        {:ok, state, number_killed + 1}

      {ref, %{delegated_to: pool, task_name: ^task_name}}, {:ok, state, number_killed} ->
        case Pool.kill_by_ref(pool, ref, exception) do
          :ok ->
            {:ok, state, number_killed + 1}

          :no_such_worker ->
            {:ok, state, number_killed}
        end

      {_ref, _worker}, {:ok, state, number_killed} ->
        {:ok, state, number_killed}
    end)
  end

  @spec kill_worker_by_ref(t(), reference(), term()) :: {:ok, t(), :ok | :no_such_worker}
  def kill_worker_by_ref(%State{workers: workers} = state, ref, exception) do
    case Map.get(workers, ref) do
      %{delegated_to: pool} ->
        result = Pool.kill_by_ref(pool, ref, exception)
        {:ok, state, result}

      %{task_pid: task_pid} ->
        state = shutdown_and_cleanup(state, ref, task_pid, exception)
        {:ok, state, :ok}

      nil ->
        {:ok, state, :no_such_worker}
    end
  end

  @spec flush_workers(t(), term()) :: {:ok, t(), non_neg_integer()}
  def flush_workers(state, exception) do
    Enum.reduce(state.workers, {:ok, state, 0}, fn
      {ref, _worker}, {:ok, state, number_killed} ->
        case kill_worker_by_ref(state, ref, exception) do
          {:ok, state, :ok} ->
            {:ok, state, number_killed + 1}

          {:ok, state, :no_such_worker} ->
            {:ok, state, number_killed}
        end
    end)
  end

  @spec send_response(t(), reference(), term) :: t()
  def send_response(state, ref, result) do
    %State{workers: workers} = state

    case Map.get(workers, ref) do
      %{from_pid: from_pid} ->
        send(from_pid, {ref, result})
        state

      nil ->
        raise "Received an un-tracked reference"
    end
  end

  defp kickoff_new_task(
         %State{pool: %Pool{delegate_to: pool}},
         fun,
         opts,
         from_pid
       )
       when not is_nil(pool) do
    with {:ok, ref} <- Pool.async(pool, fun, opts) do
      worker = %{
        bytes_committed: max_heap_bytes(opts),
        delegated_to: pool,
        from_pid: from_pid,
        task_name: task_name(opts)
      }

      {:ok, ref, worker}
    end
  end

  defp kickoff_new_task(
         %State{pool: %Pool{delegate_fun: {mod, fun_name, config}}},
         fun,
         opts,
         from_pid
       ) do
    param = Keyword.get(opts, :delegate_param)
    pools = apply(mod, fun_name, [config, param])
    acc = {:reject, NoWorkersAvailable.exception(message: "No Pools Available")}

    Enum.reduce_while(pools, acc, fn pool, _acc ->
      case Pool.async(pool, fun, opts) do
        {:ok, ref} ->
          worker = %{
            bytes_committed: max_heap_bytes(opts),
            delegated_to: pool,
            from_pid: from_pid,
            task_name: task_name(opts)
          }

          {:halt, {:ok, ref, worker}}

        {:reject, exception} ->
          {:cont, {:reject, exception}}
      end
    end)
  end

  defp kickoff_new_task(_state, fun, opts, from_pid) do
    %Task{ref: ref, pid: pid} =
      Task.async(fn ->
        task_opts = Keyword.drop(opts, [:delegate_param, :task_name])
        Handler.run(fun, task_opts)
      end)

    worker = %{
      bytes_committed: max_heap_bytes(opts),
      from_pid: from_pid,
      task_pid: pid,
      task_name: task_name(opts)
    }

    {:ok, ref, worker}
  end

  defp commit_resources(state, ref, worker) do
    workers = Map.put(state.workers, ref, worker)

    %{
      state
      | workers: workers,
        running_workers: state.running_workers + 1,
        bytes_committed: state.bytes_committed + worker.bytes_committed
    }
  end

  defp check_committed_resources(state, bytes_requested) do
    cond do
      state.running_workers >= state.pool.max_workers ->
        {:reject, NoWorkersAvailable.exception(message: "No workers available")}

      state.bytes_committed + bytes_requested > state.pool.max_memory_bytes ->
        {:reject, InsufficientMemory.exception(message: "Not enough memory available")}

      true ->
        :ok
    end
  end

  defp shutdown_and_cleanup(state, ref, task_pid, exception) do
    task = %Task{ref: ref, pid: task_pid, owner: self()}

    result =
      case Task.shutdown(task, :brutal_kill) do
        {:ok, task_result} ->
          task_result

        _ ->
          {:error, exception}
      end

    state
    |> send_response(ref, result)
    |> cleanup_commitments(ref)
  end
end
