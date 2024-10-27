defmodule Charms.Env do
  @moduledoc """
  Intrinsic module for BEAM environment's type.
  """
  use Charms.Intrinsic

  @impl true
  def handle_intrinsic(:t, _params, [], opts) do
    Beaver.ENIF.Type.env(opts)
  end

  defintrinsic [:t]
end
