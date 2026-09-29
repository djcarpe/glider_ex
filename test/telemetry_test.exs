defmodule Glider.TelemetryTest do
  # Handlers and the span exporter are global.
  use ExUnit.Case, async: false

  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  @events for s <- [:query, :transaction, :checkpoint],
              p <- [:start, :stop, :exception],
              do: [:glider, s, p]

  setup do
    test = self()
    id = make_ref()

    :telemetry.attach_many(id, @events ++ [[:glider, :db]], &__MODULE__.forward/4, test)

    on_exit(fn -> :telemetry.detach(id) end)
    {:ok, db} = Glider.open()
    {:ok, db: db}
  end

  # Other test modules run concurrently and emit events too: every assertion
  # below pins the handle it expects.
  def forward(event, m, meta, test), do: send(test, {:event, event, m, meta})

  test "a query emits a span whose stop carries the engine report", %{db: db} do
    Glider.run!(db, "CREATE (:Person {name: $n})-[:KNOWS]->(:Person {name: 'Bob'})", n: "Ada")
    {:ok, _} = Glider.query(db, "MATCH (p:Person) RETURN p.name")

    q = "MATCH (p:Person) RETURN p.name"
    assert_receive {:event, [:glider, :query, :start], %{system_time: _}, %{db: ^db, query: ^q}}
    assert_receive {:event, [:glider, :query, :stop], m, %{db: ^db, query: ^q} = meta}
    assert meta.operation == "MATCH"
    assert meta.result == :ok
    assert meta.db == db
    assert meta.db_name =~ ~r/^:memory:\d+$/
    assert m.rows == 2
    assert m.duration > 0
    assert m.engine_duration > 0 and m.engine_duration <= m.duration
    assert is_integer(m.page_hits)
  end

  test "a failed query is a stop with result :error and the reason", %{db: db} do
    {:error, reason} = Glider.query(db, "MATCH (n RETURN n")
    assert_receive {:event, [:glider, :query, :stop], %{rows: 0}, %{db: ^db} = meta}
    assert meta.result == :error
    assert meta.error == reason
    assert meta.operation == "INVALID"
  end

  test "an error before the engine runs still stops the span", %{db: db} do
    Glider.close(db)
    {:error, "this graph is closed"} = Glider.query(db, "MATCH (n) RETURN n")
    assert_receive {:event, [:glider, :query, :stop], m, %{db: ^db, result: :error}}
    refute Map.has_key?(m, :rows)
  end

  test "transactions and checkpoints are spans", %{db: db} do
    {:ok, :done} = Glider.transaction(db, fn -> Glider.run!(db, "CREATE (:A)") && :done end)
    assert_receive {:event, [:glider, :transaction, :start], _, %{db: ^db}}
    assert_receive {:event, [:glider, :query, :stop], _, %{db: ^db, operation: "CREATE"}}
    assert_receive {:event, [:glider, :transaction, :stop], _, %{db: ^db, result: :ok}}
    :ok = Glider.checkpoint(db)
    assert_receive {:event, [:glider, :checkpoint, :stop], _, %{db: ^db, result: :ok}}
  end

  test "engine counters, db metrics and renderers", %{db: db} do
    Glider.run!(db, "CREATE (:City {name: 'Oslo'})")
    snap = Glider.Telemetry.snapshot()
    assert Enum.any?(snap.queries, &(&1.op == "CREATE" and &1.ok >= 1))
    assert snap.duration_count >= 1

    {:ok, m} = Glider.Telemetry.metrics(db)
    assert m.nodes == 1
    assert m.commits >= 1

    assert Glider.Telemetry.prometheus(db) =~ ~r/glider_db_nodes\{glider_db="#{m.name}"\} 1/
    otlp = :json.decode(Glider.Telemetry.otlp_metrics([db], "beam-app"))
    [res] = otlp["resourceMetrics"]

    assert %{"key" => "service.name", "value" => %{"stringValue" => "beam-app"}} in res[
             "resource"
           ]["attributes"]

    names = for m <- hd(res["scopeMetrics"])["metrics"], do: m["name"]

    assert "glider.queries" in names and "glider.db.nodes" in names and
             "glider.query.duration" in names

    unless System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
      assert {:ok, false} = Glider.Telemetry.start_exporter()
    end

    :ok = Glider.Telemetry.emit_db_metrics(db)
    assert_receive {:event, [:glider, :db], %{nodes: 1, edges: 0}, %{db: ^db, db_name: name}}
    assert name == m.name
  end

  describe "OpenTelemetry" do
    setup do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      :ok = Glider.OpenTelemetry.setup()
      on_exit(fn -> Glider.OpenTelemetry.teardown() end)
    end

    test "queries are client spans under the caller's span, transactions parent their statements",
         %{db: db} do
      tracer = :opentelemetry.get_tracer(:test)
      parent = :otel_tracer.start_span(tracer, "request", %{})
      :otel_tracer.set_current_span(parent)

      Glider.run!(db, "CREATE (:Person {name: 'Ada'})")
      {:ok, :ok} = Glider.transaction(db, fn -> Glider.run!(db, "CREATE (:Person)") && :ok end)
      {:error, _} = Glider.query(db, "MATCH (n RETURN n")
      :otel_span.end_span(parent)

      parent_id = :otel_span.span_id(parent)
      trace_id = :otel_span.trace_id(parent)

      assert_receive {:span,
                      span(
                        name: "glider CREATE",
                        parent_span_id: ^parent_id,
                        trace_id: ^trace_id,
                        kind: :client
                      ) = create}

      attrs = :otel_attributes.map(span(create, :attributes))
      assert attrs[:"db.system.name"] == "glider"
      assert attrs[:"db.operation.name"] == "CREATE"
      assert attrs[:"db.query.text"] == "CREATE (:Person {name: 'Ada'})"
      assert attrs[:"glider.touched"] == 1
      assert attrs[:"glider.db"] =~ ~r/^:memory:/

      assert_receive {:span,
                      span(name: "glider transaction", span_id: tx_id, parent_span_id: ^parent_id)}

      assert_receive {:span, span(name: "glider CREATE", parent_span_id: ^tx_id)}

      assert_receive {:span, span(name: "glider INVALID", status: status)}
      assert {:status, :error, msg} = status
      assert is_binary(msg) and msg != ""
    end
  end
end
