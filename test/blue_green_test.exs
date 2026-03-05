defmodule BlueGreenTest do
  use ExUnit.Case
  doctest BlueGreen

  test "greets the world" do
    assert BlueGreen.hello() == :world
  end
end
