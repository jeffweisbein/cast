#!/usr/bin/env python3
"""Read-only Mac package gate. A pass is artifact evidence, not user acceptance."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

HEX_REQUIREMENT = '=anchor apple generic and identifier "anomaly.hex" and certificate leaf[subject.OU] = "5NZ4Q7NXJ4"'


class PackageRejected(RuntimeError):
    def __init__(self, receipt):
        self.receipt = receipt
        super().__init__(receipt['failure'])


def check_signature(path, requirement=None):
    args = ['/usr/bin/codesign', '--verify', '--deep', '--strict']
    if requirement:
        args += ['-R', requirement]
    result = subprocess.run([*args, str(path)], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"Signature rejected for {path.name}: {result.stderr.strip()[:6000]}. "
                           "Inspect the named component; repair/sign the affected framework and outer app only. "
                           "Never recursively re-sign vendor helpers or replace the installed app on failure.")


def verify_helper(path):
    check_signature(path, HEX_REQUIREMENT)


def executable(bundle):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    name = info['CFBundleExecutable']
    if not isinstance(name, str) or Path(name).name != name or name in ('', '.', '..'):
        raise ValueError('Invalid bundle executable name')
    binary = (bundle / 'Contents/MacOS' / name).resolve(strict=True)
    if bundle.resolve() not in binary.parents:
        raise ValueError('Executable escapes its bundle')
    return binary


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_package(app, *, version, build, source, team):
    app = Path(app).resolve()
    receipt = {'schema': 1, 'app': str(app), 'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'packageVerified': False, 'installed': 'not_checked', 'userConfirmed': 'not_checked',
               'notarization': 'not_checked', 'hardwareAcceptance': 'not_checked', 'checks': []}
    try:
        if not re.fullmatch(r'[A-Z0-9]{10}', team) or not re.fullmatch(r'[a-f0-9]{7,40}', source):
            raise ValueError('Expected team/source identity is invalid')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        expected = {'CFBundleIdentifier': 'com.besttechie.cast', 'CFBundleShortVersionString': version,
                    'CFBundleVersion': str(build), 'CastGitSHA': source}
        if any(info.get(k) != v for k, v in expected.items()):
            raise ValueError('Package version/build/source/bundle ID differs from the expected candidate')
        receipt['metadata'] = expected
        receipt['checks'].append('metadata')
        helper = app / 'Contents/Resources/Helpers/Hex.app'
        adapter = app / 'Contents/Resources/cast-desktop.py'
        framework = app / 'Contents/Frameworks/Sparkle.framework'
        if not helper.is_dir() or not adapter.is_file() or not framework.is_dir():
            raise ValueError('Packaged Hex, desktop adapter and Sparkle are required; use --hex-app with release.py')
        # Name the failing component before the outer seal, including unsigned-build header stripping.
        check_signature(framework)
        receipt['checks'].append('sparkle_signature')
        verify_helper(helper)
        receipt['checks'].append('hex_vendor_signature')
        check_signature(app, f'=anchor apple generic and identifier "com.besttechie.cast" and certificate leaf[subject.OU] = "{team}"')
        receipt['checks'].append('cast_signature')
        receipt['sha256'] = {'cast': sha256(executable(app)), 'hex': sha256(executable(helper)),
                             'desktopAdapter': sha256(adapter)}
        receipt['packageVerified'] = True
        return receipt
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired, plistlib.InvalidFileException) as error:
        receipt['failure'] = str(error)
        raise PackageRejected(receipt) from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True, type=int)
    parser.add_argument('--source', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    try:
        receipt = verify_package(args.app, version=args.version, build=args.build, source=args.source, team=args.team)
    except PackageRejected as error:
        receipt = error.receipt
    rendered = json.dumps(receipt, indent=2) + '\n'
    if args.receipt:
        # Never overwrite earlier proof, especially a failed attempt.
        with args.receipt.open('x') as output:
            output.write(rendered)
    print(rendered, end='')
    return 0 if receipt['packageVerified'] else 1


if __name__ == '__main__':
    sys.exit(main())
