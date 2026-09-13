# What happens when many processes share one handle.
#
# glider is not thread-safe, so the NIF serialises every call on a mutex. This
# measures the shape of that: throughput against the number of concurrent BEAM
# processes hammering a single handle.
#
# What to expect, and why:
#
#   * Cheap queries barely improve with concurrency. The critical section is
#     the whole query, so the mutex is the bottleneck almost immediately.
#   * Separate handles DO scale, because each has its own mutex. That is the
#     escape hatch when you need read parallelism: shard, do not share.
#
# This is measured rather than asserted because it determines how you deploy:
# one handle behind a GenServer is fine for writes, but will not give you
# parallel reads no matter how many cores you add.

Code.require_file("support.ex", __DIR__)

{shared, n} = Glider.Bench.social(50_000)
Glider.Bench.describe(shared, "shared graph")

probe = Glider.Bench.email(div(n, 2))
query = ~s|MATCH (p:Person {email:"#{probe}"}) RETURN p.name|

# One handle per scheduler, each holding the same data, to show the contrast.
sharded =
  for _ <- 1..8 do
    {db, _} = Glider.Bench.social(50_000)
    db
  end

ops = 2_000

run_shared = fn concurrency ->
  per = div(ops, concurrency)

  1..concurrency
  |> Task.async_stream(fn _ -> for _ <- 1..per, do: Glider.query(shared, query) end,
       max_concurrency: concurrency,
       timeout: :infinity
     )
  |> Stream.run()
end

run_sharded = fn concurrency ->
  per = div(ops, concurrency)

  1..concurrency
  |> Task.async_stream(
    fn i ->
      db = Enum.at(sharded, rem(i - 1, length(sharded)))
      for _ <- 1..per, do: Glider.query(db, query)
    end,
    max_concurrency: concurrency,
    timeout: :infinity
  )
  |> Stream.run()
end

IO.puts("\n== #{ops} indexed lookups, ONE shared handle ==")

Benchee.run(
  Map.new([1, 2, 4, 8], fn c -> {"#{c} process(es)", fn -> run_shared.(c) end} end),
  time: 4,
  warmup: 1,
  print: [fast_warning: false]
)

IO.puts("\n== #{ops} indexed lookups, ONE HANDLE PER PROCESS ==")

Benchee.run(
  Map.new([1, 2, 4, 8], fn c -> {"#{c} process(es)", fn -> run_sharded.(c) end} end),
  time: 4,
  warmup: 1,
  print: [fast_warning: false]
)

Glider.close(shared)
Enum.each(sharded, &Glider.close/1)
