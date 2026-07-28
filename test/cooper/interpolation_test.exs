defmodule Cooper.InterpolationTest do
  use ExUnit.Case, async: true

  # Every CASC.md §7 worked example produces the correct *unresolved*
  # AST -- resolution is `Cooper.Resolver`'s job.

  defp value(literal) do
    {:ok, %{"v" => value}} = Cooper.Grammar.run("#@version = 1.0\nv = #{literal}")
    value
  end

  describe "variables, bare (CASC.md §7.1)" do
    test "a bare reference" do
      assert value("@{name}") == %Cooper.Ref.Var{name: "name", index: nil, suffix: nil}
    end

    test "with a default" do
      assert value("@{name:\"fallback\"}") ==
               %Cooper.Ref.Var{name: "name", index: nil, suffix: {:default, "fallback"}}
    end

    test "substitute-if-set" do
      assert value("@{name:+alt}") ==
               %Cooper.Ref.Var{name: "name", index: nil, suffix: {:substitute, :alt}}
    end

    test "required-or-fail" do
      assert value(~S(@{name:?"missing name"})) ==
               %Cooper.Ref.Var{name: "name", index: nil, suffix: {:required, "missing name"}}
    end

    test "indexed" do
      assert value("@{name[2]}") == %Cooper.Ref.Var{name: "name", index: 2, suffix: nil}

      assert value("@{name[2]:0}") == %Cooper.Ref.Var{
               name: "name",
               index: 2,
               suffix: {:default, 0}
             }
    end
  end

  describe "variables, embedded in a string (CASC.md §7.1)" do
    test "produces a Cooper.Interp.Text with the ref as one segment" do
      assert value(~S("https://@{domain}:@{port}")) ==
               %Cooper.Interp.Text{
                 segments: [
                   "https://",
                   %Cooper.Ref.Var{name: "domain", index: nil, suffix: nil},
                   ":",
                   %Cooper.Ref.Var{name: "port", index: nil, suffix: nil}
                 ]
               }
    end
  end

  describe "environment expansion (CASC.md §7.2)" do
    test "a bare reference" do
      assert value("${REGION}") == %Cooper.Ref.Env{
               name: "REGION",
               index: nil,
               list?: false,
               suffix: nil
             }
    end

    test "with a default" do
      assert value("${MAX_RETRIES:3}") ==
               %Cooper.Ref.Env{
                 name: "MAX_RETRIES",
                 index: nil,
                 list?: false,
                 suffix: {:default, 3}
               }
    end

    test "substitute-if-set" do
      assert value("${FEATURE:+on}") ==
               %Cooper.Ref.Env{
                 name: "FEATURE",
                 index: nil,
                 list?: false,
                 suffix: {:substitute, :on}
               }
    end

    test "required-or-fail" do
      assert value(~S(${TOKEN:?"missing token"})) ==
               %Cooper.Ref.Env{
                 name: "TOKEN",
                 index: nil,
                 list?: false,
                 suffix: {:required, "missing token"}
               }
    end

    test "list form with a list default" do
      assert value(~S(${ALLOWED_HOSTS[]:["localhost"]})) ==
               %Cooper.Ref.Env{
                 name: "ALLOWED_HOSTS",
                 index: nil,
                 list?: true,
                 suffix: {:default, ["localhost"]}
               }
    end

    test "indexed form" do
      assert value("${HOSTS[0]:default}") ==
               %Cooper.Ref.Env{
                 name: "HOSTS",
                 index: 0,
                 list?: false,
                 suffix: {:default, :default}
               }
    end
  end

  describe "config references (CASC.md §7.3)" do
    test "a bare reference" do
      assert value("%{server.host}") == %Cooper.Ref.Config{
               path: ["server", "host"],
               index: nil,
               suffix: nil
             }
    end

    test "with a quoted-string default, matching CASC.md's own example" do
      assert value(~S(%{contact.admin:"ops@example.com"})) ==
               %Cooper.Ref.Config{
                 path: ["contact", "admin"],
                 index: nil,
                 suffix: {:default, "ops@example.com"}
               }
    end

    test "embedded in a string alongside another config ref" do
      assert value(~S("http://%{server.host}:%{server.port}/health")) ==
               %Cooper.Interp.Text{
                 segments: [
                   "http://",
                   %Cooper.Ref.Config{path: ["server", "host"], index: nil, suffix: nil},
                   ":",
                   %Cooper.Ref.Config{path: ["server", "port"], index: nil, suffix: nil},
                   "/health"
                 ]
               }
    end
  end

  describe "extensible resolution (CASC.md §7.4)" do
    test "splits on the first colon, payload verbatim" do
      assert value("!{vault:secret/db/password}") ==
               %Cooper.Ref.Resolver{name: "vault", payload: "secret/db/password"}
    end

    test "a payload containing its own colon stays intact (first colon still wins)" do
      assert value("!{vault:secret:db:password}") ==
               %Cooper.Ref.Resolver{name: "vault", payload: "secret:db:password"}
    end

    test "a payload nesting braces past the old single-level bound (Cooper.Native.ResolverRef)" do
      assert value("!{vault:{a:{b:{c:1}}}}") ==
               %Cooper.Ref.Resolver{name: "vault", payload: "{a:{b:{c:1}}}"}
    end
  end

  describe "tagged values (CASC.md §7.5)" do
    test "argument is a plain string, parsed as an ordinary value" do
      assert value("!duration(\"5m\")") == %Cooper.Ref.Tagged{name: "duration", arg: "5m"}
    end

    test "bare, whole-value form recurses through the main grammar's own value rule" do
      assert value("!int(${PORT:8080})") ==
               %Cooper.Ref.Tagged{
                 name: "int",
                 arg: %Cooper.Ref.Env{
                   name: "PORT",
                   index: nil,
                   list?: false,
                   suffix: {:default, 8080}
                 }
               }
    end

    test "port/debug example from CASC.md §7.2" do
      assert value("!bool(${DEBUG:false})") ==
               %Cooper.Ref.Tagged{
                 name: "bool",
                 arg: %Cooper.Ref.Env{
                   name: "DEBUG",
                   index: nil,
                   list?: false,
                   suffix: {:default, false}
                 }
               }
    end
  end
end
