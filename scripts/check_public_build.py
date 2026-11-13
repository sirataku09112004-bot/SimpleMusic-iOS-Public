"""Check a generic unsigned IPA and emit only the approved public diagnostics."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
from zipfile import ZipFile


APP = "Payload/SimpleMusic.app"
CONTROL = f"{APP}/PlugIns/SimpleMusicControls.appex"
BUNDLE_ID = "com.sirataku.simplemusic"
COPYING = (
    "opus-1.6.1/COPYING",
    "opusfile-0.12/COPYING",
    "libogg-1.3.6/COPYING",
    "libvorbis-1.3.7/COPYING",
)
IDENTIFIERS = {
    "personal signing identity": rb"com\.sirataku\.simplemusic\.[A-Z0-9]{10}\b",
    "personal filesystem path": rb"(?i)(?:[a-z]:[\\/]Users[\\/][\w.-]+|/Users/(?!runner/)[\w.-]+/|/var/mobile/Containers/)",
    "credential marker": rb"(?:-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16})",
    "device serial identifier": rb"\b[0-9]{8}-[A-F0-9]{16}\b",
}
PERSONAL_EMAIL = rb"(?i)\b[A-Z0-9._%+-]+@(?:gmail\.com|icloud\.com|outlook\.com|hotmail\.com|yahoo\.com)\b"
PRIVATE_NAMES = re.compile(
    r"(?:^|/)(?:_CodeSignature|SC_Info|Documents|Backups|xcuserdata|\.git|"
    r"embedded\.mobileprovision|embedded\.provisionprofile)(?:/|$)|"
    r"\.(?:p12|p8|pem|cer|key|jsonl|log|sqlite[\w-]*|private\.json)$",
    re.I,
)
AUDIO_EXTENSIONS = {".aac", ".aif", ".aiff", ".caf", ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav"}
SUMMARY_FIELDS = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")


class VerificationError(Exception):
    """A diagnostic message safe to print in the public job."""


def check_bytes(data, *, upstream_notice=False):
    # Swift and plist metadata can contain either byte strings or UTF-16 strings.
    text_views = (data, data.replace(b"\x00", b""))
    for label, pattern in IDENTIFIERS.items():
        if any(re.search(pattern, view) for view in text_views):
            raise VerificationError(f"IPA contains a {label}.")
    if not upstream_notice and any(re.search(PERSONAL_EMAIL, view) for view in text_views):
        raise VerificationError("IPA contains a personal email pattern.")


def verify_ipa(path, notices):
    with ZipFile(path) as ipa:
        names = ipa.namelist()
        if len(names) != len(set(names)) or ipa.testzip() is not None:
            raise VerificationError("IPA archive integrity check failed.")
        for entry in ipa.infolist():
            name = entry.filename
            if not (name == "Payload/" or name.startswith(APP + "/")):
                raise VerificationError("IPA has an unexpected bundle path.")
            if PRIVATE_NAMES.search(name) or ".." in PurePosixPath(name).parts or "\\" in name:
                raise VerificationError("IPA includes a private or invalid path.")
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise VerificationError("IPA contains an unexpected symbolic link.")
            check_bytes(name.encode())
            if entry.is_dir():
                continue
            if PurePosixPath(name).suffix.lower() in AUDIO_EXTENSIONS and name != f"{APP}/probe.wav":
                raise VerificationError("IPA includes unexpected audio data.")
            data = ipa.read(entry)
            if name == f"{APP}/ThirdPartyNotices.txt":
                if data != notices:
                    raise VerificationError("Bundled license notices differ from the verified notices.")
                check_bytes(data, upstream_notice=True)
            elif name == f"{APP}/probe.wav":
                if data != Path("SimpleMusic/probe.wav").read_bytes():
                    raise VerificationError("The packaged audio fixture differs from the generated fixture.")
            else:
                check_bytes(data)
        for bundle, identifier, executable in (
            (APP, BUNDLE_ID, "SimpleMusic"),
            (CONTROL, BUNDLE_ID + ".controls", "SimpleMusicControls"),
        ):
            info = plistlib.loads(ipa.read(f"{bundle}/Info.plist"))
            if info.get("CFBundleIdentifier") != identifier or info.get("CFBundleExecutable") != executable:
                raise VerificationError("IPA bundle identity differs from the existing installation.")
            if f"{bundle}/{executable}" not in names:
                raise VerificationError("IPA is missing an executable.")
        if f"{APP}/ThirdPartyNotices.txt" not in names or f"{APP}/probe.wav" not in names:
            raise VerificationError("IPA is missing required notices or the generated audio fixture.")


def verify_build(artifacts, raw_summary):
    notices = (artifacts / "ThirdPartyNotices.txt").read_bytes()
    if not all(f"===== {name} =====".encode() in notices for name in COPYING):
        raise VerificationError("The third-party notices are incomplete.")
    summary = json.loads(raw_summary.read_text(encoding="utf-8"))
    safe_summary = {key: summary[key] for key in SUMMARY_FIELDS if key in summary}
    if (
        any(type(value) is not int or value < 0 for value in safe_summary.values())
        or safe_summary.get("passedTests", 0) < 1
        or safe_summary.get("failedTests", -1) != 0
    ):
        raise VerificationError("Test results are missing or unsuccessful.")
    ipa = artifacts / "SimpleMusic-unsigned.ipa"
    verify_ipa(ipa, notices)
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (artifacts / "SHA256SUMS.txt").write_text(f"{digest}  {ipa.name}\n", encoding="utf-8")
    (artifacts / "test-summary.json").write_text(json.dumps(safe_summary, indent=2) + "\n", encoding="utf-8")
    print("Unsigned IPA, bundle IDs, notices, and public test summary verified.")


def diagnostics(path):
    # Xcode can include arbitrary test output and paths. Emit only source locations
    # confirmed to exist in this checkout and never print matched log text.
    locations = re.compile(r"(?:^|/)((?:SimpleMusic|Shared|Controls|Tests|TestsUI)/[\w./-]+\.(?:swift|c|h)):(\d+)(?::\d+)?:\s*error:", re.M)
    reported = set()
    for name, line in locations.findall(path.read_text(encoding="utf-8", errors="replace")):
        source = PurePosixPath(name)
        if ".." not in source.parts and Path(name).is_file():
            reported.add((name, int(line)))
    print("Xcode reported a failure. Raw diagnostics were kept on the runner.")
    for name, line in sorted(reported)[:30]:
        print(f"Error location: {name}:{line}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("artifacts", type=Path)
    verify.add_argument("summary", type=Path)
    report = subparsers.add_parser("diagnostics")
    report.add_argument("log", type=Path)
    args = parser.parse_args()
    if args.command == "diagnostics":
        diagnostics(args.log)
    else:
        try:
            verify_build(args.artifacts, args.summary)
        except VerificationError as error:
            raise SystemExit(str(error)) from None
        except Exception:
            raise SystemExit("Public artifact verification could not read the expected build output.") from None


if __name__ == "__main__":
    main()
