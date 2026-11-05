"""Package contract checks; real codesign replays are recorded separately."""
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'Scripts'))
import verify_mac_package as gate


class PackageTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.app = Path(tmp.name) / 'Cast.app'
        self.expected = dict(version='0.4.0', build=8, source='743502253ab8', team='2Q694P9U2Y')
        self.bundle(self.app, 'Cast', {'CFBundleIdentifier':'com.besttechie.cast',
                    'CFBundleShortVersionString':'0.4.0', 'CFBundleVersion':'8', 'CastGitSHA':'743502253ab8'})
        self.helper = self.app / 'Contents/Resources/Helpers/Hex.app'
        self.bundle(self.helper, 'hex', {})
        (self.app / 'Contents/Resources/cast-desktop.py').write_text('# adapter')
        (self.app / 'Contents/Frameworks/Sparkle.framework').mkdir(parents=True)

    def bundle(self, path, name, info):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/MacOS' / name).write_bytes(b'fixture')
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(info, CFBundleExecutable=name)))

    def test_valid_artifact_does_not_claim_installation_or_user_acceptance(self):
        with patch.object(gate, 'check_signature') as check:
            result = gate.verify_package(self.app, **self.expected)
        self.assertTrue(result['packageVerified'])
        self.assertEqual(result['installed'], 'not_checked')
        self.assertEqual(result['userConfirmed'], 'not_checked')
        self.assertEqual(result['hardwareAcceptance'], 'not_checked')
        self.assertEqual(result['notarization'], 'not_checked')
        self.assertEqual(check.call_args_list[1].args[1], gate.HEX_REQUIREMENT)
        self.assertIn('2Q694P9U2Y', check.call_args_list[2].args[1])

    def test_missing_hex_rejected_before_signature_commands(self):
        import shutil
        shutil.rmtree(self.helper)
        with patch.object(gate, 'check_signature') as check, self.assertRaises(gate.PackageRejected):
            gate.verify_package(self.app, **self.expected)
        check.assert_not_called()

    def test_wrong_source_rejected(self):
        with patch.object(gate, 'check_signature') as check, self.assertRaises(gate.PackageRejected):
            gate.verify_package(self.app, **dict(self.expected, source='abcdef0'))
        check.assert_not_called()

    def test_bad_sparkle_fails_with_component_evidence(self):
        with patch.object(gate, 'check_signature', side_effect=RuntimeError('Sparkle.framework: sealed resource missing')):
            with self.assertRaises(gate.PackageRejected) as caught:
                gate.verify_package(self.app, **self.expected)
        self.assertFalse(caught.exception.receipt['packageVerified'])
        self.assertIn('Sparkle', caught.exception.receipt['failure'])

    def test_wrong_hex_vendor_rejected_even_if_outer_signature_passes(self):
        def check(path, requirement=None):
            if path == self.helper: raise RuntimeError('Wrong helper team')
        with patch.object(gate, 'check_signature', side_effect=check), self.assertRaises(gate.PackageRejected):
            gate.verify_package(self.app, **self.expected)

    def test_executable_cannot_escape_bundle(self):
        binary=self.helper / 'Contents/MacOS/hex';binary.unlink()
        outside=self.app.parent/'other';outside.write_bytes(b'not the helper');binary.symlink_to(outside)
        with patch.object(gate, 'check_signature'), self.assertRaises(gate.PackageRejected):
            gate.verify_package(self.app, **self.expected)


if __name__ == '__main__': unittest.main()
