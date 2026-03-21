defmodule Sam.Settings do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # Public API
  # Zero/one-arg forms without a table reference use the global DETS table (:sam_settings).
  # Forms with a table reference as the first argument accept any DETS table, used in tests.

  # Global API: get(key) -> value | nil
  def get(key), do: dets_get(:sam_settings, key, nil)

  # Test API: get(table, key) -> value | nil
  # NOTE: get(table, key, default) is the 3-arg form below; this 2-arg form uses nil as default.
  def get(table, key), do: dets_get(table, key, nil)

  # Test API: get(table, key, default)
  def get(table, key, default), do: dets_get(table, key, default)

  # Global API: put(key, value)
  def put(key, value), do: dets_put(:sam_settings, key, value)

  # Test API: put(table, key, value)
  def put(table, key, value), do: dets_put(table, key, value)

  # Global API: add_mru_workdir(path)
  def add_mru_workdir(path), do: dets_add_mru_workdir(:sam_settings, path)

  # Test API: add_mru_workdir(table, path)
  def add_mru_workdir(table, path), do: dets_add_mru_workdir(table, path)

  # Private DETS helpers

  defp dets_get(table, key, default) do
    case :dets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp dets_put(table, key, value) do
    :dets.insert(table, {key, value})
    :ok
  end

  defp dets_add_mru_workdir(table, path) do
    current = dets_get(table, :mru_workdirs, [])

    updated =
      [path | Enum.reject(current, &(&1 == path))]
      |> Enum.take(5)

    dets_put(table, :mru_workdirs, updated)
  end

  # GenServer — manages DETS lifecycle

  @impl true
  def init(_) do
    dets_path = Path.join(data_dir(), "sam_settings") |> to_charlist()
    {:ok, _table} = :dets.open_file(:sam_settings, file: dets_path, type: :set)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(:sam_settings)
  end

  defp data_dir do
    dir = Path.join(System.user_home!(), ".config/secret-agent-man/data")
    File.mkdir_p!(dir)
    dir
  end
end
