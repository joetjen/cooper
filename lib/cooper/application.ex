defmodule Cooper.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Cooper.Cache], strategy: :one_for_one, name: Cooper.Supervisor)
  end
end
