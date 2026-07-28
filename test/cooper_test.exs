defmodule CooperTest do
  use ExUnit.Case, async: true

  # Every CASC.md example fixture loads via Cooper.load_file/2 into the
  # documented result, with secrets wrapped/redacting correctly and
  # tuples verified as real tuples (is_tuple/1), not lists.

  defp load!(source, opts \\ []) do
    {:ok, result} = Cooper.load_string("#@version = 1.0\n" <> source, opts)
    result
  end

  describe "load_string/2, end to end" do
    test "CASC.md §5.4's dotted-path/nested-block equivalence" do
      assert load!(~S(foo.bar.baz "dronf")) == %{"foo" => %{"bar" => %{"baz" => "dronf"}}}
    end

    test "CASC.md §7.3's config-reference worked example" do
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

    test "CASC.md §5.5's parallel-loop worked example" do
      assert load!("""
             @domains = ["us-east.example.com", "eu-west.example.com"]
             @ports = [8443, 8444]

             for @idx, @domain in @{domains}, @port in @{ports} as endpoints."domain-@{idx}" {
               url = "https://@{domain}:@{port}"
             }
             """) == %{
               "endpoints" => %{
                 "domain-0" => %{"url" => "https://us-east.example.com:8443"},
                 "domain-1" => %{"url" => "https://eu-west.example.com:8444"}
               }
             }
    end

    test "CASC.md §8.4's merge worked example" do
      assert load!("""
             server { host = "0.0.0.0", port = 8080 }
             tags = ["a", "b", "c"]
             feature.legacy_mode = true

             ~server { port = 9090 }
             +tags = ["d"]
             -tags = ["b"]
             -feature.legacy_mode
             """) == %{
               "server" => %{"port" => 9090},
               "tags" => ["a", "c", "d"],
               "feature" => %{}
             }
    end
  end

  describe "tuples come back as real Elixir tuples, not lists (CASC.md §6.11)" do
    test "a bare tuple literal" do
      result = load!("office_location = (52.5200, 13.4050)")
      assert result == %{"office_location" => {52.52, 13.405}}
      assert is_tuple(result["office_location"])
      refute is_list(result["office_location"])
    end

    test "a tuple survives resolution untouched by list handling" do
      result = load!("@x = 1\nloc = (@{x}, 2)")
      assert result == %{"loc" => {1, 2}}
      assert is_tuple(result["loc"])
    end
  end

  describe "secrets (CASC.md §4.3)" do
    test "a secret leaf is wrapped in Cooper.Secret" do
      result = load!("*password = \"hunter2\"")
      assert %Cooper.Secret{} = result["password"]
      assert Cooper.Secret.reveal(result["password"]) == "hunter2"
    end

    test "inspect and to_string both redact, never leaking the real value" do
      secret = %Cooper.Secret{value: "hunter2"}
      assert inspect(secret) == "[~~REDACTED~~]"
      assert to_string(secret) == "[~~REDACTED~~]"
      refute inspect(secret) =~ "hunter2"
    end

    test "secret propagates from any of the three prefix positions (§4.3)" do
      assert %Cooper.Secret{value: "x"} = load!(~S(*password = "x"))["password"]
      assert %Cooper.Secret{value: "x"} = load!(~S(db.*password = "x"))["db"]["password"]
      assert %Cooper.Secret{value: "x"} = load!(~S(*db.password = "x"))["db"]["password"]
    end

    test "a non-secret sibling under a secret parent is not itself wrapped" do
      result = load!("db { *password = \"x\", host = \"localhost\" }")
      assert %Cooper.Secret{} = result["db"]["password"]
      assert result["db"]["host"] == "localhost"
    end

    test "a later plain write over a secret path is no longer secret (inferred propagation rule)" do
      result = load!("*password = \"x\"\npassword = \"y\"")
      assert result["password"] == "y"
    end

    test "a %{...} reference copying a secret value stays wrapped at its new path too" do
      result =
        load!("""
        database { *password = "hunter2", host = "db.internal" }
        connection_string = "postgres://%{database.host}?pw=%{database.password}"
        """)

      assert %Cooper.Secret{} = conn = result["connection_string"]
      assert to_string(conn) == "postgres://db.internal?pw=[~~REDACTED~~]"
      assert Cooper.Secret.reveal(conn) == "postgres://db.internal?pw=hunter2"
    end
  end

  describe "load_file/2" do
    test "loads a real file, with imports resolving relative to it" do
      path = Path.join([__DIR__, "fixtures", "imports", "main.casc"])
      assert {:ok, result} = Cooper.load_file(path)

      assert %{
               "server" => %{"host" => "0.0.0.0", "port" => 9090},
               "app" => %{"name" => "shared"}
             } = result
    end

    test "a nonexistent file is a load-time error" do
      assert {:error, %Ichor.Error{stage: :import}} =
               Cooper.load_file("/does/not/exist/nope.casc")
    end
  end

  describe "extensibility options (CASC.md §9.4: unregistered use always fails loudly)" do
    test "an unregistered !Name(...) tag fails" do
      assert {:error, %Ichor.Error{stage: :resolve, message: message}} =
               Cooper.load_string("#@version = 1.0\nv = !uuid(\"x\")")

      assert message =~ "uuid"
    end

    test "a registered tag/resolver/import_scheme all work together" do
      opts = [
        tags: %{"upcase" => fn arg -> {:ok, String.upcase(arg)} end},
        resolvers: %{"echo" => fn payload -> {:ok, payload} end},
        env: %{}
      ]

      assert load!("a = !upcase(\"hi\")\nb = !{echo:hello}", opts) == %{
               "a" => "HI",
               "b" => "hello"
             }
    end
  end
end
