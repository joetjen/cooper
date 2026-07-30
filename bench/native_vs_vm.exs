# Checks that Grammar.Native shows the expected speedup over Grammar.VM
# (~2x, per Ichor's own docs). Run with:
#
#   MIX_ENV=test mix run bench/native_vs_vm.exs
#
# MIX_ENV=test, not a plain `mix run` -- the VM-parity path this
# benchmark compares against (`Cooper.Test.VMParity`) lives under
# `test/support/`, only added to `elixirc_paths` for `:test` (see
# `mix.exs`), since it calls into `ichor` proper (`Grammar.VM`,
# `Grammar.Analysis`, ...), an `only: [:dev, :test], runtime: false`
# dependency that a plain `:dev` `mix run` won't have compiled either.
#
# Representative fixture sizes, not microbenchmarks -- two of them,
# deliberately: a realistic multi-feature config (what CASC files
# actually look like) *and* a string-light one. They show meaningfully
# different ratios, and that's the actual finding worth keeping visible
# rather than picking whichever number looks better: every double-quoted
# string's content is re-parsed through `Cooper.InterpGrammar` regardless
# of which backend is under test here (that sub-grammar is already
# Native by default since it's invoked dynamically either way) -- so a
# string-heavy fixture spends a
# growing share of its time in *identical* work on both sides,
# mechanically diluting the measured difference from the *main*
# grammar's own backend choice. Neither number is "wrong"; the
# string-light one isolates what this backend switch alone is worth,
# the realistic one is what an actual CASC file sees.

realistic = """
#@version = 1.0

@region = "eu-west"
@instances = ["a", "b", "c"]

server {
  host = "0.0.0.0"
  port = 8080
  tls { min_version = "1.2", ciphers = ["TLS_AES_128_GCM_SHA256"] }
}

~server { port = 9090 }

database {
  *password = "hunter2"
  host = "db.internal"
  pool_size = 10
  timeout = 500ms
}

limits {
  max_memory = 512MiB
  max_connections = 1000
  rate_window = 1h30m
}

tags = ["a", "b", "c"]
+tags = ["d"]
-tags = ["b"]

allowed_ips = [127.0.0.1/32, ::1/128]

endpoint.url = "https://api.@{region}.example.com/health"
endpoint.retries = !int("3")

for @instance in @{instances} as replicas."@{instance}" {
  cpu = 2
  memory_mb = 512
}
"""

string_light = """
#@version = 1.0

@count = [1, 2, 3]

server { host_id = 1, port = 8080 }
~server { port = 9090 }

database {
  pool_size = 10
  timeout = 500ms
}

limits {
  max_memory = 512MiB
  max_connections = 1000
  rate_window = 1h30m
}

numbers = [1, 2, 3]
+numbers = [4]
-numbers = [2]

allowed_ips = [127.0.0.1/32, ::1/128]

endpoint.retries = !int("3")

for @n in @{count} as replicas."@{n}" {
  cpu = 2
  memory_mb = 512
}
"""

ctx = Cooper.Grammar.initial_context(root: File.cwd!())

run = fn label, fixture, iterations ->
  native = Cooper.Grammar.run_with_context(fixture, Cooper.Actions, ctx)
  vm = Cooper.Test.VMParity.run_with_context_vm(fixture, Cooper.Actions, ctx)

  if elem(native, 1) != elem(vm, 1) do
    raise "backends disagree on #{label}:\nnative: #{inspect(native)}\nvm: #{inspect(vm)}"
  end

  time = fn fun ->
    {micros, _} = :timer.tc(fn -> for _ <- 1..iterations, do: fun.(fixture) end)
    micros
  end

  vm_micros =
    time.(fn input -> Cooper.Test.VMParity.run_with_context_vm(input, Cooper.Actions, ctx) end)

  native_micros = time.(fn input -> Cooper.Grammar.run_with_context(input, Cooper.Actions, ctx) end)

  IO.puts("#{label} (#{iterations} iterations):")
  IO.puts("  VM:     #{Float.round(vm_micros / 1000, 1)} ms")
  IO.puts("  Native: #{Float.round(native_micros / 1000, 1)} ms")
  IO.puts("  Native is #{Float.round(vm_micros / native_micros, 2)}x the VM's speed")
  IO.puts("")
end

run.("realistic multi-feature config", realistic, 2_000)
run.("string-light (isolates the main grammar's own backend cost)", string_light, 2_000)
