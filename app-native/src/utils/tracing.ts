/**
 * Tracing utilities for distributed tracing across native app, server, and devices.
 *
 * Trace ID format: {timestamp_ms}-{random_8_chars}
 * Example: 1705500000000-a1b2c3d4
 */

/**
 * Generate a unique trace ID.
 */
export function generateTraceId(): string {
  const timestamp = Date.now();
  const random = Math.random().toString(36).slice(2, 10);
  return `${timestamp}-${random}`;
}

/**
 * Create trace context for a request.
 */
export function createTraceContext(action: string, accessoryId?: string) {
  return {
    traceId: generateTraceId(),
    clientTimestamp: new Date().toISOString(),
    clientType: 'native',
    action,
    accessoryId,
  };
}
