# HTTP request inactivity

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
