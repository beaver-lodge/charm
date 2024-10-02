defmodule Charms.Application do
  @moduledoc false

  def start(_args, _type) do
    children = [
      Charms.JIT.Cache
    ]

    Supervisor.start_link(children, name: __MODULE__, strategy: :one_for_one)
  end
end
