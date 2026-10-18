defmodule Cooper.ValueStructsDoctestTest do
  use ExUnit.Case, async: true

  # The examples in the three value structs' docs, run: an example that
  # states its result is a test.
  doctest Cooper.Duration
  doctest Cooper.ByteSize
  doctest Cooper.Infinity
end
