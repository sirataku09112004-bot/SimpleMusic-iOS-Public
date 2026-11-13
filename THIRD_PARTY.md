# 第三者ライセンス

| アプリに組み込むライブラリ | 版 | 上流のライセンス |
| --- | --- | --- |
| libopus | 1.6.1 | [COPYING](https://github.com/xiph/opus/blob/v1.6.1/COPYING)・[Opusの特許条件](https://opus-codec.org/license/) |
| opusfile | 0.12 | [COPYING](https://github.com/xiph/opusfile/blob/v0.12/COPYING) |
| libogg | 1.3.6 | [COPYING](https://github.com/xiph/ogg/blob/v1.3.6/COPYING) |
| libvorbis・libvorbisfile | 1.3.7 | [COPYING](https://github.com/xiph/vorbis/blob/v1.3.7/COPYING) |

各ライブラリはBSD系ライセンスです。ソースやバイナリを再配布するときは、対応する著作権表示、条件、免責条項を保持してください。ビルドはXiphの公式ソースアーカイブを取得し、SHA-256を照合してから静的リンクします。各アーカイブの通知を集約した `ThirdPartyNotices.txt` は、IPAのアプリ内とActions成果物に含まれます。

XcodeGen、CMake、Python、FFmpegはビルドまたはテストで利用するツールです。FFmpegは合成音のテスト素材を変換するコマンドとして実行します。アプリのアイコンとテスト音声はリポジトリ内のスクリプトで生成します。
