defmodule Glider.Query do
  @moduledoc ~S"""
  Composable, Ecto-flavoured queries.

  Patterns stay Cypher — ASCII art is the clearest way to write a graph
  shape — while conditions, projections and ordering are Elixir expressions,
  checked when your code compiles. Values from your code are pinned with `^`,
  exactly as in Ecto, and always travel as `$` parameters, never spliced into
  the query text.

      import Glider.Query

      adults =
        match("(p:Person)")
        |> where(p.age >= 18)

      adults
      |> where(p.country == ^country)
      |> return(name: p.name, age: p.age)
      |> order_by(desc: p.age)
      |> limit(10)
      |> Glider.all(db)
      #=> [%{name: "Ada", age: 36}, ...]

  A query is a plain struct, so it can be built up in pieces, passed around
  and extended — every function takes a query and returns a new one.

  ## Clauses

  glider runs one clause after a `MATCH`, so a query takes at most one of
  `return/2`, `set/2`, `remove/2`, `delete/3` or `create/2` after its
  matches. Without any of them, a matching query returns `*`.

    * `match/2` - add a pattern (Cypher). Several are joined with commas.
    * `where/2` - add a condition. Several are joined with `AND`.
    * `return/2`, `distinct/1`, `order_by/2`, `skip/2`, `limit/2` - project.
    * `create/2` - create a pattern, alone or from what was matched.
    * `set/2`, `set_props/3`, `add_label/3`, `remove/2`, `remove_label/3`,
      `delete/3` - write.
    * `where_fragment/2` - a condition assembled at run time.
    * `call/2` - run a graph algorithm.
    * `explain/1` - show the plan instead of running.

  ## Expressions

  Inside `where/2`, `return/2`, `order_by/2` and `set/2`:

    * a bare name is a pattern variable (`p`), and `p.name` a property
    * `^value` pins an Elixir value as a parameter
    * `==`, `!=`, `<`, `<=`, `>`, `>=`, `and`, `or`, `not`, `+`, `-`, `*`, `/`
    * `x in ^list`, `is_nil(x)`, `not is_nil(x)`
    * `contains(a, b)`, `starts_with(a, b)`, `ends_with(a, b)`
    * glider's functions: `id/1`, `labels/1`, `type/1`, `degree/1`,
      `indegree/1`, `outdegree/1`, `length/1`, `lower/1`, `upper/1`, `abs/1`,
      `to_int/1`, `to_float/1`, `coalesce/n`
    * aggregates: `count/0` (all rows), `count/1`, `sum/1`, `avg/1`, `min/1`,
      `max/1`, `collect/1`
    * `fragment("raw ? cypher", ^value)` for anything else

  Literal strings in expressions are sent as parameters too, so there is no
  quoting to get wrong.

  ## Pattern parameters

  Patterns are strings, so they take `$name` parameters alongside:

      match("(p:Person {email: $email})", email: email)

  or build nodes and relationships with `vertex/3` and `edge/5`, which parameterise
  their properties for you:

      create(vertex(:p, "Person", %{name: "Ada", age: 36}))
  """

  defstruct match: [],
            where: [],
            action: nil,
            return: nil,
            shape: :list,
            distinct: false,
            order: [],
            skip: nil,
            limit: nil,
            call: nil,
            explain: false,
            params: %{},
            next: 1

  @type t :: %__MODULE__{}

  defmodule Fragment do
    @moduledoc """
    A piece of Cypher whose values are still Elixir terms. Parameter names are
    assigned when the fragment joins a query, so fragments compose without
    colliding.
    """
    defstruct parts: []
    @type t :: %__MODULE__{parts: [String.t() | {:param, term()}]}
  end

  @functions %{
    id: "id",
    labels: "labels",
    type: "type",
    degree: "degree",
    indegree: "indegree",
    outdegree: "outdegree",
    length: "length",
    lower: "lower",
    upper: "upper",
    abs: "abs",
    to_int: "toInt",
    to_float: "toFloat",
    coalesce: "coalesce",
    count: "count",
    sum: "sum",
    avg: "avg",
    min: "min",
    max: "max",
    collect: "collect"
  }

  @binary %{
    ==: "=",
    !=: "<>",
    <: "<",
    <=: "<=",
    >: ">",
    >=: ">=",
    and: "AND",
    or: "OR",
    +: "+",
    -: "-",
    *: "*",
    /: "/"
  }

  # ------------------------------------------------------------------ build

  @doc "An empty query."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Add a pattern to match. Starts a new query when given only a pattern.

      match("(a:Person)-[:KNOWS]->(b)")
      match(q, "(c:City {name: $city})", city: "London")
      match(q, vertex(:c, "City", %{name: "London"}))
  """
  @spec match(t() | String.t() | Fragment.t(), String.t() | Fragment.t() | keyword() | map()) :: t()
  def match(query_or_pattern, pattern_or_params \\ [])

  def match(%__MODULE__{} = q, pattern), do: match(q, pattern, [])
  def match(pattern, params), do: match(new(), pattern, params)

  @spec match(t(), String.t() | Fragment.t(), keyword() | map()) :: t()
  def match(%__MODULE__{} = q, pattern, params) do
    ensure_no_call(q, "match")
    {q, text} = render(q, pattern_fragment(pattern))
    %{q | match: q.match ++ [text]} |> merge_params(params)
  end

  @doc """
  Create a pattern: on its own, or after `match/2` to link what was matched.

      create(vertex(:p, "Person", %{name: "Ada"}))

      match("(a:Person {name: $a}), (b:Person {name: $b})", a: "Ada", b: "Bob")
      |> create(edge(:a, "KNOWS", :b, %{since: 2020}))
  """
  @spec create(t() | String.t() | Fragment.t(), String.t() | Fragment.t() | keyword() | map()) :: t()
  def create(query_or_pattern, pattern_or_params \\ [])

  def create(%__MODULE__{} = q, pattern), do: create(q, pattern, [])
  def create(pattern, params), do: create(new(), pattern, params)

  @spec create(t(), String.t() | Fragment.t(), keyword() | map()) :: t()
  def create(%__MODULE__{} = q, pattern, params) do
    ensure_no_call(q, "create")
    {q, text} = render(q, pattern_fragment(pattern))

    action =
      case q.action do
        nil -> {:create, [text]}
        {:create, pats} -> {:create, pats ++ [text]}
        other -> conflict(other, :create)
      end

    %{q | action: action} |> merge_params(params)
  end

  @doc """
  A node pattern, `(var:Label {props})`, with its properties as parameters.
  `labels` is a string or a list of strings; pass `nil` for none.
  """
  @spec vertex(atom() | nil, String.t() | [String.t()] | nil, map() | keyword()) :: Fragment.t()
  def vertex(var, labels \\ nil, props \\ %{}) do
    %Fragment{parts: ["("] ++ var_label(var, labels) ++ props_parts(props) ++ [")"]}
  end

  @doc """
  A relationship pattern between two variables,
  `(from)-[var:TYPE {props}]->(to)`.
  """
  @spec edge(atom(), String.t(), atom(), map() | keyword(), atom() | nil) :: Fragment.t()
  def edge(from, type, to, props \\ %{}, var \\ nil) do
    %Fragment{
      parts:
        ["(", ident(from), ")-["] ++
          var_label(var, type) ++ props_parts(props) ++ ["]->(", ident(to), ")"]
    }
  end

  @doc """
  Add a condition. Several are joined with `AND`.

      where(q, p.age >= ^min and not is_nil(p.email))
  """
  defmacro where(query, expr) do
    frag = compile(expr, :top)
    quote do: Glider.Query.__where__(unquote(query), unquote(frag))
  end

  @doc """
  What to return, which also decides the shape of each row from `Glider.all/3`:

    * one expression - its value: `return(q, p.name)` gives `["Ada", ...]`
    * a list - a list per row: `return(q, [p.name, p.age])`
    * a tuple - a tuple per row: `return(q, {p.name, p.age})`
    * a keyword list - a map per row, the keys also naming the columns:
      `return(q, name: p.name, friends: count(f))`

  A later `return/2` replaces an earlier one.
  """
  defmacro return(query, spec) do
    {items, shape} = compile_return(spec)
    quote do: Glider.Query.__return__(unquote(query), unquote(items), unquote(Macro.escape(shape)))
  end

  @doc "Return distinct rows."
  @spec distinct(t()) :: t()
  def distinct(%__MODULE__{} = q), do: %{q | distinct: true}

  @doc """
  Order the returned rows. Takes an expression, a list of them, or a keyword
  list of `asc:` / `desc:` entries. An atom names a `return/2` key.

      order_by(q, desc: count(f), asc: p.name)
      order_by(q, desc: :friends)
  """
  defmacro order_by(query, spec) do
    items =
      spec
      |> List.wrap()
      |> Enum.map(fn
        {dir, e} when dir in [:asc, :desc] -> {order_expr(e), dir}
        e -> {order_expr(e), :asc}
      end)

    quote do: Glider.Query.__order__(unquote(query), unquote(items))
  end

  @doc "Skip the first `n` rows. `n` may be pinned or a plain expression."
  defmacro skip(query, n), do: quote(do: Glider.Query.__skip__(unquote(query), unquote(unpin(n))))

  @doc "Return at most `n` rows. `n` may be pinned or a plain expression."
  defmacro limit(query, n), do: quote(do: Glider.Query.__limit__(unquote(query), unquote(unpin(n))))

  @doc """
  Set properties on matched entities. Several assignments may be given at once.

      set(q, p.age = ^age, p.seen = true)
  """
  defmacro set(query, assignment) do
    items = [compile_assign(assignment)]
    quote do: Glider.Query.__set__(unquote(query), unquote(items))
  end

  defmacro set(query, a1, a2) do
    items = Enum.map([a1, a2], &compile_assign/1)
    quote do: Glider.Query.__set__(unquote(query), unquote(items))
  end

  defmacro set(query, a1, a2, a3) do
    items = Enum.map([a1, a2, a3], &compile_assign/1)
    quote do: Glider.Query.__set__(unquote(query), unquote(items))
  end

  @doc """
  Add a condition built at run time, for code that assembles queries from
  data rather than from source (a data layer, a search form). `parts` are
  Cypher text and `{:param, value}` pieces; values travel as parameters.

      where_fragment(q, ["n.", ident(field), " >= ", {:param, min}])
  """
  @spec where_fragment(t(), [String.t() | {:param, term()}]) :: t()
  def where_fragment(%__MODULE__{} = q, parts) when is_list(parts),
    do: __where__(q, %Fragment{parts: parts})

  @doc """
  Set properties on a matched variable from a map or keyword list, the
  run-time counterpart of `set/2`. A `nil` value writes `null`.

      set_props(q, :p, %{name: "Ada", age: 37})
  """
  @spec set_props(t(), atom(), map() | keyword()) :: t()
  def set_props(%__MODULE__{} = q, var, props) do
    frags =
      Enum.map(props, fn {k, v} ->
        %Fragment{parts: [ident(var) <> "." <> ident(k) <> " = ", {:param, v}]}
      end)

    if frags == [], do: q, else: __set__(q, frags)
  end

  @doc "Add a label to a matched node: `add_label(q, :p, \"VIP\")`."
  @spec add_label(t(), atom(), String.t()) :: t()
  def add_label(%__MODULE__{} = q, var, label),
    do: __set__(q, [%Fragment{parts: [ident(var), ":", ident(label)]}])

  @doc "Remove a property: `remove(q, p.nickname)`."
  defmacro remove(query, {{:., _, [{var, _, ctx}, field]}, _, []})
           when is_atom(var) and is_atom(ctx) and is_atom(field) do
    text = ident(var) <> "." <> ident(field)
    quote do: Glider.Query.__remove__(unquote(query), unquote(text))
  end

  defmacro remove(_query, other) do
    raise ArgumentError, "remove/2 takes a property, like p.name; got: #{Macro.to_string(other)}"
  end

  @doc "Remove a label from a matched node: `remove_label(q, :p, \"VIP\")`."
  @spec remove_label(t(), atom(), String.t()) :: t()
  def remove_label(%__MODULE__{} = q, var, label),
    do: __remove__(q, ident(var) <> ":" <> ident(label))

  @doc """
  Delete matched entities. A node with relationships can only be deleted with
  `detach: true`, which deletes them too.

      delete(q, [:p], detach: true)
  """
  @spec delete(t(), atom() | [atom()], keyword()) :: t()
  def delete(%__MODULE__{} = q, vars, opts \\ []) do
    q = ensure_action(q, :delete)
    %{q | action: {:delete, Enum.map(List.wrap(vars), &ident/1), Keyword.get(opts, :detach, false)}}
  end

  @doc """
  Run a graph algorithm. Arguments travel as parameters.

      call(:pagerank, iterations: 20, top: 10)
      call(:shortestpath, from: a, to: b, type: "KNOWS")
  """
  @spec call(t() | atom(), atom() | keyword()) :: t()
  def call(query_or_name, name_or_args \\ [])

  def call(%__MODULE__{} = q, name) when is_atom(name), do: call(q, name, [])
  def call(name, args) when is_atom(name), do: call(new(), name, args)

  @spec call(t(), atom(), keyword()) :: t()
  def call(%__MODULE__{} = q, name, args) do
    if q.match != [] or q.action != nil do
      raise ArgumentError, "call/3 runs on its own; it cannot follow match/2 or another clause"
    end

    parts =
      args
      |> Enum.map(fn {k, v} -> [ident(k), ": ", {:param, v}] end)
      |> Enum.intersperse([", "])
      |> List.flatten()

    {q, text} = render(q, %Fragment{parts: [ident(name), "("] ++ parts ++ [")"]})
    %{q | call: text}
  end

  @doc "Show glider's plan for the query instead of running it."
  @spec explain(t()) :: t()
  def explain(%__MODULE__{} = q), do: %{q | explain: true}

  @doc """
  The Cypher text and parameter map for a query.

      {"MATCH (p:Person) WHERE p.age >= $__1 RETURN p.name", %{"__1" => 18}}
  """
  @spec to_cypher(t()) :: {String.t(), %{String.t() => term()}}
  def to_cypher(%__MODULE__{} = q) do
    body =
      cond do
        q.call ->
          "CALL " <> q.call

        q.match == [] ->
          case q.action do
            {:create, pats} ->
              if q.where != [], do: raise(ArgumentError, "where/2 needs a match/2")
              "CREATE " <> Enum.join(pats, ", ")

            nil ->
              raise ArgumentError, "an empty query: start with match/1, create/1 or call/2"

            _ ->
              raise ArgumentError, "set, remove, delete and return need a match/2 first"
          end

        true ->
          "MATCH " <> Enum.join(q.match, ", ") <> where_text(q) <> " " <> tail_text(q)
      end

    {if(q.explain, do: "EXPLAIN " <> body, else: body), q.params}
  end

  @doc false
  # Shape one result row as `return/2` asked.
  def shape(%__MODULE__{shape: :value}, [v]), do: v
  def shape(%__MODULE__{shape: :tuple}, row), do: List.to_tuple(row)
  def shape(%__MODULE__{shape: {:map, keys}}, row), do: keys |> Enum.zip(row) |> Map.new()
  def shape(%__MODULE__{}, row), do: row

  # --------------------------------------------------------- runtime helpers

  @doc false
  def __where__(%__MODULE__{} = q, frag) do
    {q, text} = render(q, frag)
    %{q | where: q.where ++ [text]}
  end

  @doc false
  def __return__(%__MODULE__{} = q, items, shape) do
    q = ensure_action(q, :return)

    {texts, q} =
      Enum.map_reduce(items, q, fn {frag, alias}, q ->
        {q, text} = render(q, frag)
        {if(alias, do: text <> " AS " <> alias, else: text), q}
      end)

    %{q | action: :return, return: texts, shape: shape}
  end

  @doc false
  def __order__(%__MODULE__{} = q, items) do
    {texts, q} =
      Enum.map_reduce(items, q, fn {frag, dir}, q ->
        {q, text} = render(q, frag)
        {if(dir == :desc, do: text <> " DESC", else: text), q}
      end)

    %{q | order: q.order ++ texts}
  end

  @doc false
  def __skip__(%__MODULE__{} = q, n) when is_integer(n) and n >= 0, do: %{q | skip: n}
  def __skip__(_q, n), do: raise(ArgumentError, "skip/2 needs a non-negative integer, got: #{inspect(n)}")

  @doc false
  def __limit__(%__MODULE__{} = q, n) when is_integer(n) and n >= 0, do: %{q | limit: n}
  def __limit__(_q, n), do: raise(ArgumentError, "limit/2 needs a non-negative integer, got: #{inspect(n)}")

  @doc false
  def __set__(%__MODULE__{} = q, frags) do
    q = ensure_action(q, :set)
    prior = case q.action, do: ({:set, items} -> items; _ -> [])

    {texts, q} =
      Enum.map_reduce(frags, q, fn frag, q ->
        {q, text} = render(q, frag)
        {text, q}
      end)

    %{q | action: {:set, prior ++ texts}}
  end

  @doc false
  def __remove__(%__MODULE__{} = q, text) do
    q = ensure_action(q, :remove)
    prior = case q.action, do: ({:remove, items} -> items; _ -> [])
    %{q | action: {:remove, prior ++ [text]}}
  end

  # -------------------------------------------------------------- rendering

  defp where_text(%{where: []}), do: ""
  defp where_text(%{where: [one]}), do: " WHERE " <> one
  defp where_text(%{where: many}), do: " WHERE " <> Enum.map_join(many, " AND ", &("(" <> &1 <> ")"))

  defp tail_text(q) do
    case q.action do
      nil -> "RETURN *" <> order_text(q)
      :return -> "RETURN " <> if(q.distinct, do: "DISTINCT ", else: "") <> Enum.join(q.return, ", ") <> order_text(q)
      {:set, items} -> "SET " <> Enum.join(items, ", ")
      {:remove, items} -> "REMOVE " <> Enum.join(items, ", ")
      {:delete, vars, detach} -> if(detach, do: "DETACH DELETE ", else: "DELETE ") <> Enum.join(vars, ", ")
      {:create, pats} -> "CREATE " <> Enum.join(pats, ", ")
    end
  end

  defp order_text(q) do
    # glider orders by returned columns: an expression that is also returned
    # under an alias is ordered by that alias.
    aliases =
      for item <- q.return || [], [expr, name] <- [String.split(item, " AS ", parts: 2)], into: %{},
          do: {expr, name}

    order =
      if q.order == [] do
        ""
      else
        " ORDER BY " <>
          Enum.map_join(q.order, ", ", fn item ->
            {expr, dir} =
              case String.split(item, " DESC", parts: 2) do
                [e, ""] -> {e, " DESC"}
                _ -> {item, ""}
              end

            Map.get(aliases, expr, expr) <> dir
          end)
      end

    skip = if q.skip, do: " SKIP #{q.skip}", else: ""
    limit = if q.limit, do: " LIMIT #{q.limit}", else: ""
    order <> skip <> limit
  end

  # Assign fresh parameter names to a fragment's values.
  defp render(q, %Fragment{parts: parts}) do
    {texts, q} =
      Enum.map_reduce(parts, q, fn
        {:param, v}, q ->
          name = "__#{q.next}"
          {"$" <> name, %{q | next: q.next + 1, params: Map.put(q.params, name, v)}}

        text, q ->
          {text, q}
      end)

    {q, IO.iodata_to_binary(texts)}
  end

  defp pattern_fragment(%Fragment{} = f), do: f
  defp pattern_fragment(text) when is_binary(text), do: %Fragment{parts: [text]}

  defp merge_params(q, params) do
    Enum.reduce(params, q, fn {k, v}, q ->
      key = to_string(k)

      case q.params do
        %{^key => ^v} -> q
        %{^key => other} -> raise ArgumentError, "parameter $#{key} given twice, as #{inspect(other)} and #{inspect(v)}"
        _ -> %{q | params: Map.put(q.params, key, v)}
      end
    end)
  end

  defp ensure_no_call(%{call: nil}, _), do: :ok
  defp ensure_no_call(_, what), do: raise(ArgumentError, "#{what} cannot be combined with call/2")

  defp ensure_action(%{action: nil} = q, _), do: q
  defp ensure_action(%{action: :return} = q, :return), do: q
  defp ensure_action(%{action: {kind, _}} = q, kind), do: q
  defp ensure_action(%{action: other}, wanted), do: conflict(other, wanted)

  defp conflict(have, wanted) do
    name = fn
      :return -> "return"
      {k, _} -> Atom.to_string(k)
      {k, _, _} -> Atom.to_string(k)
      k -> Atom.to_string(k)
    end

    raise ArgumentError,
          "glider runs one clause after MATCH; this query already has #{name.(have)} and cannot also #{name.(wanted)}"
  end

  defp var_label(var, labels) do
    v = if var, do: [ident(var)], else: []
    l = labels |> List.wrap() |> Enum.flat_map(&[":", ident(&1)])
    v ++ l
  end

  defp props_parts(props) do
    case Enum.to_list(props) do
      [] ->
        []

      pairs ->
        inner =
          pairs
          |> Enum.map(fn {k, v} -> [ident(k), ": ", {:param, v}] end)
          |> Enum.intersperse([", "])
          |> List.flatten()

        [" {"] ++ inner ++ ["}"]
    end
  end

  @doc false
  # A label, type, variable or property name as Cypher: bare when it is a
  # plain identifier, backticked otherwise.
  def ident(name) when is_atom(name), do: ident(Atom.to_string(name))

  def ident(name) when is_binary(name) do
    cond do
      name =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/ -> name
      String.contains?(name, "`") -> raise ArgumentError, "names cannot contain a backtick: #{inspect(name)}"
      true -> "`" <> name <> "`"
    end
  end

  # ------------------------------------------------------- expression compiler
  # Runs at compile time: turns an Elixir expression into quoted code that
  # builds a %Fragment{} at runtime, with pinned values left as {:param, expr}.

  defp compile(ast, pos) do
    parts = ast |> expr(pos) |> List.flatten() |> merge_text()
    quote do: %Glider.Query.Fragment{parts: unquote(parts)}
  end

  defp merge_text(parts) do
    parts
    |> Enum.chunk_by(&is_binary/1)
    |> Enum.flat_map(fn
      [s | _] = chunk when is_binary(s) -> [Enum.join(chunk)]
      params -> params
    end)
  end

  # pinned value
  defp expr({:^, _, [value]}, _pos), do: [{:param, value}]

  # var.field
  defp expr({{:., _, [{var, _, ctx}, field]}, _, []}, _pos)
       when is_atom(var) and is_atom(ctx) and is_atom(field),
       do: [ident(var) <> "." <> ident(field)]

  # literals
  defp expr(n, _pos) when is_integer(n) or is_float(n), do: [to_string(n)]
  defp expr(b, _pos) when is_boolean(b), do: [to_string(b)]
  defp expr(nil, _pos), do: ["null"]
  defp expr(s, _pos) when is_binary(s), do: [{:param, s}]
  defp expr(a, _pos) when is_atom(a), do: [{:param, Atom.to_string(a)}]
  defp expr(list, _pos) when is_list(list), do: ["["] ++ Enum.intersperse(Enum.map(list, &expr(&1, :inner)), ", ") ++ ["]"]

  # not is_nil(x) -> x IS NOT NULL
  defp expr({op, _, [{:is_nil, _, [x]}]}, pos) when op in [:not, :!],
    do: wrap(pos, [expr(x, :inner), " IS NOT NULL"])

  defp expr({:is_nil, _, [x]}, pos), do: wrap(pos, [expr(x, :inner), " IS NULL"])
  defp expr({op, _, [x]}, pos) when op in [:not, :!], do: wrap(pos, ["NOT ", expr(x, :inner)])
  defp expr({:-, _, [x]}, _pos), do: ["-", expr(x, :inner)]

  defp expr({:in, _, [x, list]}, pos), do: wrap(pos, [expr(x, :inner), " IN ", expr(list, :inner)])

  defp expr({op, _, [a, b]}, pos) when is_map_key(@binary, op),
    do: wrap(pos, [expr(a, :inner), " ", @binary[op], " ", expr(b, :inner)])

  defp expr({:&&, m, args}, pos), do: expr({:and, m, args}, pos)
  defp expr({:||, m, args}, pos), do: expr({:or, m, args}, pos)

  defp expr({op, _, [a, b]}, pos) when op in [:contains, :starts_with, :ends_with] do
    kw = %{contains: " CONTAINS ", starts_with: " STARTS WITH ", ends_with: " ENDS WITH "}[op]
    wrap(pos, [expr(a, :inner), kw, expr(b, :inner)])
  end

  defp expr({:count, _, []}, _pos), do: ["count(*)"]

  defp expr({:fragment, _, [text | args]}, _pos) when is_binary(text) do
    pieces = String.split(text, "?")

    if length(pieces) != length(args) + 1 do
      raise ArgumentError, "fragment/n: #{length(pieces) - 1} placeholders but #{length(args)} arguments"
    end

    ["("] ++ interleave(pieces, Enum.map(args, &expr(&1, :inner))) ++ [")"]
  end

  defp expr({fun, _, args}, _pos) when is_atom(fun) and is_list(args) and is_map_key(@functions, fun),
    do: [@functions[fun], "("] ++ Enum.intersperse(Enum.map(args, &expr(&1, :inner)), ", ") ++ [")"]

  # a pattern variable
  defp expr({var, _, ctx}, _pos) when is_atom(var) and is_atom(ctx), do: [ident(var)]

  defp expr(other, _pos) do
    raise ArgumentError,
          "cannot translate #{Macro.to_string(other)} to Cypher. Pin Elixir values with ^, " <>
            "or use fragment/n"
  end

  defp wrap(:top, parts), do: parts
  defp wrap(:inner, parts), do: ["("] ++ parts ++ [")"]

  defp interleave([p], []), do: [p]
  defp interleave([p | ps], [a | as]), do: [p, a | interleave(ps, as)]

  defp compile_return(spec) when is_list(spec) do
    if spec != [] and Keyword.keyword?(spec) do
      items = Enum.map(spec, fn {k, e} -> {compile(e, :top), ident(k)} end)
      {items, {:map, Keyword.keys(spec)}}
    else
      {Enum.map(spec, &{compile(&1, :top), nil}), :list}
    end
  end

  defp compile_return({:{}, _, elems}), do: {Enum.map(elems, &{compile(&1, :top), nil}), :tuple}
  defp compile_return({a, b}), do: {[{compile(a, :top), nil}, {compile(b, :top), nil}], :tuple}
  defp compile_return(e), do: {[{compile(e, :top), nil}], :value}

  defp order_expr(a) when is_atom(a) and not is_boolean(a) and not is_nil(a),
    do: quote(do: %Glider.Query.Fragment{parts: [unquote(ident(a))]})

  defp order_expr(e), do: compile(e, :top)

  defp compile_assign({:=, _, [{{:., _, [{var, _, ctx}, field]}, _, []}, value]})
       when is_atom(var) and is_atom(ctx) and is_atom(field) do
    parts = List.flatten([ident(var) <> "." <> ident(field) <> " = ", expr(value, :top)]) |> merge_text()
    quote do: %Glider.Query.Fragment{parts: unquote(parts)}
  end

  defp compile_assign(other) do
    raise ArgumentError, "set/2 takes assignments like p.name = ^name; got: #{Macro.to_string(other)}"
  end

  defp unpin({:^, _, [e]}), do: e
  defp unpin(e), do: e
end
