import
  std/[net, os, strutils],
  mummy

from std/nativesockets import setSockOptInt, SOL_SOCKET

const SocketHeader =
  when defined(windows): "<winsock2.h>"
  else: "<sys/socket.h>"

let receiveBufferOption {.importc: "SO_RCVBUF", header: SocketHeader.}: cint

const
  IdleTimeout = 250
  SlowDelay = IdleTimeout * 3
  LargeResponseBytes = 8 * 1024 * 1024

proc handler(request: Request) {.gcsafe.} =
  ## Exercises slow handlers, response backpressure, and ordinary HTTP replies.
  case request.path
  of "/slow":
    sleep(SlowDelay)
    request.respond(200, body = "slow")
  of "/interim":
    request.respond(100)
    sleep(SlowDelay)
    request.respond(200, body = "final")
  of "/large":
    request.respond(200, body = repeat('x', LargeResponseBytes))
  of "/websocket":
    discard request.upgradeToWebSocket()
  else:
    request.respond(200, body = request.body & "ok")

proc websocketHandler(
  socket: WebSocket, event: WebSocketEvent, message: Message
) {.gcsafe.} =
  ## Echoes one test message after the HTTP read deadline has passed.
  if event == MessageEvent and message.kind == TextMessage:
    socket.send(message.data)

proc serve(config: tuple[server: Server, port: Port]) {.thread.} =
  ## Runs the real socket loop with only two request workers.
  config.server.serve(config.port, "127.0.0.1")

proc withServer(timeout: int, test: proc(port: Port)) =
  ## Starts one loopback fixture and always joins its serving thread.
  let reservation = newSocket()
  reservation.bindAddr(Port(0), "127.0.0.1")
  let port = reservation.getLocalAddr()[1]
  reservation.close()
  let server = newServer(
    handler, websocketHandler, workerThreads = 2, requestTimeoutMs = timeout
  )
  var thread: Thread[tuple[server: Server, port: Port]]
  createThread(thread, serve, (server, port))
  defer:
    server.close()
    joinThread(thread)
  server.waitUntilReady()
  test(port)

proc connect(port: Port, receiveBuffer = 0): Socket =
  ## Opens an unbuffered client so deadline checks observe real socket reads.
  result = newSocket(buffered = false)
  if receiveBuffer > 0:
    result.getFd().setSockOptInt(SOL_SOCKET, receiveBufferOption, receiveBuffer)
  result.connect("127.0.0.1", port, timeout = 3000)

proc request(socket: Socket, path = "/") =
  ## Sends a persistent ordinary request to the fixture server.
  socket.send("GET " & path & " HTTP/1.1\r\nHost: localhost\r\n\r\n")

proc reply(socket: Socket): tuple[status: int, body: string] =
  ## Reads one HTTP response without consuming a later persistent response.
  var headers: string
  while not headers.endsWith("\r\n\r\n"):
    let next = socket.recv(1, timeout = 3000)
    doAssert next.len == 1, "Connection closed before its response."
    headers.add(next)
    doAssert headers.len < 16 * 1024
  let lines = headers.split("\r\n")
  result.status = parseInt(lines[0].splitWhitespace()[1])
  var length = 0
  for line in lines:
    if line.toLowerAscii().startsWith("content-length:"):
      length = parseInt(line.split(':', 1)[1].strip())
  while result.body.len < length:
    let data = socket.recv(min(65536, length - result.body.len), timeout = 3000)
    doAssert data.len > 0, "Connection closed during its response."
    result.body.add(data)

proc testIncomplete(port: Port) =
  ## Expires idle sockets and incomplete request headers or bodies.
  echo "Testing HTTP receive inactivity deadlines"
  for partial in ["", "GET / HTTP/1.1\r\nHost:",
    "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\na"]:
      let socket = connect(port)
      if partial.len > 0:
        socket.send(partial)
      doAssert socket.recv(1, timeout = 3000).len == 0,
        "An incomplete request must close after its inactivity deadline."
      socket.close()

proc testProgress(port: Port) =
  ## Extends the inactivity deadline when each body fragment makes progress.
  echo "Testing progress renews the HTTP read deadline"
  let socket = connect(port)
  defer: socket.close()
  socket.send("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n\r\n")
  for value in "abcdef":
    sleep(IdleTimeout div 3)
    socket.send($value)
  doAssert socket.reply() == (200, "abcdefok")

proc testHandlers(port: Port) =
  ## Leaves slow and informational handlers alive and renews keepalive time.
  echo "Testing slow handlers and interim HTTP responses"
  for path in ["/slow", "/interim"]:
    let socket = connect(port)
    socket.request(path)
    if path == "/interim":
      doAssert socket.reply().status == 100
    doAssert socket.reply().status == 200
    sleep(IdleTimeout div 3)
    socket.request()
    doAssert socket.reply() == (200, "ok")
    doAssert socket.recv(1, timeout = 3000).len == 0,
      "A completed handler must return to the bounded keepalive wait."
    socket.close()

proc testBackpressure(port: Port) =
  ## Keeps every response byte available while its consumer drains slowly.
  echo "Testing response backpressure pauses HTTP read deadlines"
  let socket = connect(port, 16 * 1024)
  defer: socket.close()
  socket.request("/large")
  sleep(SlowDelay)
  let response = socket.reply()
  doAssert response.status == 200
  doAssert response.body.len == LargeResponseBytes
  doAssert response.body[0] == 'x' and response.body[^1] == 'x'

proc testWebSocket(port: Port) =
  ## Exempts upgraded connections from HTTP read inactivity limits.
  echo "Testing upgraded WebSockets ignore HTTP read deadlines"
  let socket = connect(port)
  defer: socket.close()
  socket.send("GET /websocket HTTP/1.1\r\nHost: localhost\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
    "Sec-WebSocket-Version: 13\r\n\r\n")
  doAssert socket.reply().status == 101
  sleep(SlowDelay)
  socket.send("\x81\x82\x00\x00\x00\x00hi")
  doAssert socket.recv(4, timeout = 3000) == "\x81\x02hi"

proc testDisabled(port: Port) =
  ## Retains the original unlimited wait when no timeout is configured.
  echo "Testing disabled HTTP read deadlines"
  let socket = connect(port)
  defer: socket.close()
  sleep(SlowDelay)
  socket.request()
  doAssert socket.reply() == (200, "ok")

proc testInvalidTimeouts() =
  ## Rejects values that cannot be represented by native selector timeouts.
  var values = @[-1]
  when sizeof(int) > sizeof(int32):
    values.add(int32.high.int + 1)
  for value in values:
    var rejected = false
    try:
      let server = newServer(handler, workerThreads = 2, requestTimeoutMs = value)
      server.close()
    except MummyError:
      rejected = true
    doAssert rejected

testInvalidTimeouts()
withServer(IdleTimeout, proc(port: Port) =
  testIncomplete(port)
  testProgress(port)
  testHandlers(port)
  testBackpressure(port)
  testWebSocket(port)
)
withServer(0, testDisabled)
echo "HTTP request timeout tests passed."
