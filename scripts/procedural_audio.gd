extends RefCounted
class_name ProceduralAudio
## Procedural PCM audio generation for pool ball sounds.
## All functions are static — no instance needed.
## Generated streams are shared across all ball instances via static caches in pool_ball.gd.


static func generate_ball_hit() -> AudioStreamWAV:
	# Short, bright click: two high-frequency sine tones with sharp noise transient
	return _make_wav(22050, 0.12,
		3200.0, 0.5, 4800.0, 0.3,
		60.0, 0.8, 0.005, 0.0)


static func generate_wall_hit() -> AudioStreamWAV:
	# Lower thud: two low-frequency tones with moderate noise transient
	return _make_wav(22050, 0.15,
		800.0, 0.6, 1200.0, 0.3,
		35.0, 0.5, 0.008, 0.0)


static func generate_fall() -> AudioStreamWAV:
	# Falling pitch sweep with noise: freq sweeps from 600Hz down to 120Hz
	return _make_wav(22050, 0.5,
		600.0, 0.5, 0.0, 0.0,
		4.0, 0.15, 1.0, 120.0)  # noise_window=1.0 (full duration), sweep_end=120Hz


## Generate a 16-bit mono PCM AudioStreamWAV.
## freq1/amp1 and freq2/amp2: two sine tone components (set amp2=0 to disable second tone).
## decay: exponential decay rate (higher = shorter sound).
## noise_amt: amplitude of white noise added at the transient (t < noise_window).
## noise_window: how many seconds from the start the noise transient lasts.
## sweep_end_freq: if > 0, freq1 sweeps linearly from freq1 to sweep_end_freq over duration.
static func _make_wav(sample_rate: int, duration: float,
		freq1: float, amp1: float, freq2: float, amp2: float,
		decay: float, noise_amt: float, noise_window: float,
		sweep_end_freq: float) -> AudioStreamWAV:
	var samples := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t := float(i) / sample_rate
		var env := exp(-t * decay)
		var f1 := lerpf(freq1, sweep_end_freq, t / duration) if sweep_end_freq > 0.0 else freq1
		var sig := sin(t * TAU * f1) * amp1
		if amp2 > 0.0:
			sig += sin(t * TAU * freq2) * amp2
		if noise_amt > 0.0 and t < noise_window:
			sig += randf_range(-1.0, 1.0) * noise_amt
		sig *= env
		var sample := int(clampf(sig, -1.0, 1.0) * 32767.0)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream
