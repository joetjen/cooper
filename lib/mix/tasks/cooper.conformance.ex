defmodule Mix.Tasks.Cooper.Conformance do
  @moduledoc """
  This implementation's adapter for the Cooper Conformance Suite.

      mix cooper.conformance REQUEST ANSWER

  Reads the suite's JSON request at `REQUEST` and writes the answer to
  `ANSWER` (`Cooper.Conformance`). Exits non-zero only when the request
  cannot be read or the answer cannot be written; a case that fails is
  an answer.
  """
  use Mix.Task

  @shortdoc "Answers a Cooper Conformance Suite request"

  @impl Mix.Task
  def run([request, answer]) do
    Mix.Task.run("app.start")

    case Cooper.Conformance.run(request, answer) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("cooper.conformance: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix cooper.conformance REQUEST ANSWER")
end
