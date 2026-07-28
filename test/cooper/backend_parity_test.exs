defmodule Cooper.BackendParityTest do
  use ExUnit.Case, async: true

  # The full fixture suite passes identically under both backends.
  # Rather than re-running every other test in this suite twice, this
  # asserts the two backends produce byte-for-byte identical raw
  # entries for a representative cross-section of every language
  # feature -- comments, all value kinds, keys/blocks, sigils, loops,
  # interpolation/refs -- directly at the `run_with_context/3` vs.
  # `run_with_context_vm/3` level (Native vs. VM), independent of
  # anything built on top.

  @fixtures [
    "#@version = 1.0",
    """
    #@version = 1.0
    # a comment
    nil_v = nil
    bool_v = true
    int_v = 0xDEAD_BEEF
    float_v = -2.5e-2
    atom_v = :info
    str_v = "hello \\"world\\""
    date_v = 1979-05-27
    ip_v = 127.0.0.1/32
    dur_v = 1h30m
    bytes_v = 512MiB
    list_v = ["a", "b", "c"]
    tuple_v = (1, 2, 3)
    """,
    """
    #@version = 1.0
    *db.password = "hunter2"
    server { host = "0.0.0.0", port = 8080 }
    ~server { port = 9090 }
    +tags = ["d"]
    -tags = ["b"]
    -feature.legacy_mode
    #disabled = 1
    """,
    """
    #@version = 1.0
    @name = "world"
    greeting = "hello @{name}"
    region = ${REGION:default}
    ref = %{server.host}
    tagged = !int("42")
    resolver = !{vault:secret/path}
    """,
    """
    #@version = 1.0
    @domains = ["a.example.com", "b.example.com"]
    for @idx, @domain in @{domains} as endpoints."domain-@{idx}" {
      url = "https://@{domain}"
    }
    """
  ]

  test "Grammar.Native and Grammar.VM produce identical raw entries for every fixture" do
    for source <- @fixtures do
      ctx = Cooper.Grammar.initial_context(root: File.cwd!())

      native = Cooper.Grammar.run_with_context(source, Cooper.Actions, ctx)
      vm = Cooper.Grammar.run_with_context_vm(source, Cooper.Actions, ctx)

      assert strip_context(native) == strip_context(vm),
             "backends diverged for fixture:\n#{source}\n\nnative: #{inspect(native)}\nvm: #{inspect(vm)}"
    end
  end

  test "Cooper.InterpGrammar (native) and run_vm/1 (VM) agree on interpolation parsing" do
    fixtures = [
      "",
      "plain text, no refs",
      "hello @{name}",
      "port: ${PORT:8080}, tagged: !int(\"1\")",
      "config: %{server.host[0]:default}",
      "resolver: !{vault:a/b/c}"
    ]

    for text <- fixtures do
      assert Cooper.NativeInterpGrammar.run(text) == Cooper.InterpGrammar.run_vm(text)
    end
  end

  # The context returned alongside the value differs in irrelevant ways
  # (e.g. accumulated `:vars` insertion order) between backends; only
  # the actual parsed/evaluated *value* needs to match.
  defp strip_context({:ok, value, _ctx}), do: {:ok, value}
  defp strip_context(other), do: other
end
