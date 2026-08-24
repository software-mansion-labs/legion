defmodule Legion.Test.Support.EchoTool do
  @moduledoc "Echoes its arguments back, for sandbox bridge tests."
  use Legion.Tool

  def echo(value), do: {:ok, value}
  def add(a, b), do: a + b
  def boom, do: raise(ArgumentError, "boom")
end
