extends Node
## Link to the relay server (server/src/index.js) over a WebSocket. Text messages are JSON
## objects; binary messages are voice packets. Everything sent goes to everyone else in the
## same room. Reconnects by itself (with backoff) until close() is called.

signal welcomed(slot: int, peers: Array)
signal peer_joined(slot: int)
signal peer_left(slot: int)
signal received(msg: Dictionary)
signal received_bytes(data: PackedByteArray)
## "offline", "connecting", "online", or "error" (gave up; see `detail`).
signal state_changed(state: String, detail: String)

const PING_EVERY := 20.0
const CONNECT_TIMEOUT := 10.0

var state := "offline"
var detail := ""
var url := ""

var _ws: WebSocketPeer
var _want := false
var _retry_in := 0.0
var _backoff := 1.0
var _ping_in := 0.0
var _connecting_for := 0.0
var _stop_after_close := false


func open(server: String, room: String, client_id: String) -> void:
	close()
	url = "%s/room/%s?id=%s" % [server.trim_suffix("/"), room.uri_encode(), client_id.uri_encode()]
	_want = true
	_backoff = 1.0
	_connect()


func close() -> void:
	_want = false
	if _ws:
		_ws.close(1000, "leaving")
	_ws = null
	_set_state("offline")


func is_open() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN and state == "online"


func send(msg: Dictionary) -> bool:
	if not is_open():
		return false
	return _ws.send_text(JSON.stringify(msg)) == OK


func send_bytes(data: PackedByteArray) -> bool:
	if not is_open():
		return false
	return _ws.put_packet(data) == OK


func _connect() -> void:
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 18
	_ws.outbound_buffer_size = 1 << 18
	_stop_after_close = false
	var tls: TLSOptions = TLSOptions.client() if url.begins_with("wss:") else null
	var err := _ws.connect_to_url(url, tls)
	if err != OK:
		_ws = null
		_schedule_retry("couldn't start connecting (error %d)" % err)
		return
	_connecting_for = 0.0
	_set_state("connecting")
	print("Net: connecting to ", url)


func _process(delta: float) -> void:
	if _ws == null:
		if _want:
			_retry_in -= delta
			if _retry_in <= 0.0:
				_connect()
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			_connecting_for += delta
			if _connecting_for > CONNECT_TIMEOUT:
				_ws.close()
				_ws = null
				_schedule_retry("timed out")
		WebSocketPeer.STATE_OPEN:
			while _ws and _ws.get_available_packet_count() > 0:
				var data := _ws.get_packet()
				if not _ws.was_string_packet():
					received_bytes.emit(data)
					continue
				var msg: Variant = JSON.parse_string(data.get_string_from_utf8())
				if msg is Dictionary:
					_handle(msg)
			_ping_in -= delta
			if _ping_in <= 0.0 and _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				_ping_in = PING_EVERY
				_ws.send_text('{"type":"ping"}')
		WebSocketPeer.STATE_CLOSED:
			var why := "closed (%d %s)" % [_ws.get_close_code(), _ws.get_close_reason()]
			_ws = null
			if _stop_after_close:
				_want = false
				_set_state("error", detail)
			elif _want:
				_schedule_retry(why)
			else:
				_set_state("offline")


func _handle(msg: Dictionary) -> void:
	match msg.get("type", ""):
		"welcome":
			_backoff = 1.0
			_ping_in = PING_EVERY
			_set_state("online")
			var peers: Array = []
			for p: Variant in msg.get("peers", []):
				peers.append(int(p))
			welcomed.emit(int(msg.get("slot", 0)), peers)
		"peer_join":
			peer_joined.emit(int(msg.get("slot", -1)))
		"peer_leave":
			peer_left.emit(int(msg.get("slot", -1)))
		"pong":
			pass
		"error":
			# The server closes the socket next; don't keep retrying.
			detail = str(msg.get("reason", "rejected by the server"))
			_stop_after_close = true
			print("Net: ", detail)
		_:
			received.emit(msg)


func _schedule_retry(why: String) -> void:
	_retry_in = _backoff
	_backoff = minf(_backoff * 2.0, 15.0)
	_set_state("connecting", why)
	print("Net: %s; retrying in %.0f s" % [why, _retry_in])


func _set_state(new_state: String, new_detail := "") -> void:
	if new_state != "error":
		detail = new_detail
	if new_state == state and new_state != "error":
		return
	state = new_state
	state_changed.emit(state, detail)
