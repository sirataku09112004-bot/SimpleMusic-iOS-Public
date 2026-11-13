"""Generate an original 2-second quiet PCM WAV; no external audio assets."""
import math
import pathlib
import struct
import wave

target = pathlib.Path(__file__).resolve().parents[1] / "SimpleMusic" / "probe.wav"
target.parent.mkdir(parents=True, exist_ok=True)
rate = 44100
with wave.open(str(target), "wb") as wav:
    wav.setparams((1, 2, rate, 0, "NONE", "not compressed"))
    for i in range(rate * 2):
        fade = min(1.0, i / 2205, (rate * 2 - 1 - i) / 2205)
        value = int(32767 * 0.25 * fade * math.sin(2 * math.pi * 440 * i / rate))
        wav.writeframesraw(struct.pack("<h", value))
print(target)
