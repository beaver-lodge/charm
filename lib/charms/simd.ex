defmodule Charms.SIMD do
  @moduledoc """
  Intrinsic module for SIMD types.
  """
  use Charms.Intrinsic
  alias MLIR.Dialect.Arith
  alias MLIR.Type

  @impl true
  def handle_intrinsic(:new, [type, width], opts) do
    fn literal_values ->
      mlir ctx: opts[:ctx], block: opts[:block] do
        values = Enum.map(literal_values, &Attribute.integer(type, &1))

        if Enum.count(values) != width do
          raise ArgumentError, "expected #{width} values, got #{length(values)}"
        end

        t = handle_intrinsic(:t, [type, width], opts)
        value = Attribute.dense_elements(values, t, opts)
        Arith.constant(value: value) >>> t
      end
    end
  end

  def handle_intrinsic(:t, [type, width], _opts) do
    Type.vector([width], type)
  end

  defintrinsic [:new, :t]
end
