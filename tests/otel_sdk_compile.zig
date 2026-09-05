const std = @import("std");
const otel = @import("opentelemetry-sdk");

test "fx can compile the pinned native OpenTelemetry SDK" {
    _ = otel.trace;
    _ = otel.otlp;
    _ = std.testing.allocator;
}
