defmodule Cooper.SpecCoverageTest do
  use ExUnit.Case, async: true

  # Fills the specific CASC.md corners not already covered incidentally
  # by the other test files. See test/SPEC_COVERAGE.md for the full
  # section-by-section traceability table this (and every other test
  # file) feeds into.

  describe "${?NAME} conditional statement skip (CASC.md §7.2)" do
    test "the spec's own worked example, verbatim" do
      source = """
      #@version = 1.0
      region = ${REGION}
      max_retries = !int(${MAX_RETRIES:3})
      ${?FEATURE_FLAG}
      enabled = true
      allowed_hosts = ${ALLOWED_HOSTS[]:["localhost"]}
      """

      assert Cooper.load_string(source, env: %{"REGION" => "eu-west"}) ==
               {:ok,
                %{"region" => "eu-west", "max_retries" => 3, "allowed_hosts" => ["localhost"]}}
    end

    test "the guarded statement is evaluated (not skipped) when the var is set and non-empty" do
      source = """
      #@version = 1.0
      ${?FEATURE_FLAG}
      enabled = true
      """

      assert Cooper.load_string(source, env: %{"FEATURE_FLAG" => "1"}) ==
               {:ok, %{"enabled" => true}}
    end

    test "an empty value counts as unset, same as ${NAME:default}'s own unset/empty wording" do
      source = """
      #@version = 1.0
      ${?FEATURE_FLAG}
      enabled = true
      """

      assert Cooper.load_string(source, env: %{"FEATURE_FLAG" => ""}) == {:ok, %{}}
    end

    test "only guards the one statement immediately after it -- later statements are unaffected" do
      source = """
      #@version = 1.0
      ${?MISSING}
      skipped = true
      kept = 1
      """

      assert Cooper.load_string(source, env: %{}) == {:ok, %{"kept" => 1}}
    end

    test "a skipped statement's own content is never evaluated -- an unregistered tag inside it doesn't raise" do
      source = """
      #@version = 1.0
      ${?MISSING}
      v = !nonexistent_tag("x")
      kept = 1
      """

      assert Cooper.load_string(source, env: %{}) == {:ok, %{"kept" => 1}}
    end
  end

  describe "sigil ordering combinations (CASC.md §5.7)" do
    test "~* combined: replace wholesale AND mark secret, in the fixed order" do
      source = """
      #@version = 1.0
      database { host = "old.internal", password = "old-pw" }
      ~*database { host = "db.internal", password = "hunter2" }
      """

      assert {:ok, tree, _vars} = Cooper.Grammar.run_tree(source)

      assert %{
               "database" => %{
                 "host" => %Cooper.Secret{value: "db.internal"},
                 "password" => %Cooper.Secret{value: "hunter2"}
               }
             } = tree
    end

    test "#~* combined: the disabled form of the same statement produces nothing at all" do
      source = """
      #@version = 1.0
      database { host = "old.internal" }
      #~*database { host = "db.internal", password = "hunter2" }
      """

      assert Cooper.load_string(source) == {:ok, %{"database" => %{"host" => "old.internal"}}}
    end
  end

  describe "missing version header (CASC.md §2: must be the first statement)" do
    test "a completely empty file is a load-time error" do
      assert {:error, %Ichor.Error{}} = Cooper.load_string("")
    end

    test "a file whose first statement isn't the version header is a load-time error" do
      assert {:error, %Ichor.Error{}} = Cooper.load_string("foo = 1\n#@version = 1.0\n")
    end
  end

  describe "triple-quoted strings do not interpolate (CASC.md is silent; assumed no)" do
    test "a @{} sequence inside a triple-quoted string stays literal text" do
      source = ~s(#@version = 1.0
        motd = """
            hello @{name}
            """)

      assert Cooper.load_string(source) == {:ok, %{"motd" => "hello @{name}\n"}}
    end
  end

  describe "for/in/from/as are contextual, not globally reserved (CASC.md §4.1)" do
    test "each is usable as an ordinary key name outside a for-loop" do
      source = """
      #@version = 1.0
      for = 1
      in = 2
      from = 3
      as = 4
      """

      assert Cooper.load_string(source) == {:ok, %{"for" => 1, "in" => 2, "from" => 3, "as" => 4}}
    end
  end

  describe "public variable visibility is transitive across import-of-import (CASC.md is silent; assumed yes)" do
    test "a variable declared two imports deep is visible at the top" do
      dir = Path.join([__DIR__, "..", "fixtures", "transitive_imports"])
      assert {:ok, result} = Cooper.load_file(Path.join(dir, "top.casc"))
      assert result == %{"value" => "from-deepest"}
    end
  end

  describe "later imports override earlier ones for the same path (CASC.md §5.1)" do
    test "two import statements, later one winning, same as two ordinary statements would" do
      dir = Path.join([__DIR__, "..", "fixtures", "import_order"])
      assert {:ok, result} = Cooper.load_file(Path.join(dir, "main.casc"))
      assert result == %{"value" => "second"}
    end
  end

  describe "duration unit table (CASC.md §6.8)" do
    test "every unit resolves to the documented nanosecond multiple" do
      units = %{
        "1ns" => 1,
        "1us" => 1_000,
        "1µs" => 1_000,
        "1ms" => 1_000_000,
        "1s" => 1_000_000_000,
        "1m" => 60_000_000_000,
        "1h" => 3_600_000_000_000,
        "1d" => 86_400_000_000_000
      }

      for {literal, expected_ns} <- units do
        assert Cooper.load_string("#@version = 1.0\nv = #{literal}") ==
                 {:ok, %{"v" => {:duration, expected_ns}}}
      end
    end

    test "compound literals combine strictly-descending units" do
      assert Cooper.load_string("#@version = 1.0\nv = 1h30m") ==
               {:ok, %{"v" => {:duration, 5_400_000_000_000}}}
    end
  end

  describe "byte-size unit table, decimal vs. binary (CASC.md §6.9)" do
    test "decimal (SI, x1000) units" do
      units = %{
        "1B" => 1,
        "1kB" => 1_000,
        "1MB" => 1_000_000,
        "1GB" => 1_000_000_000,
        "1TB" => 1_000_000_000_000,
        "1PB" => 1_000_000_000_000_000
      }

      for {literal, expected_bytes} <- units do
        assert Cooper.load_string("#@version = 1.0\nv = #{literal}") ==
                 {:ok, %{"v" => {:bytes, expected_bytes}}}
      end
    end

    test "binary (IEC, x1024) units" do
      units = %{
        "1KiB" => 1024,
        "1MiB" => 1024 * 1024,
        "1GiB" => 1024 * 1024 * 1024,
        "1TiB" => 1024 * 1024 * 1024 * 1024,
        "1PiB" => 1024 * 1024 * 1024 * 1024 * 1024
      }

      for {literal, expected_bytes} <- units do
        assert Cooper.load_string("#@version = 1.0\nv = #{literal}") ==
                 {:ok, %{"v" => {:bytes, expected_bytes}}}
      end
    end
  end
end
