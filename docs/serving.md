# Listener readiness

`serve` accepts an optional `onReady` callback. It runs once on the serving
thread after the socket has successfully bound and started listening, before
the event loop begins. It does not run if binding or listener setup fails.

The callback must be `gcsafe` and must not raise exceptions. It can publish
readiness to another thread or call `close` to request an orderly shutdown.
Its default is `nil`, which preserves the usual `serve` behavior.
