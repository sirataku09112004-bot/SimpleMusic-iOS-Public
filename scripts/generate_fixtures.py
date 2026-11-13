"""CI-only original format fixtures. FFmpeg is not linked or shipped in the app."""
import pathlib
import shutil
import subprocess
import math
import struct
import wave

root = pathlib.Path(__file__).resolve().parents[1]
target = root / "Tests" / "Fixtures"
target.mkdir(parents=True, exist_ok=True)
source = root / "SimpleMusic" / "probe.wav"
shutil.copyfile(source, target / "fixture.wav")
for ext, codec in [("mp3", "libmp3lame"), ("m4a", "aac"), ("aac", "aac"), ("flac", "flac")]:
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
                    "-c:a", codec, str(target / f"fixture.{ext}")], check=True)

subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
                "-c:a", "libopus", "-b:a", "64k", str(target / "fixture.opus")], check=True)
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                "aevalsrc=0.1*sin(2*PI*440*t)|0.1*sin(2*PI*660*t):s=48000:d=2",
                "-c:a", "libopus", "-b:a", "128k", str(target / "stereo.opus")], check=True)
(target / "chain.opus").write_bytes((target / "fixture.opus").read_bytes() + (target / "stereo.opus").read_bytes())
(target / "corrupt.opus").write_bytes(b"invalid Opus input")
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                "aevalsrc=0.1*sin(2*PI*if(lt(t\\,10)\\,330\\,if(lt(t\\,20)\\,990\\,1650))*t):s=48000:d=30",
                "-c:a", "libopus", str(target / "seek-markers.opus")], check=True)

# Tagged originals exercise native ID3/MP4/RIFF and Vorbis Comment paths.
for ext, codec in [("opus", "libopus"), ("mp3", "libmp3lame"), ("m4a", "aac"), ("flac", "flac"), ("wav", "pcm_s16le"), ("ogg", "vorbis")]:
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
                    "-metadata", "artist=日本語 Artist & ☆ / テスト", "-metadata", "album_artist=WRONG ALBUM ARTIST",
                    "-c:a", codec, *(["-strict", "-2", "-ac", "2"] if ext == "ogg" else []), str(target / f"tagged.{ext}")], check=True)
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:sample_rate=48000:duration=30", "-c:a", "libopus",
                str(target / "long.opus")], check=True)

subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                "aevalsrc=0.1*sin(2*PI*if(lt(t\\,10)\\,330\\,if(lt(t\\,20)\\,990\\,1650))*t)|0.1*sin(2*PI*660*t):s=44100:d=30",
                "-c:a", "vorbis", "-strict", "-2", str(target / "seek-vorbis.ogg")], check=True)
(target / "chain-vorbis.ogg").write_bytes((target / "tagged.ogg").read_bytes() + (target / "seek-vorbis.ogg").read_bytes())
for name, amplitude in [("quiet", 0.04), ("loud", 0.4), ("silent", 0)]:
    with wave.open(str(target / f"{name}.wav"), "wb") as wav:
        wav.setparams((1, 2, 44100, 0, "NONE", "not compressed"))
        wav.writeframes(b"".join(struct.pack("<h", int(32767 * amplitude * math.sin(2 * math.pi * 440 * i / 44100))) for i in range(88200)))
