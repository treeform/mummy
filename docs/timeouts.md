# Socket inactivity

Pass `requestTimeoutMs` to `newServer` to bound idle connections and incomplete
HTTP request headers or bodies. The default is `0`, which disables this limit.

```nim
let server = newServer(handler, requestTimeoutMs = 15000)
```

Each incoming read renews the deadline. Time spent running request handlers or
draining outgoing responses does not count toward the timeout. A persistent
connection receives a new read deadline after its response drains. Upgraded
WebSockets are exempt. Expired HTTP connections close without a response.

The server uses monotonic deadlines and sleeps until socket activity or the
earliest pending deadline; enabling this limit does not add a polling thread.

Pass `writeTimeoutMs` to bound outgoing HTTP responses and WebSocket frames
that stop making progress. Its default is also `0`, which disables this limit.

```nim
let server = newServer(handler, requestTimeoutMs = 15000, writeTimeoutMs = 15000)
```

The write deadline starts when the first outgoing buffer is queued and renews
only when bytes are written to the socket. Queuing more output does not extend
an existing deadline. There is no write deadline while the output queue is
empty, including time spent running handlers or waiting for WebSocket messages.
Expired connections close even if part of a response remains unsent.
