defmodule Cooper.Conformance do
  @moduledoc """
  This implementation's adapter for the Cooper Conformance Suite: a JSON
  request in, a JSON answer out (`mix cooper.conformance REQUEST ANSWER`).

  The suite (`libs_prx/cooper_conformance` in the Praxis repository,
  run by its `assize` library) holds every CASC implementation to the
  same cases. Each case asks for one operation, `load`, on a document
  file; this answers with the loaded configuration in the suite's typed
  JSON, or with the category (CASC.md §9.5) of the error that refused
  it.

  ## What every adapter loads with

  The suite fixes the environment and the extension points, so a case
  can use them and every implementation sees the same: the variables in
  `@env`, no `.env` file, the document's own directory as the root, the
  resolvers `echo` (answers its payload) and `fail` (refuses), the tag
  `twice` (doubles an integer, repeats a string) and the import scheme
  `mem:` (`mem:base`, `mem:vars`).

  ## Values

  Every value travels in the suite's typed JSON: `{"integer": "42"}`,
  `{"float": "2.0"}`, `{"keyword": "info"}`, `{"tuple": [...]}`,
  `{"map": [[key, value], ...]}`, arrays, and strings, booleans and
  `null` as they are. What CASC has and Praxis notation has no literal
  for is a tuple tagged with a dotted keyword -- `casc.duration`,
  `casc.bytes`, `casc.secret`, `casc.module`, `casc.float`,
  `casc.ipv4`, `casc.ipv6`, `casc.date`, `casc.time`,
  `casc.local-date-time`, `casc.date-time` -- which no CASC atom can be,
  so a tag never reads as a tuple a document wrote.
  """

  @env %{
    "REGION" => "eu-west",
    "PORT" => "9090",
    "DEBUG" => "true",
    "EMPTY" => "",
    "LIST" => "a, b;c",
    "SCHEME" => "HTTPS://",
    "PADDED" => "  padded  ",
    "TOKEN_1" => "tok-one",
    "TOKEN_2" => "tok-two",
    "FEATURE" => "on",
    "WHICH" => "dev",
    "FORMATTER" => "Foo.Bar",
    "COOPER_ENV" => "conformance"
  }

  @mem %{
    "base" => "#@version = 1\nfrom_mem = true\nshared = \"mem\"\n",
    "vars" => "#@version = 1\n@mem_var = \"from-mem\"\n"
  }

  @doc """
  Reads the request at `request_path` and writes the answer to
  `answer_path`.

  `:ok`, or `{:error, reason}` when the request cannot be read or the
  answer cannot be written. A case that fails is an answer, not an
  error.
  """
  @spec run(Path.t(), Path.t()) :: :ok | {:error, term()}
  def run(request_path, answer_path) do
    with {:ok, text} <- File.read(request_path),
         {:ok, request} <- JSON.decode(text) do
      File.write(answer_path, JSON.encode!(answer(request)))
    end
  end

  @doc """
  The answer to a decoded request: one result per case, in order.
  """
  @spec answer(map()) :: map()
  def answer(%{"cases" => cases}) when is_list(cases) do
    %{"results" => Enum.map(cases, &result/1)}
  end

  @doc """
  `value`, as this implementation holds a loaded configuration, in the
  suite's typed JSON.
  """
  @spec encode(term()) :: term()
  def encode(value) when is_nil(value) or is_boolean(value) or is_binary(value), do: value
  def encode(n) when is_integer(n), do: %{"integer" => Integer.to_string(n)}
  def encode(f) when is_float(f), do: %{"float" => Float.to_string(f)}
  def encode(:infinity), do: tagged("casc.float", ["inf"])
  def encode(:neg_infinity), do: tagged("casc.float", ["-inf"])

  # A module built by `!module(...)` (§7.5) is an atom with Elixir's
  # prefix, which no CASC atom can carry; it travels by the name CASC
  # wrote, so every implementation compares the name rather than its
  # host's value.
  def encode(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> written -> tagged("casc.module", [written])
      name -> %{"keyword" => name}
    end
  end

  def encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  def encode({:duration, ns}) when is_integer(ns), do: tagged("casc.duration", [encode(ns)])
  def encode({:bytes, n}) when is_integer(n), do: tagged("casc.bytes", [encode(n)])
  def encode(%Cooper.Secret{value: v, redacted: nil}), do: tagged("casc.secret", [encode(v)])

  def encode(%Cooper.Secret{value: v, redacted: shown}),
    do: tagged("casc.secret", [encode(v), shown])

  def encode(%Cooper.IPv4{} = ip), do: tagged("casc.ipv4", [to_string(ip)])
  def encode(%Cooper.IPv6{} = ip), do: tagged("casc.ipv6", [to_string(ip)])
  def encode(%Date{} = d), do: tagged("casc.date", [Date.to_iso8601(d)])
  def encode(%Time{} = t), do: tagged("casc.time", [Time.to_iso8601(t)])

  def encode(%NaiveDateTime{} = t),
    do: tagged("casc.local-date-time", [NaiveDateTime.to_iso8601(t)])

  def encode(%DateTime{} = t), do: tagged("casc.date-time", [DateTime.to_iso8601(t)])
  def encode(t) when is_tuple(t), do: %{"tuple" => t |> Tuple.to_list() |> Enum.map(&encode/1)}

  def encode(%{} = map) when not is_struct(map) do
    %{"map" => map |> Enum.sort() |> Enum.map(fn {k, v} -> [encode(k), encode(v)] end)}
  end

  defp tagged(tag, items), do: %{"tuple" => [%{"keyword" => tag} | items]}

  defp result(%{"id" => id, "operation" => "load", "document" => path}) do
    case Cooper.load_file(path, options(Path.dirname(path))) do
      {:ok, value} -> %{"id" => id, "result" => encode(value)}
      {:error, error} -> %{"id" => id, "error" => category(error)}
    end
  rescue
    # A crash is this implementation's failure on this case, answered as
    # such: the suite reports it as a disagreement rather than losing
    # every other case's answer with it.
    e -> %{"id" => id, "error" => "crash: " <> Exception.message(e)}
  end

  defp result(%{"id" => id} = asked) do
    %{"id" => id, "error" => "unknown operation: #{inspect(asked["operation"])}"}
  end

  defp category(%{stage: stage}), do: to_string(stage)
  defp category([first | _]), do: category(first)
  defp category(other), do: "unknown: " <> inspect(other)

  defp options(root) do
    [
      env: @env,
      dotenv: false,
      cache: false,
      root: root,
      resolvers: %{
        "echo" => fn payload -> {:ok, payload} end,
        "fail" => fn payload -> {:error, "refused #{payload}"} end
      },
      tags: %{
        "twice" => fn
          n when is_integer(n) -> {:ok, n * 2}
          s when is_binary(s) -> {:ok, s <> s}
          other -> {:error, "cannot double #{inspect(other)}"}
        end
      },
      import_schemes: %{
        "mem" => fn rest ->
          case Map.fetch(@mem, rest) do
            {:ok, source} -> {:ok, source}
            :error -> {:error, :enoent}
          end
        end
      }
    ]
  end
end
