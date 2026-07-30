[
  # `MapSet` is `@opaque` -- Dialyzer's success typing "sees through" a
  # `%{atom() => MapSet.t()}` literal built with `MapSet.new/1` (as
  # `Cooper.NativeGrammar.CaptureShapes.get/0` and `mix ichor.gen`-generated
  # `run/2`/`run_sequence/2` do, the latter via `Macro.escape/1` at
  # codegen time) and flags the resulting concrete struct shape against
  # `Ichor.Actions.evaluate/5`'s own opaque `capture_shapes()` parameter
  # type -- a known class of Dialyzer noise around opaque types embedded
  # in map literals, not a real type error: the values genuinely are
  # valid `MapSet.t()`s.
  {"lib/cooper/grammar.ex", "Type mismatch in call without opaque term in evaluate."},
  {"lib/cooper/native_grammar/capture_shapes.ex",
   "The @spec for get has an opaque subtype which is violated by the success typing."}
]
