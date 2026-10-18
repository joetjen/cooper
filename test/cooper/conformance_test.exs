defmodule Cooper.ConformanceTest do
  use ExUnit.Case, async: true

  # The adapter the Cooper Conformance Suite runs this implementation
  # through: a JSON request in, a JSON answer out, every value in the
  # suite's typed JSON (assize), every error as its §9.5 category.

  alias Cooper.Conformance

  @fixtures Path.expand("../fixtures/conformance", __DIR__)

  defp load(name),
    do: %{"id" => "c: #{name}", "operation" => "load", "document" => Path.join(@fixtures, name)}

  describe "a value in the suite's typed JSON" do
    test "a string, a boolean and nil are themselves" do
      assert Conformance.encode(["s", true, false, nil]) == ["s", true, false, nil]
    end

    test "a number is typed, as text" do
      assert Conformance.encode(42) == %{"integer" => "42"}
      assert Conformance.encode(2.0) == %{"float" => "2.0"}

      assert Conformance.encode(123_456_789_012_345_678_901) == %{
               "integer" => "123456789012345678901"
             }
    end

    test "an atom is a keyword, a list an array, a tuple a tuple" do
      assert Conformance.encode([:info, {1, :x}]) ==
               [%{"keyword" => "info"}, %{"tuple" => [%{"integer" => "1"}, %{"keyword" => "x"}]}]
    end

    test "a map is a list of pairs, in key order" do
      assert Conformance.encode(%{"b" => 1, "a" => 2}) ==
               %{"map" => [["a", %{"integer" => "2"}], ["b", %{"integer" => "1"}]]}
    end

    # What CASC has and Praxis notation has no literal for is a tuple
    # tagged with a dotted keyword, which no CASC atom can be.
    test "a duration and a byte size are tagged with their base unit" do
      assert Conformance.encode({:duration, 300_000_000_000}) ==
               %{"tuple" => [%{"keyword" => "casc.duration"}, %{"integer" => "300000000000"}]}

      assert Conformance.encode({:bytes, 512}) ==
               %{"tuple" => [%{"keyword" => "casc.bytes"}, %{"integer" => "512"}]}
    end

    test "a secret is tagged, and carries its shown form when partly redacted" do
      assert Conformance.encode(%Cooper.Secret{value: "s", redacted: nil}) ==
               %{"tuple" => [%{"keyword" => "casc.secret"}, "s"]}

      assert Conformance.encode(%Cooper.Secret{
               value: "http://a",
               redacted: "http://[~~REDACTED~~]"
             }) ==
               %{"tuple" => [%{"keyword" => "casc.secret"}, "http://a", "http://[~~REDACTED~~]"]}
    end

    test "a module is tagged with its name as CASC writes it" do
      assert Conformance.encode(Foo.Bar) == %{
               "tuple" => [%{"keyword" => "casc.module"}, "Foo.Bar"]
             }
    end

    test "infinity is a tagged float" do
      assert Conformance.encode(:infinity) == %{"tuple" => [%{"keyword" => "casc.float"}, "inf"]}

      assert Conformance.encode(:neg_infinity) == %{
               "tuple" => [%{"keyword" => "casc.float"}, "-inf"]
             }
    end

    test "dates and times are tagged ISO 8601" do
      assert Conformance.encode(~D[2026-10-18]) == %{
               "tuple" => [%{"keyword" => "casc.date"}, "2026-10-18"]
             }

      assert Conformance.encode(~T[07:32:00]) == %{
               "tuple" => [%{"keyword" => "casc.time"}, "07:32:00"]
             }

      assert Conformance.encode(~N[2026-10-18 07:32:00]) ==
               %{"tuple" => [%{"keyword" => "casc.local-date-time"}, "2026-10-18T07:32:00"]}

      assert Conformance.encode(~U[2026-10-18 07:32:00Z]) ==
               %{"tuple" => [%{"keyword" => "casc.date-time"}, "2026-10-18T07:32:00Z"]}
    end
  end

  describe "answering a request" do
    test "a document that loads answers its result" do
      %{"results" => [result]} = Conformance.answer(%{"cases" => [load("plain.casc")]})
      assert result["id"] == "c: plain.casc"

      assert result["result"] ==
               Conformance.encode(%{
                 "a" => 1,
                 "wait" => {:duration, 300_000_000_000},
                 "region" => "eu-west",
                 "pw" => %Cooper.Secret{value: "s", redacted: nil},
                 "t" => {1, :x}
               })
    end

    test "a document that is refused answers its category" do
      assert Conformance.answer(%{"cases" => [load("refused.casc")]}) ==
               %{"results" => [%{"id" => "c: refused.casc", "error" => "resolve"}]}
    end

    test "an operation it does not know is an error naming it" do
      %{"results" => [result]} =
        Conformance.answer(%{"cases" => [%{"id" => "x", "operation" => "dance"}]})

      assert result["error"] =~ "dance"
    end
  end

  describe "the files" do
    @tag :tmp_dir
    test "a request file is answered in an answer file", %{tmp_dir: dir} do
      request = Path.join(dir, "request.json")
      answer = Path.join(dir, "answer.json")
      File.write!(request, JSON.encode!(%{"cases" => [load("refused.casc")]}))

      assert Conformance.run(request, answer) == :ok

      assert JSON.decode!(File.read!(answer)) == %{
               "results" => [%{"id" => "c: refused.casc", "error" => "resolve"}]
             }
    end
  end
end
