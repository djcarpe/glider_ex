import Config

if config_env() == :test do
  # Spans go to the test process (see test/telemetry_test.exs), not a collector.
  config :opentelemetry,
    traces_exporter: :none,
    processors: [{:otel_simple_processor, %{}}]
end
