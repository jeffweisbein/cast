#!/usr/bin/env python3
"""Reproducible signed releases. Credentials stay in Xcode/Keychain, never CLI args."""
import argparse
import datetime
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from verify_mac_package import PackageRejected, verify_helper, verify_package

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args, capture=False):
    return subprocess.run(args, cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def verify_and_record(app, path, expected):
    try:
        receipt = verify_package(app, **expected)
    except PackageRejected as error:
        path.write_text(json.dumps(error.receipt, indent=2))
        raise
    path.write_text(json.dumps(receipt, indent=2))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["mac", "ios", "install-mac"])
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--team", required=True, help="Apple team ID, not a credential")
    parser.add_argument("--notary-profile", help="Existing Keychain notarytool profile name")
    parser.add_argument("--upload-testflight", action="store_true")
    parser.add_argument("--feed-url", default="", help="Public HTTPS Sparkle appcast URL")
    parser.add_argument("--update-public-key", default="", help="Public Ed25519 key only")
    parser.add_argument("--hex-app", type=pathlib.Path, help="Vendor-signed Hex.app to embed (required for Mac)")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or args.build < 1:
        parser.error("Use a three-part version and positive build number.")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("Use the 10-character Apple team ID.")
    if args.upload_testflight and args.platform != "ios":
        parser.error("TestFlight upload is iOS only.")
    if args.notary_profile and args.platform != "mac":
        parser.error("Notarization is for the mac distribution archive only.")
    if args.hex_app and args.platform == "ios":
        parser.error("The Hex executable is Mac-only; iOS uses native speech recognition.")
    if bool(args.feed_url) != bool(args.update_public_key):
        parser.error("The update feed and public key must be supplied together.")
    if args.feed_url:
        from urllib.parse import urlsplit
        import base64
        url = urlsplit(args.feed_url)
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment:
            parser.error("Use a public HTTPS feed URL without credentials or query parameters.")
        try:
            valid_key = len(base64.b64decode(args.update_public_key, validate=True)) == 32
        except ValueError:
            valid_key = False
        if not valid_key:
            parser.error("The update public key must encode 32 bytes.")
    dirty = run("git", "status", "--porcelain", capture=True)
    if dirty.strip():
        parser.error("Commit your changes first so the release has reproducible source metadata.")
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
    required = "Apple Development" if args.platform == "install-mac" else ("Developer ID Application" if args.platform == "mac" else "Apple Distribution")
    matching = [re.search(r'\b[A-F0-9]{40}\b', line) for line in identities.splitlines()
                if required in line and f"({args.team})" in line and 'REVOKED' not in line]
    signing_identity = next((match.group() for match in matching if match), None)
    if not signing_identity:
        parser.error(f"Missing {required} identity for this team. Configure signing in Xcode/Keychain first.")
    if args.platform != "ios":
        if not args.hex_app:
            parser.error("Mac releases require --hex-app /path/to/vendor-signed/Hex.app.")
        args.hex_app = args.hex_app.expanduser().resolve()
        verify_helper(args.hex_app)
        run("sh", "Scripts/verify-regressions.sh")
    sha = run("git", "rev-parse", "--short=12", "HEAD", capture=True).strip()
    out = ROOT / "build" / f"{args.platform}-{args.version}-{args.build}-{sha}"
    if out.exists():
        parser.error(f"Output already exists: {out}. Use a new build number; previous evidence is preserved.")
    out.mkdir(parents=True)
    run("Scripts/generate-project.sh")
    settings = [f"MARKETING_VERSION={args.version}", f"CURRENT_PROJECT_VERSION={args.build}",
                f"DEVELOPMENT_TEAM={args.team}", f"CAST_GIT_SHA={sha}",
                f"CAST_UPDATE_FEED_URL={args.feed_url}", f"CAST_UPDATE_PUBLIC_KEY={args.update_public_key}"]
    if args.platform == "ios":
        # TestFlight/App Store tokens use production APNs, never the development sandbox.
        settings.append("CAST_APNS_ENVIRONMENT=production")
    scheme = "Cast-iOS" if args.platform == "ios" else "Cast-macOS"
    common = ["xcodebuild", "-project", "Cast.xcodeproj", "-scheme", scheme,
              "-configuration", "Release", "-derivedDataPath", str(out / "DerivedData")]
    if args.platform == "install-mac":
        run(*common, "-destination", "platform=macOS", "build", *settings)
        app = out / "DerivedData/Build/Products/Release/Cast.app"
    else:
        archive = out / "Cast.xcarchive"
        destination = "generic/platform=iOS" if args.platform == "ios" else "generic/platform=macOS"
        # iOS automatic signing chooses the archive identity. Forcing Distribution here
        # conflicts with app/extension and SPM resource targets; exportArchive applies
        # the App Store profile and distribution identity to the finished archive.
        archive_signing = [] if args.platform == "ios" else [f"CODE_SIGN_IDENTITY={required}"]
        run(*common, "-destination", destination, "-archivePath", str(archive), "-allowProvisioningUpdates",
            "archive", *settings, *archive_signing, "ENABLE_HARDENED_RUNTIME=YES")
        options = {"method": "app-store-connect" if args.platform == "ios" else "developer-id",
                   "teamID": args.team, "signingStyle": "automatic"}
        if args.platform == "ios":
            options.update(destination="upload" if args.upload_testflight else "export", manageAppVersionAndBuildNumber=False)
        export_plist = out / "ExportOptions.plist"
        export_plist.write_bytes(plistlib.dumps(options))
        run("xcodebuild", "-exportArchive", "-archivePath", str(archive),
            "-exportPath", str(out / "export"), "-exportOptionsPlist", str(export_plist),
            "-allowProvisioningUpdates")
        if args.platform == "ios":
            print(f"{'Uploaded for TestFlight processing' if args.upload_testflight else 'Exported for review'}: {out}")
            return
        app = out / "export/Cast.app"
    run("Scripts/embed-hex.sh", str(app), str(args.hex_app))
    # Xcode signs frameworks. Re-seal only the outer app after embedding Hex;
    # preserving entitlements/runtime flags and the helper's original identity.
    run("codesign", "--force", "--sign", signing_identity,
        "--preserve-metadata=identifier,entitlements,flags", str(app))
    expected = dict(version=args.version, build=args.build, source=sha, team=args.team)
    receipt = verify_and_record(app, out / "package-verification.json", expected)
    if args.platform == "install-mac":
        if subprocess.run(["pgrep", "-x", "Cast"], stdout=subprocess.DEVNULL).returncode == 0:
            raise RuntimeError("Quit Cast before installation; the running app has been left untouched.")
        target = pathlib.Path.home() / "Applications/Cast.app"
        target.parent.mkdir(exist_ok=True)
        staging = pathlib.Path(tempfile.mkdtemp(prefix="Cast-install-", dir=target.parent))
        staged_app = staging / "Cast.app"
        run("ditto", str(app), str(staged_app))
        staged_receipt = verify_and_record(staged_app, out / "staged-verification.json", expected)
        if staged_receipt['sha256'] != receipt['sha256']:
            raise RuntimeError("Staged package differs from verified candidate; installed app is unchanged.")
        backup = None
        if target.exists():
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            backup = target.with_name(f"Cast-backup-{stamp}.app")
            if backup.exists():
                raise RuntimeError("A backup already exists for this timestamp. Previous app is unchanged.")
            target.rename(backup)
        try:
            staged_app.rename(target)
            installed_receipt = verify_and_record(target, out / "installed-package-verification.json", expected)
            if installed_receipt['sha256'] != receipt['sha256']:
                raise RuntimeError("Installed package identity changed")
        except (OSError, RuntimeError):
            if target.exists() and not staged_app.exists():
                target.rename(staged_app)
            if backup is not None:
                backup.rename(target)
            raise
        staging.rmdir()
        installed_receipt.update(installed=True, backup=str(backup) if backup else None)
        (out / "installation-verification.json").write_text(json.dumps(installed_receipt, indent=2))
        print(f"Installed signed build: {target}. Previous app preserved; pairing data untouched.")
        return
    package = out / f"Cast-{args.version}-{args.build}.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(package))
    if args.notary_profile:
        run("xcrun", "notarytool", "submit", str(package), "--keychain-profile", args.notary_profile, "--wait")
        run("xcrun", "stapler", "staple", str(app))
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "--assess", "--type", "execute", str(app))
        package.unlink()  # Only the just-created unstapled archive; preserve prior releases.
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(package))
        print(f"Notarized release ready: {package}")
    else:
        print(f"Signed archive only, NOT notarized or ready for distribution: {package}")


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        sys.exit(str(error))
