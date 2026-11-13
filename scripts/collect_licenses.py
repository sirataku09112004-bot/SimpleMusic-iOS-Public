"""Bundle complete licenses and patent notices from the exact verified archives."""
from pathlib import Path
import hashlib

root = Path('build/codec-sources')
parts = ['SimpleMusic third-party notices\n\nlibopus 1.6.1, libopusfile 0.12, libogg 1.3.6, libvorbis 1.3.7.\n'
         'Sources: https://downloads.xiph.org/\nOpus information: https://opus-codec.org/license/\n'
         'HTTP/opusurl, OpenSSL, learned model features, and FFmpeg are not included in the app.\n']
for name in ['opus-1.6.1', 'opusfile-0.12', 'libogg-1.3.6', 'libvorbis-1.3.7']:
    folder = root / name
    selected = [p for p in folder.rglob('*') if p.is_file() and
                (p.name.startswith(('COPYING', 'LICENSE')) or 'PATENT' in p.name.upper())]
    assert folder.joinpath('COPYING') in selected
    for file in sorted(selected):
        content = file.read_text(errors='strict')
        parts.append(f'\n\n===== {name}/{file.relative_to(folder)} =====\n{content}')
text = '\n'.join(parts)
Path('SimpleMusic/Licenses').mkdir(parents=True, exist_ok=True)
Path('SimpleMusic/Licenses/ThirdPartyNotices.txt').write_text(text)
Path('artifacts/ThirdPartyNotices.txt').write_text(text)
print('Bundled license bytes:', len(text.encode()), 'SHA256:', hashlib.sha256(text.encode()).hexdigest())
