defmodule Cooper.Op do
  @moduledoc """
  One flattened leaf assignment: every assignment or block statement --
  regardless of surface form, dotted path, or nested block -- resolves
  recursively into a list of these before merge ever runs, so the merge
  engine (`Cooper.Merge`) only ever deep-merges paths, never
  re-discovers which parts of two differently-shaped literals mean the
  same key.
  """

  @enforce_keys [:path, :sigil, :value]
  defstruct path: [], sigil: :merge, value: nil, secret?: false

  @type sigil :: :merge | :replace | :append | :remove | :delete

  @type t :: %__MODULE__{
          path: [String.t()],
          sigil: sigil(),
          value: term(),
          secret?: boolean()
        }
end
