defmodule Cooper.ResolverTest do
  use ExUnit.Case, async: true

  # A circular %{...} fixture raises with the cycle path in the
  # message, an unregistered resolver/tag/import-scheme each raise
  # naming the offender, and a fixture combining imports + variables +
  # env + config refs + sigils + loops produces the exact documented
  # result end to end.

  defp load!(source, opts \\ []) do
    {:ok, tree, vars} = Cooper.Grammar.run_tree("#@version = 1.0\n" <> source)
    {:ok, result} = Cooper.Resolver.resolve(tree, Keyword.put_new(opts, :vars, vars))
    result
  end

  defp load(source, opts \\ []) do
    {:ok, tree, vars} = Cooper.Grammar.run_tree("#@version = 1.0\n" <> source)
    Cooper.Resolver.resolve(tree, Keyword.put_new(opts, :vars, vars))
  end

  describe "@{} variables (CASC.md §7.1)" do
    test "a bare reference resolves to the variable's value" do
      assert load!("""
             @name = "world"
             greeting = "hello @{name}"
             """) == %{"greeting" => "hello world"}
    end

    test "a non-string value substituted bare keeps its own type" do
      assert load!("""
             @port = 8080
             port = @{port}
             """) == %{"port" => 8080}
    end

    test "a duration/bytes/IP value embedded in a string stringifies instead of crashing" do
      assert load!("""
             @t = 500ms
             @b = 512MiB
             @ip = 127.0.0.1/32
             v = "timeout=@{t} size=@{b} ip=@{ip}"
             """) == %{"v" => "timeout=500000000ns size=536870912B ip=127.0.0.1/32"}
    end

    test "an undefined variable with no suffix is a load-time error" do
      assert {:error, %Ichor.Error{stage: :resolve}} = load("v = @{missing}")
    end

    test "a default is used when undefined" do
      assert load!("v = @{missing:42}") == %{"v" => 42}
    end

    test "substitute-if-set: alt used when defined, empty string when not" do
      assert load!("""
             @x = "anything"
             v = "@{x:+alt}"
             """) == %{"v" => "alt"}

      assert load!(~S(v = "@{missing:+alt}")) == %{"v" => ""}
    end

    test "required-or-fail aborts loading with the message" do
      assert {:error, %Ichor.Error{stage: :resolve, message: "missing name"}} =
               load(~S(v = @{missing:?"missing name"}))
    end

    test "indexed access into a list-valued variable" do
      assert load!("""
             @items = ["a", "b", "c"]
             v = @{items[1]}
             """) == %{"v" => "b"}
    end

    test "a variable whose own value is an unresolved ref is resolved before substitution" do
      assert load!(
               """
               @region = ${REGION:"eu-west"}
               host = "db.@{region}.internal"
               """,
               env: %{}
             ) == %{"host" => "db.eu-west.internal"}
    end

    test "a direct self-reference is a load-time error naming the cycle, not an infinite loop" do
      assert {:error, %Ichor.Error{stage: :resolve, message: message}} =
               load("""
               @a = @{a}
               v = @{a}
               """)

      assert message == "circular @{...} reference: a -> a"
    end

    test "a transitive cycle across two variables is a load-time error naming the chain" do
      assert {:error, %Ichor.Error{stage: :resolve, message: message}} =
               load("""
               @a = @{b}
               @b = @{a}
               v = @{a}
               """)

      assert message == "circular @{...} reference: a -> b -> a"
    end
  end

  describe "${} environment expansion (CASC.md §7.2)" do
    test "CASC.md's own worked example" do
      env = %{"REGION" => "eu-west"}

      assert load!(
               """
               region = ${REGION}
               max_retries = !int(${MAX_RETRIES:3})
               allowed_hosts = ${ALLOWED_HOSTS[]:["localhost"]}
               """,
               env: env
             ) == %{
               "region" => "eu-west",
               "max_retries" => 3,
               "allowed_hosts" => ["localhost"]
             }
    end

    test "never auto-coerces -- always a string on success" do
      assert load!("v = ${PORT}", env: %{"PORT" => "8080"}) == %{"v" => "8080"}
    end

    test "unset with no default is a load-time error" do
      assert {:error, %Ichor.Error{stage: :resolve}} = load("v = ${MISSING}", env: %{})
    end

    test "empty is treated the same as unset (falls to default)" do
      assert load!("v = ${EMPTY:fallback}", env: %{"EMPTY" => ""}) == %{"v" => :fallback}
    end
  end

  describe "%{} config references (CASC.md §7.3)" do
    test "CASC.md's own worked example, including the timing note" do
      # "if a later import replaces the whole tls block via ~tls {...},
      # %{tls.min_version} resolves to the replacement's value" -- here,
      # simpler but same idea: the reference resolves against the FINAL
      # tree, so ordering in the source doesn't matter.
      assert load!("""
             server.host = "api.internal"
             server.port = 8080
             health_check.url = "http://%{server.host}:%{server.port}/health"
             admin_email = %{contact.admin:"ops@example.com"}
             """) == %{
               "server" => %{"host" => "api.internal", "port" => 8080},
               "health_check" => %{"url" => "http://api.internal:8080/health"},
               "admin_email" => "ops@example.com"
             }
    end

    test "resolves against the final tree even when defined later in the file" do
      assert load!("""
             a = %{b}
             b = 1
             """) == %{"a" => 1, "b" => 1}
    end

    test "a genuine cycle is a load-time error with the cycle path in the message" do
      assert {:error, %Ichor.Error{stage: :resolve, message: message}} =
               load("""
               a = %{b}
               b = %{c}
               c = %{a}
               """)

      # Detection starts from whichever of a/b/c the tree walk (map
      # iteration order, unspecified) reaches first -- any rotation of
      # the same cycle is equally correct, e.g. "b -> c -> a -> b".
      assert message =~ ~r/\A circular \s %\{\.\.\.\} \s reference: \s
                            (a|b|c) \s -> \s (a|b|c) \s -> \s (a|b|c) \s -> \s \1 \z/x
    end
  end

  describe "!{resolver:payload} dispatch (CASC.md §7.4/§9.4)" do
    test "dispatches to the registered resolver with the payload verbatim" do
      resolvers = %{"vault" => fn payload -> {:ok, "resolved:" <> payload} end}

      assert load!("v = !{vault:secret/db/password}", resolvers: resolvers) == %{
               "v" => "resolved:secret/db/password"
             }
    end

    test "an unregistered resolver is a load-time error naming it" do
      assert {:error, %Ichor.Error{stage: :resolve, message: message}} =
               load("v = !{vault:secret/db/password}")

      assert message =~ "vault"
    end

    test "a payload nesting braces past the old single-level bound (Cooper.Native.ResolverRef)" do
      resolvers = %{"vault" => fn payload -> {:ok, payload} end}

      assert load!("v = !{vault:{a:{b:{c:1}}}}", resolvers: resolvers) == %{
               "v" => "{a:{b:{c:1}}}"
             }
    end
  end

  describe "!Name(arg) dispatch (CASC.md §7.5/§9.4)" do
    test "built-in !int/!float/!bool/!duration/!bytes" do
      assert load!("v = !int(\"42\")") == %{"v" => 42}
      assert load!("v = !float(\"3.5\")") == %{"v" => 3.5}
      assert load!("v = !bool(\"true\")") == %{"v" => true}
      assert load!("v = !duration(\"5m\")") == %{"v" => {:duration, 300_000_000_000}}
      assert load!("v = !bytes(\"512MiB\")") == %{"v" => {:bytes, 536_870_912}}
    end

    test "port/debug example from CASC.md §7.2, end to end" do
      assert load!(
               """
               port = !int(${PORT:8080})
               debug = !bool(${DEBUG:false})
               """,
               env: %{}
             ) == %{"port" => 8080, "debug" => false}
    end

    test "a consumer-registered tag" do
      tags = %{"upcase" => fn arg -> {:ok, String.upcase(arg)} end}
      assert load!("v = !upcase(\"hi\")", tags: tags) == %{"v" => "HI"}
    end

    test "an unregistered tag is a load-time error naming it" do
      assert {:error, %Ichor.Error{stage: :resolve, message: message}} = load("v = !uuid(\"x\")")
      assert message =~ "uuid"
    end
  end

  describe "for-loop `from` interaction (Cooper.Merge.Layered, loop+merge+resolve end to end)" do
    test "the base resolves and overrides deep-merge on top, per replica" do
      source = """
      defaults.replica { cpu = 1, memory_mb = 512 }

      @instances = ["a", "b", "c"]
      for @instance in @{instances} from defaults.replica as replicas."@{instance}" {
        cpu = 2
      }
      """

      assert load!(source) == %{
               "defaults" => %{"replica" => %{"cpu" => 1, "memory_mb" => 512}},
               "replicas" => %{
                 "a" => %{"cpu" => 2, "memory_mb" => 512},
                 "b" => %{"cpu" => 2, "memory_mb" => 512},
                 "c" => %{"cpu" => 2, "memory_mb" => 512}
               }
             }
    end
  end

  describe "combined fixture: imports + variables + env + config refs + sigils + loops" do
    test "produces the exact expected result end to end" do
      import_dir = Path.join([__DIR__, "..", "fixtures", "resolver"])

      assert {:ok, tree, vars} =
               Cooper.Grammar.run_tree(File.read!(Path.join(import_dir, "main.casc")),
                 root: import_dir
               )

      assert {:ok, result} =
               Cooper.Resolver.resolve(tree, vars: vars, env: %{"EXTRA_TAG" => "prod"})

      assert result == %{
               "base" => %{"name" => "base-service"},
               "service" => %{
                 "name" => "base-service",
                 "tag" => "prod"
               },
               "replicas" => %{
                 "0" => %{"cpu" => 1},
                 "1" => %{"cpu" => 1}
               }
             }
    end
  end

  describe "secrecy travels with a copied value, not just its original path" do
    test "a %{...} reference to a secret path is itself wrapped, not the raw value" do
      result =
        load!("""
        database { *password = "hunter2", host = "db.internal" }
        copy = %{database.password}
        """)

      assert %Cooper.Secret{value: "hunter2"} = result["copy"]
    end

    test "a for...from template copying a secret subtree wraps every generated copy" do
      result =
        load!("""
        defaults.creds { *token = "topsecret" }
        @ids = ["a", "b"]
        for @id in @{ids} from defaults.creds as replicas."@{id}" {}
        """)

      assert %Cooper.Secret{value: "topsecret"} = result["replicas"]["a"]["token"]
      assert %Cooper.Secret{value: "topsecret"} = result["replicas"]["b"]["token"]
    end

    test "a tag applied to a secret-sourced argument re-wraps the result" do
      result =
        load!("""
        *port_secret = "8443"
        tagged = !int(%{port_secret})
        """)

      assert %Cooper.Secret{value: 8443} = result["tagged"]
    end

    test "indexing into a secret-wrapped list re-wraps the element" do
      result =
        load!("""
        *items = ["a", "b", "c"]
        indexed = %{items[1]}
        """)

      assert %Cooper.Secret{value: "b"} = result["indexed"]
    end
  end

  describe "partial redaction of a secret embedded in a larger string (CASC.md §7)" do
    test "only the secret portion is redacted, not the whole string" do
      result =
        load!("""
        database { *password = "hunter2", host = "db.internal" }
        url = "postgres://user:%{database.password}@%{database.host}/app"
        """)

      assert %Cooper.Secret{} = url = result["url"]
      assert to_string(url) == "postgres://user:[~~REDACTED~~]@db.internal/app"
      assert inspect(url) == "\"postgres://user:[~~REDACTED~~]@db.internal/app\""
      assert Cooper.Secret.reveal(url) == "postgres://user:hunter2@db.internal/app"
    end

    test "multiple secrets interpolated into the same string each redact independently" do
      result =
        load!("""
        *user = "admin"
        *pass = "hunter2"
        conn = "user=%{user};pass=%{pass};host=localhost"
        """)

      assert %Cooper.Secret{} = conn = result["conn"]
      assert to_string(conn) == "user=[~~REDACTED~~];pass=[~~REDACTED~~];host=localhost"
      assert Cooper.Secret.reveal(conn) == "user=admin;pass=hunter2;host=localhost"
    end

    test "a plain string with no secret at all is unaffected (fast path, no wrapping)" do
      result = load!(~S(v = "hello @{name}"), vars: %{"name" => "world"})
      assert result["v"] == "hello world"
    end
  end
end
