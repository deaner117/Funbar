extends Node
## Voice chat (always on unless muted): the mic is resampled to 16 kHz, μ-law encoded, cut into
## 60 ms packets and sent through the relay as binary messages. Quiet stretches aren't sent.
## Each friend's voice plays from their avatar's head, so it comes from where they are.
##
## Packet: [sender slot, 1 (voice), seq lo, seq hi, μ-law bytes...]

const RATE := 16000
const CHUNK := 960            # 60 ms at 16 kHz
const GATE := 0.008           # RMS below this counts as silence
const HANGOVER := 0.5         # keep sending this long after speech stops (seconds)
const GAIN := 1.6
const PREBUFFER := 1600       # 100 ms of silence queued before a burst, to ride out jitter
const MAX_BUFFERED := 6400    # drop packets beyond 400 ms behind

var main: Node
var muted := false
## Mic loudness 0..1 (for the menu's level meter).
var level := 0.0
var started := false
var packets_sent := 0
var packets_received := 0

var _capture: AudioEffectCapture
var _mic: AudioStreamPlayer
var _ratio := 3.0
var _phase := 0.0
var _acc := 0.0
var _acc_n := 0
var _pending := PackedFloat32Array()
var _quiet_for := 99.0
var _seq := 0
var _decode := PackedFloat32Array()


func _ready() -> void:
	_decode.resize(256)
	for u in 256:
		_decode[u] = ulaw_decode(u)


## Starts the microphone (on Quest, only once RECORD_AUDIO has been granted).
func start() -> void:
	if started:
		_mic.stop()
		_mic.play()
		return
	var idx := AudioServer.get_bus_index("Mic")
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, "Mic")
	AudioServer.set_bus_mute(idx, true)   # don't hear yourself
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 0.5
	AudioServer.add_bus_effect(idx, _capture)
	_mic = AudioStreamPlayer.new()
	_mic.stream = AudioStreamMicrophone.new()
	_mic.bus = "Mic"
	add_child(_mic)
	_mic.play()
	_ratio = AudioServer.get_mix_rate() / float(RATE)
	started = true
	print("Voice: mic started (mix rate %d)" % AudioServer.get_mix_rate())


func _process(_delta: float) -> void:
	if not started:
		return
	var n := _capture.get_frames_available()
	if n <= 0:
		return
	var buf := _capture.get_buffer(n)
	if muted or main == null or not main.has_friends():
		level = 0.0
		_pending.clear()
		return
	feed(buf)


## Adds mic frames (at the mix rate) and sends any full packets.
func feed(buf: PackedVector2Array) -> void:
	for f in buf:
		_acc += (f.x + f.y) * 0.5
		_acc_n += 1
		_phase += 1.0
		if _phase >= _ratio:
			_phase -= _ratio
			_pending.append(_acc / _acc_n)
			_acc = 0.0
			_acc_n = 0
	while _pending.size() >= CHUNK:
		var chunk := _pending.slice(0, CHUNK)
		_pending = _pending.slice(CHUNK)
		_send_chunk(chunk)


func _send_chunk(chunk: PackedFloat32Array) -> void:
	var sum := 0.0
	for s in chunk:
		sum += s * s
	var rms := sqrt(sum / chunk.size())
	level = clampf(rms * 8.0, 0.0, 1.0)
	_quiet_for = 0.0 if rms > GATE else _quiet_for + float(CHUNK) / RATE
	if _quiet_for > HANGOVER:
		return
	var pkt := PackedByteArray()
	pkt.resize(4 + chunk.size())
	pkt[0] = clampi(main.my_slot, 0, 255)
	pkt[1] = 1
	pkt[2] = _seq & 0xFF
	pkt[3] = (_seq >> 8) & 0xFF
	_seq = (_seq + 1) & 0xFFFF
	for i in chunk.size():
		pkt[4 + i] = ulaw_encode(clampf(chunk[i] * GAIN, -1.0, 1.0))
	if main.net.send_bytes(pkt):
		packets_sent += 1


## A voice packet from a friend.
func receive(data: PackedByteArray) -> void:
	if data.size() <= 4 or data[1] != 1:
		return
	var av: Node = main.avatars.get(int(data[0]))
	if av == null:
		return
	packets_received += 1
	av.speaking_until = Time.get_ticks_msec() / 1000.0 + 0.3
	var player: AudioStreamPlayer3D = av.voice_player
	if not (player.stream is AudioStreamGenerator):
		var g := AudioStreamGenerator.new()
		g.mix_rate = RATE
		g.buffer_length = 0.5
		player.stream = g
	if not player.playing:
		player.play()
	var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		return
	var gen: AudioStreamGenerator = player.stream
	var capacity := int(gen.mix_rate * gen.buffer_length)
	var buffered := capacity - playback.get_frames_available()
	var count := data.size() - 4
	if buffered > MAX_BUFFERED:
		return
	if buffered < 320:
		var silence := PackedVector2Array()
		silence.resize(PREBUFFER)
		playback.push_buffer(silence)
	if playback.get_frames_available() < count:
		return
	var frames := PackedVector2Array()
	frames.resize(count)
	for i in count:
		var v := _decode[data[4 + i]]
		frames[i] = Vector2(v, v)
	playback.push_buffer(frames)


static func ulaw_encode(x: float) -> int:
	var s := clampi(int(x * 32767.0), -32767, 32767)
	var sign := 0
	if s < 0:
		s = -s
		sign = 0x80
	s = mini(s + 132, 32767)
	var exponent := 7
	var mask := 0x4000
	while exponent > 0 and (s & mask) == 0:
		exponent -= 1
		mask >>= 1
	var mantissa := (s >> (exponent + 3)) & 0x0F
	return ~(sign | (exponent << 4) | mantissa) & 0xFF


static func ulaw_decode(u: int) -> float:
	u = ~u & 0xFF
	var exponent := (u >> 4) & 7
	var mantissa := u & 0x0F
	var s := (((mantissa << 3) + 132) << exponent) - 132
	return (-s if (u & 0x80) != 0 else s) / 32768.0
