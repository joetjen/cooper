# CASC Configuration Format (CASC)

## 1. Overview

CASC is a hierarchical configuration language that combines:

- **Assignments** (`key = value`, or `key value` — the operator is optional, §5.3) and **blocks** (`{ ... }`), which double as CASC's only map type (§5.4)
- **Dotted paths** (`a.b.c = 1`) as sugar for nested blocks; `key { ... }` (no operator) is sugar for `key = { ... }` — all forms desugar to the same tree before merge (§5.4)
- **Imports** (`import "path/**/*.casc"`), including consumer-defined import sources via URI scheme (`import "vault://..."`, §9.3)
- **Variables** (public `@name`, private `@*name`, §5.2), including block-scoped loop variables (§5.5)
- **Three brace-delimited sigils**: variables (`@{...}`, §7.1), environment expansion (`${...}`, bash-like, §7.2), config references (`%{...}`, §7.3)
- **Extensible resolution** (`!{resolver:arg}`, §7.4) and **tagged values** (`!Name(...)`, §7.5) for consumer-defined vocabulary — unregistered use of either always fails loudly (§9.4)
- **Lists** (`[...]`) and **tuples** (`(...)`) — tuples are fixed-arity and never merged, only replaced wholesale (§6.11, §8.3)
- **Native duration** (`5ms`, `1h30m`, §6.8) and **byte-size** (`512MiB`, `10GB`, §6.9) literals — decimal (SI, powers of 10) vs. binary (IEC, powers of 2)
- **Secret keys** (`*password = ...`) for consumer-side redaction (§4.3)
- **Merge control sigils** (`~key`, `+key`, `-key`) overriding default merge behavior per key (§5.7, §8.4)
- A **loop** construct (`for ... [from ...] as ... { ... }`) generating repeated structure from one or more parallel-iterated lists (§5.5)
- One **comment** marker (`# ...`), deliberately shared with the version header and with disabling a statement (§3.2, §5.6)

This document defines CASC at the language/spec level; implementations may add conveniences but must not break the syntax described here.

**Result values in this document are shown as native Elixir terms**: maps use string keys (`%{"key" => value}`), CASC atoms become Elixir atoms (`:info`), CASC tuples become real Elixir tuples (`{...}`). Where a result has many uniform entries, it's shown in [TOON](https://github.com/toon-format/spec) instead, for density.

---

## 2. Mandatory header

Every CASC file **must** begin with a version header, as the first non-blank, non-comment statement:

```casc
#@version = <version>
```

The operator is optional here like everywhere else (§5.3); `#@version = <version>` is the recommended spelling. `<version>` should follow SemVer 2.0, e.g. `1`, `1.0`, `1.0.0`, `2.1.3`.

---

## 3. Lexical structure

### 3.1 Whitespace

Spaces, tabs, and newlines separate tokens. Newlines end statements, except where a value spans multiple lines (triple-quoted strings, backslash continuation, §6.5).

### 3.2 Comments

```casc
# a line comment, runs to end of line
```

No multi-line comment syntax exists. `#` serves three related purposes, sharing one character deliberately — all three are "treat what follows differently, based on what comes right after `#`":

1. **A plain comment** — `#` followed by whitespace or anything other than a letter, `@`, or `*`.
2. **The version header** (§2) — `#@version ...`, only as the file's first non-blank statement.
3. **A disabled statement** (§5.6) — `#` followed directly by a letter or `*`, anywhere else (`#key = 1`, `#*key { ... }`, `#@name = 1`).

This is a hard lexical rule: `#TODO` (no space) is a disabled-statement attempt, not a comment, and fails to parse unless `TODO` happens to be valid statement syntax. `# TODO` (space) is unambiguously a comment.

---

## 4. Identifiers and naming rules

### 4.1 Key names, atoms, and variable names

`/^[a-zA-Z][a-zA-Z0-9_+-]*[?!]?$/` — mixed case, underscores, hyphens, digits, `+`, optionally ending `?` or `!`.

Examples: `logger`, `handleOtpReports`, `handle-otp-reports`, `enabled?`, `ready!`, `MyApp`.

`for`, `in`, `from`, `as` (§5.5) are **contextual** keywords — special only inside a `for` statement, ordinary identifiers everywhere else. This differs from the six reserved words in §6.4 (`nil`, `true`, `false`, `inf`, `+inf`, `-inf`), which are reserved everywhere.

### 4.2 Quoted key segments

A key segment may be written as a string, for text that doesn't fit the identifier rule — spaces, punctuation, arbitrary content:

```casc
headers = {
  "Content-Type" = "application/json"
}

foo."bar baz".dronf = "fnord"
```

Double-quoted key segments support interpolation and escapes, same as double-quoted strings (§6.5). Single-quoted key segments are literal, same as single-quoted strings. Bare identifier keys cannot be interpolated (§4.1's rule has no room for `@{}`), so an interpolated key must be double-quoted.

An interpolated segment must resolve to a non-empty string with no `.` in it (a written-out `"a.b"` is one segment; a `.` that arrives through interpolation would silently be read as two), and may not be built from a secret (§7.2). The rule is the same inside a `for` loop (§5.5), where the segment is built from a binding, as outside one.

### 4.3 Secret keys

Any key segment may be prefixed `*` to mark it **secret**: `*password = "..."`, `db.*password = "..."`, `*db.password = "..."`. The stored value is unaffected; consumers should redact secret values on display (e.g. `"[~~REDACTED~~]"`).

---

## 5. Statements

A CASC file is a sequence of statements: imports, variable declarations, assignments, blocks, loops, blank lines. Statements may be **disabled** (§5.6) and may carry a **merge control sigil** (§5.7) — both are prefix modifiers, not separate statement kinds.

### 5.1 Imports

```casc
import "path/to/file.casc"
import "config/{base,dev}/**.casc"
import "vault://secret/base"
```

1. **No `scheme://` prefix** — resolves relative to the current file. Brace (`{a,b}`) and glob (`**.casc`) patterns expand against the filesystem; matches load in lexicographic order.
2. **`scheme://` prefix** — dispatched entirely to the loader registered for that scheme (§9.3); expansion, ordering, and path meaning are that loader's to define. An unregistered scheme is a load-time error naming it (§9.4).
3. **Merge**: later imports override earlier ones for the same path, per §8.
4. **A path may interpolate `${NAME}` or `${NAME:default}`** (§7.2), which is how one document selects among several:

   ```casc
   import "env/${COOPER_ENV}.casc"
   ```

   Only `${...}` works. An import is resolved *while the document is parsed* — the imported file's statements are spliced into the importer — so a reference needing the finished tree (`%{...}`, §7.3) cannot be available yet and is a load-time error. The environment is available, which is the same thing `${?NAME}` reads (§7.2).

   Unset and empty are treated alike, as everywhere else. An unset variable **without** a default is an error rather than an empty segment, since a path that silently became `env/.casc` would import the wrong file or none.

### 5.2 Variable declarations

```casc
@name = "value"       # public
@*private = "value"   # private, file-local
```

Operator optional, per §5.3.

**Visibility.** A **public** `@name` belongs to the whole load, not to
the file that wrote it. It is visible to the files that import that file
(transitively), *and* to the files that file imports — so an entry
document can declare a value before its imports and have every imported
file see it:

```casc
# app.casc
@service = "checkout"
import "inc/telemetry.casc"   # sees @{service}

# inc/telemetry.casc
telemetry.service_name = "@{service}"
```

A **private** `@*name` is usable anywhere inside the file that declares
it and nowhere else. It never reaches an importer, and it is never
visible to a file it imports. Two files may each declare an unrelated
`@*name` without colliding, and inside its own file a private
declaration shadows a public one of the same name.

Because visibility is decided per *file*, and the last file to assign a
public name wins, prefer `@*name` for anything a file only needs for
itself — a public name is effectively part of the load's shared surface.

### 5.3 Assignments

`=` is the assignment operator, and **optional**:

```casc
foo = "bar"
foo "bar"
```

Both are fully equivalent; an implementation must accept both. `=` is recommended for readability, never required. `:` has no assignment role — it's reserved solely for the atom sigil (§6.4).

This is unambiguous because a key path only continues via a literal `.` (§5.4): once whitespace appears with no `.` following, the key is finished, and whatever comes next — `=`, `{`, or a value — can only be read one way.

### 5.4 Key paths and blocks

```casc
logger.console.colors.enabled = true

logger {
  level = info
  console { colors.enabled = true }
}
```

**Dotted paths, nested blocks, and explicit `= { ... }` are fully equivalent — the same tree, not just similar.** `key { ... }` is sugar for `key = { ... }`; combined with the optional operator, these all produce the identical structure:

```casc
foo { bar { baz = "dronf" } }
foo { bar.baz "dronf" }
foo = { bar = { baz = "dronf" } }
foo.bar.baz "dronf"
```

**Result** (identical for all four):

```elixir
%{"foo" => %{"bar" => %{"baz" => "dronf"}}}
```

Desugaring to the canonical tree always happens *before* merge (§8) — a correctness requirement, not convenience: `foo.bar.baz = 1` in one file and `foo = { bar = { qux = 2 } }` in another must merge into one `foo.bar` with both keys, regardless of surface form.

Allowing three equivalent forms — rather than picking one, as TOML does — is a deliberate readability tradeoff: a deep config often reads better as dotted paths, a config with many siblings often reads better as a block. Consistency across a codebase is left to tooling (a formatter), not enforced by the grammar.

**Block keys may be identifier-shaped (§4.1) or quoted strings (§4.2)** — so a block with quoted keys already covers what a separate "map" type would. **There is no separate map syntax in CASC; a block in value position is a map, however its keys are written.**

**An empty block is an empty map**: `logger {}` and `logger = {}` both make `logger` a map with nothing in it. Like any block it merges, so written over a map that already exists it adds nothing and leaves that map as it is; `~logger {}` empties it.

### 5.5 Loops

```casc
for <binding> [, <binding>]* [from <template-path>] as <destination-path> {
  <body>
}
```

**Bindings**, comma-separated, each one of:

- `@name` — **index binding**: the current iteration number (`0, 1, 2, ...`). At most one per loop; not itself iterable, takes no `in`.
- `@name in <iterable>` — **element binding**: the current element of `<iterable>` (typically `@{...}` or `%{...}`, resolving to a list).

At least one element binding is required — an index-only loop is a load-time error.

With more than one element binding, iteration is **parallel (zipped), not a nested cartesian product**: iteration *n* uses index *n* of every bound list. This favors the common "N parallel lists describe N generated things" shape over an explosion of every combination. All element-bound lists **must share the same length** — a mismatch is a load-time error naming each list and its actual length, never a silent truncation.

**`<destination-path>`** is an ordinary key path (§5.4), evaluated per iteration, and may use interpolated segments (§4.2) built from the bindings — any segment may be dynamic, not just a fixed trailing one.

**`from <template-path>`** (optional) — each generated destination starts as a copy of the value at `<template-path>`, with the loop body's statements applied as overrides on top (§8). `<template-path>` is a bare key path, resolved **lazily against the fully-merged final tree**, same timing as `%{...}` (§7.3).

**Scope** — loop-bound variables are ordinary `@name` variables (§7.1), scoped to the body: they shadow any outer variable of the same name for that scope only, and cease to exist once the loop ends.

**Example:**

```casc
@domains = ["us-east.example.com", "eu-west.example.com"]
@ports = [8443, 8444]

for @idx, @domain in @{domains}, @port in @{ports} as endpoints."domain-@{idx}" {
  url = "https://@{domain}:@{port}"
}
```

**Result:**

```toon
endpoints[2]{name,url}:
  domain-0,https://us-east.example.com:8443
  domain-1,https://eu-west.example.com:8444
```

(Mismatched `@domains`/`@ports` lengths would be a load-time error naming both lists, not two endpoints and a dropped port.)

**Example, with `from`:**

```casc
defaults.replica {
  cpu = 1
  memory_mb = 512
}

@instances = ["a", "b", "c"]
for @instance in @{instances} from defaults.replica as replicas."@{instance}" {
  cpu = 2
}
```

**Result:**

```toon
defaults.replica: {cpu: 1, memory_mb: 512}

replicas[3]{name,cpu,memory_mb}:
  a,2,512
  b,2,512
  c,2,512
```

### 5.6 Disabled statements

Prefixing a statement with `#` directly before its key (or before another leading sigil, §5.7) disables it entirely — syntactically valid, but produces nothing:

```casc
section {
  #ignored = 1
  #sub { remove = yes }
  kept = true
}
```

**Result:**

```elixir
%{"section" => %{"kept" => true}}
```

`ignored` and `sub` are absent, not present-but-null. Distinct from a `#` comment (§3.2) because the rest of the line can still look like a valid statement.

### 5.7 Merge control sigils and sigil ordering

Blocks/maps deep-merge and lists replace by default (§8 has full rationale). Three sigils override this per key, in the same leading position as `*` and `#`:

- **`~key { ... }`** — force **replace** instead of merge, for a block/map.
- **`+key = [...]`** — **append** to an existing list. Behaves like a plain assignment if `key` doesn't exist yet.
- **`-key = [...]`** — **remove** matching elements from an existing list.
- **`-key.path`** (bare, no value) — **delete** the path entirely, any type.

A bare `-key.path` followed by another complete statement is always the delete — `-feature.legacy_mode` on one line and `c = 1` on the next is a delete and an assignment, never the remove `-feature.legacy_mode = c` (statements are not newline-terminated, so without this rule the operator being optional, §5.3, would make the next line's key the remove value). Write the remove form with its `=` (`-tags = b`) where its value is itself a bare word that could start a statement.

`+`/`-` (list form) apply only to lists — using either against a tuple is a load-time error (§8.3), since it would silently change the tuple's fixed arity.

**Sigil ordering** — `#`, then merge-control (`~`/`+`/`-`), then `*`, directly before the key, no separators:

```casc
~*database { host = "db.internal", password = "hunter2" }
#~*database { host = "db.internal", password = "hunter2" }
```

The first replaces (not merges) `database` wholesale and marks it secret; the second is the same statement, disabled. `#` always comes first when present — a disabled statement produces nothing, so nothing downstream has anything left to act on.

---

## 6. Values

### 6.1 Nil

`nil`

### 6.2 Booleans

`true`, `false`

### 6.3 Numbers

- Integers: `-17`, `0`, `+99`
- Hex/octal/binary: `0xDEAD_BEEF`, `0o755`, `0b11010110`
- Floats: `3.1415`, `-0.01`
- Exponent: `5e+22`, `-2E-2`
- Digit separators: `_` between digits
- Infinity: `inf`, `+inf`, `-inf`

### 6.4 Atoms

Bare identifiers, same naming rule as keys:

```casc
level = info
remove = yes
```

**Reserved words take precedence over the atom rule** — `nil`, `true`, `false`, `inf`, `+inf`, `-inf` are always their literal meaning (§6.1–6.3), never bare atoms, even though they're valid identifiers under §4.1.

**An atom may optionally carry a leading `:`** (Ruby/Lisp/Elixir convention) — required to *reach* an atom named one of the six reserved words, optional everywhere else:

```casc
level = :info    ; identical to `level = info`
mode = :inf       ; the atom inf -- NOT infinity
```

**`:nil`, `:true` and `:false` are the values `nil`, `true` and `false`.** On the reference implementations' runtime those three atoms *are* the three values, so there is no separate atom for a document to reach; an implementation on a runtime that tells them apart produces the value too, so that a document means one thing everywhere. `:inf` is an ordinary atom.

Keeping them as atoms distinct from the values was tried and dropped. It took a wrapper on the BEAM (`:true` *is* `true` there), so those three spellings came back as something no other atom is, and a document's meaning still depended on which implementation read it — the opposite of what the distinction was for.

`:` has no other meaning in CASC — not an assignment operator (§5.3), and appears nowhere else in the grammar.

### 6.5 Strings

- **Double-quoted** — escapes (`\n`, `\r`, `\t`, `\"`, `\\`, `\uXXXX`) and interpolation (§7).
- **Single-quoted** — literal, no escapes, no interpolation.
- **Triple-quoted** (`""" ... """`) — multi-line; the smallest common leading whitespace across non-empty lines is stripped from each line.
- **Backslash-continued** — a bare value starting with `\` at end-of-line joins onto the next line, dropping the line break.

**Example:**

```casc
motd = """
    Welcome to the service.
    Status: operational
    """
```

**Result:**

```elixir
%{"motd" => "Welcome to the service.\nStatus: operational\n"}
```

### 6.6 Dates and times

ISO-8601-like: offset datetime (`1979-05-27T07:32:00Z`), local datetime (`1979-05-27T07:32:00`), local date (`1979-05-27`), local time (`07:32:00`), all with optional fractional seconds.

### 6.7 IP addresses

IPv4/IPv6, optionally with CIDR: `127.0.0.1/32`, `::1/128`.

### 6.8 Durations

A number immediately followed by a unit, no whitespace between. Units, lowercase: `ns`, `us`/`µs`, `ms`, `s`, `m`, `h`, `d`.

```casc
timeout = 500ms
cache_ttl = 1h30m
```

A single-unit literal may be fractional (`1.5h`); a compound literal (multiple units concatenated) requires each component to be a plain integer, strictly descending, no unit repeated — `1h30m` is valid, `30m1h` is not. Digit separators (`_`) are allowed per §6.3.

**Result** (`timeout` above, illustrating the resolved shape — the exact tag/base-unit is implementation-defined):

```elixir
%{"timeout" => {:duration, 500_000_000}}
```

Also reachable as a tagged value (§7.5) — `!duration("5m")` — for computed/interpolated values; the bare literal is recommended when static.

### 6.9 Byte sizes

A number immediately followed by a unit, no whitespace. Matching is case-insensitive; an `i` right after the magnitude letter (before `B`) signals binary, its absence decimal.

- Decimal (SI, ×1000): `B`, `kB`, `MB`, `GB`, `TB`, `PB`
- Binary (IEC, ×1024): `KiB`, `MiB`, `GiB`, `TiB`, `PiB`

```casc
memory_limit = 512MiB
disk_quota = 10GB
```

The numeral may be fractional (`1.5GiB`).

**Result** (`memory_limit` above):

```elixir
%{"memory_limit" => {:bytes, 536_870_912}}
```

Also reachable as `!bytes("512MiB")` (§7.5), for computed/interpolated values.

### 6.10 Lists

```casc
list1 = ["a", "b", "c"]
list2 = [
  "a"
  "b"
]
```

Comma, newline, or whitespace all separate elements.

**An element may be a block** — a map, written exactly as a block is anywhere else (§5.4), keys interpolating and statements merging inside it:

```casc
access_control = [
  { path = "^/admin", roles = ["ROLE_ADMIN"] }
  { path = "^/api",   roles = ["ROLE_API"] }
]
```

The same holds for a tuple's elements (§6.11). A list of maps is still a list: it replaces wholesale (§8.2), and `+`/`-` append or remove whole maps, compared by value (§8.4).

### 6.11 Tuples

Parentheses — chosen to avoid colliding with blocks, which already own `{ ... }` (§5.4) as both structure and map type:

```casc
office_location = (52.5200, 13.4050)
```

**Result:**

```elixir
%{"office_location" => {52.52, 13.405}}
```

A genuine, fixed-arity Elixir tuple — not a list. Arity is fixed at parse time and is part of the value: a tuple is never merged element-wise or appended to, only replaced wholesale by a later statement (§8.3). An implementation must carry a real tuple type through parsing, merging, and the final returned value.

Comma, newline, or whitespace separate elements, same as lists. `;` and `|` are reserved for splitting environment-variable strings into lists (§7.2), not for tuples.

---

## 7. Interpolation and references

Three brace-delimited sigils, plus two extensibility mechanisms sharing the same shape (§9).

**A value interpolated into a string reads as CASC writes it:** `nil`, `true`, `false`, `inf`, `-inf`; an atom as its name; a duration in nanoseconds (`500000000ns`) and a byte size in bytes (`2048B`); an IP address or network as written in canonical form; a float as the shortest digits that read back as the same float, written as a plain decimal or with an exponent, whichever is shorter (the decimal on a tie), and always with a fraction (`1.0`, `52.52`, `100.0`, `0.0001`, `1.0e3`, `1.0e-5`). A list, a tuple or a map has no string form, and interpolating one is a load error.

### 7.1 Variables

`@name = value` (§5.2) or a loop binding (§5.5) **defines** a variable; **referencing** one — standalone, in a string, or inside another sigil — always uses `@{name}`. There is no bare `@name` reference form.

- `@{name}`
- `@{name:default}` — default if undefined
- `@{name:+alt}` — substitute `alt` if defined (any value), else empty string
- `@{name:?"message"}` — fail loading with `message` if undefined
- `@{name[i]}`, `@{name[i]:default}` — index into a list-valued variable
- `@{name | filter}` — normalize the resolved value (§7.2)

Private variables (`@*var`) are visible only in the declaring file. Loop-bound variables are visible only in their loop's body, shadowing any outer variable of the same name for that scope.

### 7.2 Environment expansion

Deliberately bash-like. Names match `/^[a-zA-Z_][a-zA-Z0-9_]*$/`.

- `${NAME}`
- `${NAME:default}` — default if unset/empty
- `${NAME:+alt}` — substitute `alt` if set, else empty string
- `${NAME:?"message"}` — fail loading if unset
- `${?NAME}` — skip the whole statement if unset/empty
- `${NAME[]:[...]}` — parse as a list (split on `,`/`;`), with a default
- `${NAME[i]:default}` — index into the split list

**`${COOPER_ENV}` names the current environment** in every implementation, so one document selects per-environment files the same way everywhere: `import "env/${COOPER_ENV}.casc"`. The names are `dev`, `staging`, `test` and `prod`. A real `COOPER_ENV` always wins and is used exactly as written; unset or empty, each implementation falls back to its host's own variable (`MIX_ENV`, `PRX_ENV`, `APP_ENV`, `NODE_ENV`), else `dev`, and maps that value onto the shared names through one table:

| Host value | `COOPER_ENV` |
|---|---|
| `development`, `local` | `dev` |
| `testing` | `test` |
| `production` | `prod` |
| anything else (`dev`, `staging`, `test`, `prod`, ...) | unchanged |

**`${...}` always resolves to a string.** For a number or boolean, wrap it in the matching tagged value (§7.5) rather than relying on CASC to guess:

```casc
port = !int(${PORT:8080})
debug = !bool(${DEBUG:false})
```

This is deliberate, not an oversight: guessing a type from what a string looks like is exactly the kind of implicit behavior that produces surprises, so CASC never does it silently.

**Note:** real bash uses `${NAME:-default}` (with a dash); CASC drops it so the suffix grammar (`:default`, `:+alt`, `:?"msg"`) is identical across `@{...}`, `${...}`, and `%{...}` — one rule, not three near-identical ones.

`:+` always introduces a substitute, so `${PORT:+1}` substitutes `1` and `${PORT:+inf}` substitutes infinity; a default of minus one is `${PORT:-1}`, and of minus infinity `${PORT:-inf}`. The message of `:?"..."` is a double-quoted string like any other and interpolates: `@{n:?"need @{m}"}` fails with `need` followed by `@{m}`'s value.

#### Filters

A reference may be followed by one or more `| filter` clauses, which normalize the resolved string. Like the suffix grammar, this is **one rule shared by all three reference forms** — `@{...}`, `${...}`, and `%{...}` — not three near-identical ones.

- `${NAME | trim}` — strip leading and trailing whitespace
- `${NAME | downcase}`, `${NAME | upcase}` — change case
- `${NAME | trim_prefix: "..."}`, `${NAME | trim_suffix: "..."}` — strip an affix if present

Filters apply **after** the suffix has settled, left to right, so a filter always sees the value that will actually be used — whether that came from the reference or from its default:

```casc
scheme = ${SCHEME | trim_suffix: "://" | downcase}
region = ${REGION:"  us-east-1  " | trim}
```

An argument may be double- or single-quoted. Single quotes exist so a filter remains usable *inside* an interpolated string, where a double-quoted argument has no way to nest:

```casc
endpoint = "${SCHEME | trim_suffix: '://'}://%{host}"
```

Filters normalize; they do not convert. A filter applied to a non-string is a load-time error rather than a silent coercion, an unknown filter name is a load-time error naming it, and so is an argument given to a filter that takes none (or omitted from one that requires it). To change a value's *type*, use a tagged value (§7.5).

**Example**, `REGION=eu-west` set, others unset:

```casc
region = ${REGION}
max_retries = !int(${MAX_RETRIES:3})
${?FEATURE_FLAG}
enabled = true
allowed_hosts = ${ALLOWED_HOSTS[]:["localhost"]}
```

**Result** (`enabled` is skipped entirely, guarded by `${?FEATURE_FLAG}`):

```elixir
%{"region" => "eu-west", "max_retries" => 3, "allowed_hosts" => ["localhost"]}
```

#### Built names

A reference's **name** may be built by interpolation instead of written
out, by giving it as a double-quoted string:

```casc
@which = "HOST"
host = ${"APP_@{which}"}     # reads APP_HOST
```

This exists for one thing a document otherwise cannot do at all: follow
a deployment convention of one variable per tenant. CASC reads *named*
variables and has no way to enumerate the environment, so without it a
set like `TOKEN_1`, `TOKEN_2`, … can only be written out one line at a
time. With a loop (§5.5) it becomes a list of ids:

```casc
@supervisor_ids = ["1", "2", "3"]

for @id in @{supervisor_ids} as tokens {
  "@{id}" = ${"TOKEN_@{id}"}
}
```

```elixir
%{"tokens" => %{"1" => "tok-one", "2" => "tok-two", "3" => "tok-three"}}
```

The same applies to `@{"..."}` and to a `%{...}` path segment
(`%{tokens."supervisor-@{id}"}`).

This is interpolation — the concatenation the language already has,
pointed at the name — not a new expression form. There is deliberately
no concatenation operator, for the same reason the filter set is closed:
that road ends at an expression language, and this is a config format.

Three rules:

- A built `${...}`/`@{...}` name must resolve to an identifier
  (`[A-Za-z_][A-Za-z0-9_]*`), so a built name and a written-out one are
  interchangeable. A `%{...}` key needn't — keys are quoted and may
  contain anything but a `.`, which would silently split the path.
- A name or key may not be built from a **secret**. Names appear in
  error messages, which do not redact.
- Only the **bare** form may be built. A reference nested inside a
  larger string keeps a plain name: its token ends at the first `}`, so
  a nested `@{...}` would truncate it — the same scope trim the reduced
  `:default` grammar already has in that position.

### 7.3 Config references

- `%{path}`
- `%{path:default}`
- `%{path[i]}`, `%{path[i]:default}`
- `%{path | filter}` — normalize the resolved value (§7.2)

`path` follows the dotted key-path rules (§5.4).

**Resolves lazily, against the fully-merged final tree** — after every import, merge, and override sigil (§8), not eagerly per-file. A reference tracks a value "wherever it ends up," independent of import order: if a later import replaces the whole `tls` block via `~tls { ... }`, `%{tls.min_version}` resolves to the replacement's value even if written in an earlier-processed file.

**Cycle detection is required.** `%{a}` referencing something that transitively contains `%{a}` again must fail at load time with the cycle path in the error — never loop forever or silently return a partial value.

**Example:**

```casc
server.host = "api.internal"
server.port = 8080
health_check.url = "http://%{server.host}:%{server.port}/health"
admin_email = %{contact.admin:"ops@example.com"}
```

**Result** (no `contact.admin` defined):

```elixir
%{
  "server" => %{"host" => "api.internal", "port" => 8080},
  "health_check" => %{"url" => "http://api.internal:8080/health"},
  "admin_email" => "ops@example.com"
}
```

### 7.4 Extensible resolution

`!{resolver:payload}` dispatches to a consumer-registered resolver named `resolver`, passing `payload` through. The **first** `:` splits name from payload; everything to the matching closing `}` is the payload verbatim, brace-balanced.

```casc
*password = !{vault:secret/db/password}
```

Giving `vault` meaning is entirely the consumer's job. An unregistered resolver name is a load-time error naming it (§9.4, §9.2).

### 7.5 Tagged values

`!Name(argument)` constructs a value of type `Name` from one argument (typically a string). Parsing only needs to recognize "a tag plus one parenthesized argument" — giving it meaning is the registered handler's job.

Built in: `!int`, `!float`, `!bool` (coercion, mainly for `${...}`, §7.2), `!duration`, `!bytes` (constructors for §6.8/§6.9), `!trim`, `!downcase`, `!upcase` (normalization), and `!module` (below). The normalizing tags do for a whole value what the matching filter (§7.2) does for one reference, and share its rule that a non-string argument is an error rather than a coercion. Anything else — e.g. `!uuid("...")` — is consumer-defined. An unregistered tag is a load-time error naming it (§9.4, §9.1).

**`!module("Name")`** names a module of the host language:

```casc
client_module = !module("ASCO.Redis.TestClient")
formatter = !module("${LOG_FORMATTER}")
```

It exists because §6.4's atoms are bare identifiers, so a dotted module name cannot be written as a literal — and because a module is often deployment-selected, which means it arrives through `${...}` as a string.

**A module name is written the same way for every implementation**: dot-separated segments, each in PascalCase (`[A-Z][A-Za-z0-9]*`). Anything else — `crypto`, `Foo.bar`, `stripe_client`, `./x.js` — is a load error, so a document that names a module means one module everywhere.

Each implementation resolves the name in two steps:

1. **The application's mapping**, a `modules` load option from written name to host module, consulted by the name *exactly* as written. It is how a module outside the convention is reached: an Erlang module from Elixir (`"Crypto" => :crypto`), a module whose own spelling differs, or any Node module.
2. **The host's convention**, for a name the mapping does not hold:

| Written | Elixir | Praxis | PHP | Node |
|---|---|---|---|---|
| `Acme.Payments.StripeClient` | `Acme.Payments.StripeClient` | `acme.payments.stripe-client` | `Acme\Payments\StripeClient` | mapping required |
| `Cooper.Resolver` | `Cooper.Resolver` | `cooper.resolver` | `Cooper\Resolver` | mapping required |
| `ASCO.HTTPClient` | `ASCO.HTTPClient` | `asco.http-client` | `ASCO\HTTPClient` | mapping required |

Praxis splits a segment into words before an upper-case letter that follows a lower-case letter or a digit, and before the last capital of a run of capitals followed by a lower-case letter (`HTTPClient` → `http`, `client`), then joins them lower-case with `-`. Node has no convention to translate into — a Node module is a location, not a name — so there a name the mapping does not hold is a load error naming the `modules` option.

No implementation checks at load that the module exists; the name is resolved, never loaded.

On the BEAM, like a bare atom literal, this creates an atom, with the same caveat: fine for a fixed, trusted set of configuration files, not for untrusted input.

---

## 8. Merge model

Merge operates on the fully-desugared tree (§5.4). Imports behave like "early writes," overridden by later imports and then the current file's own statements (§5.1); later statements override earlier ones for the same path. Each type's default is whichever behavior is safe without a schema:

### 8.1 Blocks and maps

**Deep-merge by default.** `a { b = 1 }` then `a { c = 2 }` produces both `a.b` and `a.c`, at every depth — safe, since merging two maps by key has one obvious meaning.

### 8.2 Lists

**Replace wholesale by default.** Merging positionally is well-defined but rarely intended; merging by identity requires knowing which field to key by, which CASC has no schema to supply. Replacing avoids guessing.

### 8.3 Tuples

**Always replace, never merge.** A tuple's fixed arity (§6.11) is part of its meaning; element-level append/remove would silently change it. None of `~`/`+`/`-` apply to a tuple-valued key — using any of them is a load-time error, not a silent no-op.

### 8.4 Overriding the default (sigils)

- `~key { ... }` — replace instead of merge.
- `+key = [...]` — append instead of replace (plain assignment if `key` doesn't exist yet).
- `-key = [...]` — remove matching elements instead of replace.
- `-key.path` (bare) — delete the path entirely, any type.

A list operand stands for its elements; anything else, `nil` included, is one element (`+tags = "d"` appends `"d"`, `+tags = nil` appends `nil`). Removal compares values strictly: `1` and `1.0` are different elements.

Ordering with `#`/`*` is fixed (§5.7).

**Example** — an earlier import established:

```casc
server { host = "0.0.0.0", port = 8080 }
tags = ["a", "b", "c"]
feature.legacy_mode = true
```

A later file writes:

```casc
~server { port = 9090 }
+tags = ["d"]
-tags = ["b"]
-feature.legacy_mode
```

**Result:**

```elixir
%{"server" => %{"port" => 9090}, "tags" => ["a", "c", "d"], "feature" => %{}}
```

`server` lost `host` (replaced, not merged); `tags` gained `"d"`, lost `"b"`; `feature.legacy_mode` is gone entirely, not `false`.

### 8.5 Deferred: merge-by-key

An explicit, opt-in merge-by-key for lists — e.g. `~items[id] = [...]`, matching elements by an `id` field, a CASC-native analogue of Kustomize's strategic merge patch. Deliberately out of scope for this version.

---

## 9. Extensibility

CASC's core grammar is intentionally small and frozen. Three points let a consuming application add its own vocabulary:

### 9.1 Tagged values

`!Name(...)` (§7.5) — the parser recognizes shape only, never meaning. `!int`/`!float`/`!bool`/`!duration`/`!bytes` are built in; anything else is consumer-registered.

### 9.2 Extensible resolvers

`!{resolver:payload}` (§7.4) — a named callback the consumer registers, receiving the payload verbatim. Mirrors Ichor's own `Actions` mechanism, rather than introducing a new architectural idea.

### 9.3 Extensible import sources

`import "scheme://..."` (§5.1) — dispatched to a consumer-registered loader for that scheme. A bare path always keeps filesystem-plus-glob/brace behavior; anything past the scheme, including whether expansion applies at all, is the loader's to define.

### 9.4 Failure semantics

**The rule underlying all three:** an unregistered tag, resolver, or import scheme is always a load-time error naming the offender — never silently ignored, never passed through as an opaque value. This keeps the core language small and predictable while staying genuinely open: consumers add vocabulary explicitly, and CASC never guesses at what an unrecognized extension point meant.

---

## 10. Minimal valid file

```casc
#@version = 1.0
```
