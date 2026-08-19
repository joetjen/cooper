# CASC Cheatsheet

Quick syntax lookup. See [CASC.md](CASC.md) for full explanations, or
the [tutorial](TUTORIAL.md) for a walkthrough.

## File skeleton

```casc
#@version = 1.0   ; required, must be the first non-blank/non-comment statement

# a line comment, runs to end of line

key = value        ; "=" is always optional -- "key value" works too
```

## Statements

| Syntax | Meaning |
|---|---|
| `key = value` / `key value` | assignment (§5.3) |
| `key { ... }` | block (sugar for `key = { ... }`, §5.4) |
| `a.b.c = value` | dotted path (sugar for nested blocks, §5.4) |
| `@name = value` | public variable declaration (§5.2) |
| `@*name = value` | private variable declaration -- file-local, never exported (§5.2) |
| `import "path"` | filesystem import, glob/brace patterns expand (§5.1) |
| `import "scheme://..."` | consumer-registered import loader (§5.1, §9.3) |
| `for ... as ... { ... }` | loop (§5.5) |
| `#statement` | disabled statement -- produces nothing (§5.6) |

## Sigil ordering (`#`, then `~`/`+`/`-`, then `*`, then the key)

| Sigil | Position | Meaning |
|---|---|---|
| `#key` | disable | statement produces nothing (§5.6) |
| `~key { ... }` | merge control | replace the whole subtree, not merge (§5.7/§8.4) |
| `+key = [...]` | merge control | append to an existing list (§5.7/§8.4) |
| `-key = [...]` | merge control | remove matching elements from an existing list (§5.7/§8.4) |
| `-key.path` | merge control | delete the path entirely, any type, no value (§5.7/§8.4) |
| `*key` | secrecy | mark this key (and everything under it) secret (§4.3) |

```casc
#~*database { host = "db.internal", password = "hunter2" }
```
`#` disabled, `~` replace, `*` secret, in that order, no separators.

## Values (§6)

| Syntax | Result |
|---|---|
| `nil` | `nil` |
| `true` / `false` | `true` / `false` |
| `-17`, `0`, `+99`, `0xDEAD_BEEF`, `0o755`, `0b1101`, `3.14`, `5e+22` | numbers, `_` allowed as a digit separator |
| `inf`, `+inf`, `-inf` | infinities |
| `info`, `:info` | atom `:info` (leading `:` optional except to reach a reserved word: `:true`, `:nil`, ...) |
| `"double quoted"` | string -- escapes + interpolation (§7) |
| `'single quoted'` | string -- literal, no escapes/interpolation |
| `"""triple\nquoted"""` | multi-line string, common leading whitespace stripped |
| `\` at end of line | backslash continuation -- joins onto the next line |
| `1979-05-27T07:32:00Z`, `1979-05-27`, `07:32:00` | date/time/datetime (§6.6) |
| `127.0.0.1`, `127.0.0.1/32`, `::1/128` | `%Cooper.IPv4{}` / `%Cooper.IPv6{}` (§6.7) |
| `500ms`, `1h30m` | `{:duration, nanoseconds}` -- units: `ns us µs ms s m h d`, descending, no repeats (§6.8) |
| `512MiB`, `10GB` | `{:bytes, count}` -- `Ki/Mi/Gi/Ti/Pi` = ×1024, no `i` = ×1000 (§6.9) |
| `["a", "b", "c"]` | list -- comma/newline/whitespace-separated |
| `(52.52, 13.405)` | tuple -- fixed arity, never merged, only replaced wholesale (§6.11) |

## Interpolation and references (§7)

| Sigil | Meaning | Timing |
|---|---|---|
| `@{name}` | variable reference (§7.1) | eager, per-file |
| `${NAME}` | environment variable, always a string (§7.2) | eager |
| `%{path}` | reference into the final merged tree (§7.3) | lazy, after merge |
| `!{resolver:payload}` | consumer-registered resolver dispatch (§7.4/§9.2) | resolve time |
| `!Name(arg)` | tagged value -- built-in or consumer-registered (§7.5/§9.1) | resolve time |

Shared suffix grammar across `@{}`/`${}`/`%{}`:

| Suffix | Meaning |
|---|---|
| `:default` | fall back to `default` if undefined/unset |
| `:+alt` | substitute `alt` if defined/set, else empty string |
| `:?"message"` | fail loading with `message` if undefined/unset |
| `[i]` | index into a list-valued variable/config path |

`${...}`-only extras:

| Syntax | Meaning |
|---|---|
| `${?NAME}` | guards the *one statement immediately following* -- skipped entirely if `NAME` unset/empty |
| `${NAME[]:[...]}` | parse `NAME` as a comma/semicolon-separated list, with a default |
| `${NAME[i]:default}` | index into the split list |

## Filters (§7.2)

| Filter | Effect |
|---|---|
| `\| trim` | strip leading and trailing whitespace |
| `\| downcase`, `\| upcase` | change case |
| `\| trim_prefix: "..."`, `\| trim_suffix: "..."` | strip an affix if present |

One rule shared by `@{...}`, `${...}` and `%{...}`, exactly like the
suffix grammar. Applied after the suffix settles, left to right, so a
filter always sees the value that will actually be used:

```casc
scheme = ${SCHEME | trim_suffix: "://" | downcase}
region = ${REGION:"  us-east-1  " | trim}
```

Single-quoted arguments exist so a filter stays usable inside an
interpolated string: `"${S | trim_suffix: '://'}://%{host}"`. Filters
normalize, they never convert -- a non-string is an error, not a
coercion. Use a tagged value to change a type.

## Built-in tagged values

`!int(arg)` `!float(arg)` `!bool(arg)` `!duration(arg)` `!bytes(arg)`
`!trim(arg)` `!downcase(arg)` `!upcase(arg)` -- always available, no
registration needed. `!duration`/`!bytes` produce the same
`{:duration, ns}` / `{:bytes, n}` shape as the bare literal forms
(§6.8/§6.9); the last three normalize a whole value the way the
matching filter normalizes one reference.

## Loops (§5.5)

```casc
for <binding> [, <binding>]* [from <template-path>] as <destination-path> {
  <body>
}
```

| Binding | Meaning |
|---|---|
| `@name` | index binding -- current iteration number, at most one per loop, no `in` |
| `@name in <iterable>` | element binding -- current element of an `@{}`/`%{}`-resolved list |

- Multiple element bindings iterate **in parallel** (zipped by index), never a cartesian product -- all bound lists must share the same length.
- `from <template-path>` copies that path's value as each iteration's base, resolved lazily against the *final* tree, same timing as `%{...}`.
- `<destination-path>` may use interpolated segments built from the loop's own bindings.
- Loop-bound variables are scoped to the body only.

## Merge model (§8)

| Type | Default | Override |
|---|---|---|
| Blocks/maps | deep-merge | `~key { ... }` replaces the whole subtree |
| Lists | replace wholesale | `+key`/`-key` append/remove elements |
| Tuples | replace wholesale | none -- `~`/`+`/`-` against a tuple is a load-time error |

Later statements (including a later import) override earlier ones at
the same path. `%{...}` always resolves against the *final*, fully
merged tree, regardless of where in the source the reference itself
was written.

## Identifiers (§4.1)

`/^[a-zA-Z][a-zA-Z0-9_+-]*[?!]?$/` -- mixed case, `_`/`-`/`+`, digits,
optional trailing `?`/`!`. `nil`/`true`/`false`/`inf`/`+inf`/`-inf` are
reserved everywhere (§6.4); `for`/`in`/`from`/`as` are reserved only
inside a `for` statement (§5.5), ordinary identifiers everywhere else.
A key segment that doesn't fit this rule (spaces, punctuation) must be
quoted: `"Content-Type" = "application/json"`.

## Common gotchas

- `#TODO` (no space) is a **disabled-statement attempt**, not a
  comment -- it fails to parse unless `TODO` happens to be valid
  statement syntax. `# TODO` (space) is unambiguously a comment (§3.2).
- `${...}` always resolves to a plain string -- wrap it in `!int(...)`/
  `!bool(...)`/etc. to get a typed value; CASC never guesses a type
  from what the string looks like (§7.2).
- A compound duration (`1h30m`) requires strictly descending,
  non-repeated, integer-only components -- `30m1h` and `1.5h30m` are
  both invalid (§6.8).
- `+`/`-` against a **tuple** is a load-time error, not a silent no-op
  -- only lists support append/remove (§6.11/§8.3).
- `%{...}`/`@{...}` cycles are a load-time error naming the full cycle
  path, never an infinite loop or a silently partial value (§7.1/§7.3).
- An unregistered `!Name(...)` tag, `!{resolver:...}` resolver, or
  `scheme://` import source is always a load-time error naming the
  offender -- never silently ignored (§9.4).
