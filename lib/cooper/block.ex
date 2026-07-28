defmodule Cooper.Block do
  @moduledoc """
  Internal marker wrapping a `{ ... }` block's already-flattened entries,
  distinguishing "this statement's right-hand side was a block" from "was
  a scalar value" (`Cooper.Actions`' own `handle_rule/3` clause for
  `:kv_statement` branches on it). A struct rather than a tagged tuple
  deliberately --
  CASC tuples (§6.11) are real Elixir tuples built from user data, and a
  plain `{:block_ops, list}` tag could theoretically collide with one; a
  struct never can.
  """

  @enforce_keys [:ops]
  defstruct ops: []

  @type t :: %__MODULE__{ops: [{:op, Cooper.Op.t()} | {:var, Cooper.VarDecl.t()}]}
end
