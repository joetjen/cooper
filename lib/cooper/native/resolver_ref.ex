defmodule Cooper.Native.ResolverRef do
  @moduledoc """
  `@native("Cooper.Native.ResolverRef", "scan")` implementation for
  `RESOLVER_REF_RAW` (`casc.aether`/`casc_interp.aether`): scans a
  `!{name:payload}` resolver reference (CASC.md §7.4) with genuinely
  unbounded brace nesting in `payload`, tracking depth as it goes.

  Superseded by this token's earlier, ordinary-combinator form (one
  literal level of `"{"`/`"}"` tolerated, no deeper -- Aether tokens
  can't self-reference, so a fixed grammar can only ever hard-code a
  fixed nesting depth) once Ichor 0.1.1 added `@native(...)` at token
  position: what was a *documented limitation* ("realistic payloads
  don't nest deeper") is now simply not a limitation, at zero cost to
  every payload that never nested in the first place. `Cooper.RefCommon
  .build_resolver_ref/2` -- the only consumer of this token's captured
  text -- already works on the raw span regardless of how deep it
  nests, so nothing downstream needed to change.
  """

  @behaviour Ichor.CustomLexeme

  @impl Ichor.CustomLexeme
  def scan(input, _context, _rule_matchers) do
    with "!{" <> rest <- input,
         {:ok, after_close} <- consume_balanced(rest, 1) do
      text = binary_part(input, 0, byte_size(input) - byte_size(after_close))
      {:ok, text, after_close, nil}
    else
      _ -> :fail
    end
  end

  # `depth` counts unclosed "{"s still open, starting at 1 for the "!{"
  # that got us here -- hits 0 (returns) the moment the matching "}"
  # closes it back out. Walked one codepoint at a time (not byte at a
  # time) so multi-byte UTF-8 payload text (CASC strings/keys allow it
  # freely elsewhere) never gets split mid-character.
  defp consume_balanced("{" <> rest, depth), do: consume_balanced(rest, depth + 1)
  defp consume_balanced("}" <> rest, 1), do: {:ok, rest}
  defp consume_balanced("}" <> rest, depth), do: consume_balanced(rest, depth - 1)

  defp consume_balanced(<<>>, _depth), do: :fail

  defp consume_balanced(input, depth) do
    {_codepoint, rest} = String.next_codepoint(input)
    consume_balanced(rest, depth)
  end
end
