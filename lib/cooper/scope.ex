defmodule Cooper.Scope do
  @moduledoc """
  Per-file variable visibility (CASC.md §5.2).

  A CASC load flattens an arbitrarily deep import tree into one list of
  `Cooper.Op` entries, and `Cooper.Resolver` resolves that flat result
  against one variable environment. Visibility, however, is a property
  of the *file a reference was written in*:

    * `@name` -- public. Visible to the file's importers (transitively),
      and to the files it imports. Public variables live in the single
      shared environment and need no scoping at all.
    * `@*name` -- private. Usable anywhere inside its declaring file,
      and invisible everywhere else.

  Flattening destroys the file boundary that the private half depends
  on, so it has to be recorded before the flattening happens. This
  module stamps every `Cooper.Ref.Var` in a freshly parsed file's
  entries with that file's `scope` (its expanded path, or
  `"(source)"` for a string loaded without one), and collects that
  file's private declarations into a per-scope environment that
  `Cooper.Resolver` consults *before* the shared one.

  Stamping is idempotent and outside-in safe: `stamp/2` only fills in
  references whose scope is still `nil`, so entries spliced in from an
  already-stamped nested import keep the scope of the file that
  actually wrote them rather than being re-attributed to their
  importer.
  """

  @anonymous "(source)"

  @doc """
  Returns the scope identity for `file`, or the anonymous scope when a
  source string was loaded without a path.
  """
  @spec id(String.t() | nil) :: String.t()
  def id(nil), do: @anonymous
  def id(file), do: Path.expand(file)

  @doc """
  Stamps every not-yet-stamped `Cooper.Ref.Var` reachable from `term`
  with `scope`, leaving references already attributed to a nested
  import untouched.
  """
  @spec stamp(term(), String.t()) :: term()
  def stamp(%Cooper.Ref.Var{scope: nil} = ref, scope) do
    %{ref | name: stamp(ref.name, scope), suffix: stamp(ref.suffix, scope), scope: scope}
  end

  def stamp(%Cooper.Ref.Var{} = ref, _scope), do: ref

  def stamp(%Cooper.Interp.Text{segments: segments} = text, scope) do
    %{text | segments: Enum.map(segments, &stamp(&1, scope))}
  end

  def stamp(%Cooper.Op{value: value} = op, scope), do: %{op | value: stamp(value, scope)}

  def stamp(%Cooper.VarDecl{value: value} = decl, scope),
    do: %{decl | value: stamp(value, scope)}

  def stamp(%Cooper.Ref.Tagged{arg: arg} = ref, scope), do: %{ref | arg: stamp(arg, scope)}

  def stamp(%Cooper.Ref.Env{} = ref, scope),
    do: %{ref | name: stamp(ref.name, scope), suffix: stamp(ref.suffix, scope)}

  def stamp(%Cooper.Ref.Config{} = ref, scope),
    do: %{ref | path: stamp(ref.path, scope), suffix: stamp(ref.suffix, scope)}

  # A struct with no references of its own (`Cooper.Secret`,
  # `Cooper.IPv4`, `DateTime`, ...) is a leaf: walking its fields would
  # rebuild it field-by-field for nothing, and `Cooper.Secret` in
  # particular must not be taken apart here.
  def stamp(%_{} = struct, _scope), do: struct

  def stamp(list, scope) when is_list(list), do: Enum.map(list, &stamp(&1, scope))

  def stamp(map, scope) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, stamp(value, scope)} end)
  end

  def stamp(tuple, scope) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&stamp(&1, scope)) |> List.to_tuple()
  end

  def stamp(other, _scope), do: other

  @doc """
  Splits a parsed file's `vars` (`name => {value, public?}`, a private
  declaration keyed `{:private, name}`) into the public environment that
  crosses file boundaries and the private one that does not, both keyed
  by plain name.
  """
  @spec split(map()) :: {map(), map()}
  def split(vars) do
    {public, private} = Enum.split_with(vars, fn {_key, {_value, public?}} -> public? end)

    {Map.new(public, fn {name, {value, _}} -> {name, value} end),
     Map.new(private, fn {{:private, name}, {value, _}} -> {name, value} end)}
  end

  @doc """
  The value `name` has in a file's `vars` so far -- its private
  declaration if it has one, otherwise the public one (CASC.md §5.2's
  shadowing, as `Cooper.Loop` needs it for an iterable).
  """
  @spec lookup(map(), String.t()) :: {:ok, term()} | :error
  def lookup(vars, name) do
    case Map.fetch(vars, {:private, name}) do
      {:ok, {value, _}} ->
        {:ok, value}

      :error ->
        case Map.fetch(vars, name) do
          {:ok, {value, _}} -> {:ok, value}
          :error -> :error
        end
    end
  end
end
