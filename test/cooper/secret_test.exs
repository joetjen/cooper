defmodule Cooper.SecretTest do
  use ExUnit.Case, async: true

  describe "a whole-value secret (:redacted defaults to nil -- the blanket marker)" do
    test "inspect renders the bare, unquoted marker" do
      assert inspect(%Cooper.Secret{value: "hunter2"}) == "[~~REDACTED~~]"
    end

    test "to_string renders the same marker" do
      assert to_string(%Cooper.Secret{value: "hunter2"}) == "[~~REDACTED~~]"
    end

    test "neither ever contains the real value" do
      secret = %Cooper.Secret{value: "hunter2"}
      refute inspect(secret) =~ "hunter2"
      refute to_string(secret) =~ "hunter2"
    end

    test "reveal/1 gives back the real value regardless of type" do
      assert Cooper.Secret.reveal(%Cooper.Secret{value: "hunter2"}) == "hunter2"
      assert Cooper.Secret.reveal(%Cooper.Secret{value: 42}) == 42
      assert Cooper.Secret.reveal(%Cooper.Secret{value: %{a: 1}}) == %{a: 1}
    end
  end

  describe "a partially-redacted secret (:redacted set -- a secret embedded in a larger string)" do
    test "to_string renders the precomputed redacted text, not the blanket marker" do
      secret = %Cooper.Secret{
        value: "conn=hunter2",
        redacted: "conn=[~~REDACTED~~]"
      }

      assert to_string(secret) == "conn=[~~REDACTED~~]"
    end

    test "inspect renders it quoted, like an ordinary string" do
      secret = %Cooper.Secret{value: "conn=hunter2", redacted: "conn=[~~REDACTED~~]"}
      assert inspect(secret) == "\"conn=[~~REDACTED~~]\""
    end

    test "reveal/1 still gives back the fully unmasked real value" do
      secret = %Cooper.Secret{value: "conn=hunter2", redacted: "conn=[~~REDACTED~~]"}
      assert Cooper.Secret.reveal(secret) == "conn=hunter2"
    end
  end
end
