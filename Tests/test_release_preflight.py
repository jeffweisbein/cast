"""Exercise the release boundary without accessing signing keys or uploading anything."""
import contextlib
import importlib.util
import io
import pathlib
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'Scripts'))

spec = importlib.util.spec_from_file_location("cast_release", pathlib.Path(__file__).parents[1] / "Scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleasePreflightTests(unittest.TestCase):
    def invoke(self, args, runner):
        with patch.object(sys, "argv", ["release.py", *args]), patch.object(release, "run", runner), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                release.main()
        self.assertEqual(caught.exception.code, 2)

    def test_missing_signing_identity_never_builds_or_installs(self):
        calls = []
        def runner(*args, **kwargs):
            calls.append(args)
            return "" if args[0] == "git" else "0 valid identities found"
        self.invoke(["install-mac", "--version", "0.2.0", "--build", "4", "--team", "ABCDEFGHIJ"], runner)
        self.assertEqual([call[0] for call in calls], ["git", "security"])

    def test_dirty_checkout_stops_before_signing_or_build(self):
        calls = []
        def runner(*args, **kwargs):
            calls.append(args)
            return " M Sources/App.swift"
        self.invoke(["mac", "--version", "0.2.0", "--build", "4", "--team", "ABCDEFGHIJ"], runner)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "git")

    def test_feed_credentials_rejected_before_any_command(self):
        def forbidden(*args, **kwargs):
            self.fail("Invalid feed must fail before external commands")
        self.invoke(["mac", "--version", "0.2.0", "--build", "4", "--team", "ABCDEFGHIJ",
                     "--feed-url", "https://user:password@updates.test/a", "--update-public-key", "invalid"], forbidden)

    def test_testflight_upload_cannot_be_used_on_mac_path(self):
        def forbidden(*args, **kwargs):
            self.fail("Invalid upload request must fail before external commands")
        self.invoke(["mac", "--version", "0.2.0", "--build", "4", "--team", "ABCDEFGHIJ", "--upload-testflight"], forbidden)

    def test_invalid_package_never_replaces_existing_install(self):
        self.exercise_install(reject=True)

    def test_valid_package_installs_with_separate_receipt(self):
        self.exercise_install(reject=False)

    def test_staged_rejection_preserves_existing_install(self):
        self.exercise_install(reject=False, fail_at=2)

    def test_post_replace_rejection_restores_previous_app(self):
        self.exercise_install(reject=False, fail_at=3)

    def exercise_install(self, reject, fail_at=None):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp); home=root/'home'; target=home/'Applications/Cast.app'
            target.mkdir(parents=True);(target/'old').write_text('preserve me')
            calls=[]
            def runner(*args, **kwargs):
                calls.append(args)
                if args[:3]==('git','status','--porcelain'):return ''
                if args[0]=='security':return ' 1) '+'A'*40+' "Apple Development: Fixture (ABCDEFGHIJ)"'
                if args[:2]==('git','rev-parse'):return 'abcdef123456'
                if args[0]=='xcodebuild':
                    app=root/'build/install-mac-0.4.0-8-abcdef123456/DerivedData/Build/Products/Release/Cast.app'
                    app.mkdir(parents=True);(app/'new').write_text('candidate')
                if args[0]=='ditto':shutil.copytree(args[1],args[2])
                return ''
            verification_calls=[]
            def verify(app, **kwargs):
                verification_calls.append(str(app))
                if reject or len(verification_calls)==fail_at:raise RuntimeError('Sparkle.framework: a sealed resource is missing')
                return {'packageVerified':True,'sha256':{'cast':'fixture'},'installed':'not_checked','userConfirmed':'not_checked'}
            argv=['release.py','install-mac','--version','0.4.0','--build','8','--team','ABCDEFGHIJ','--hex-app',str(root/'Hex.app')]
            with patch.object(sys,'argv',argv), patch.object(release,'ROOT',root), \
                 patch.object(release,'run',side_effect=runner), patch.object(release,'verify_helper'), \
                 patch.object(release,'verify_package',side_effect=verify), \
                 patch.object(pathlib.Path,'home',return_value=home), \
                 patch.object(release.subprocess,'run',return_value=type('Result',(),{'returncode':1})()), \
                 contextlib.redirect_stdout(io.StringIO()):
                if reject or fail_at:
                    with self.assertRaisesRegex(RuntimeError,'Sparkle'):release.main()
                else:release.main()
            if reject or fail_at:
                self.assertEqual((target/'old').read_text(),'preserve me')
                if reject:self.assertFalse(any(c[0]=='ditto' for c in calls))
                self.assertFalse((root/'build/install-mac-0.4.0-8-abcdef123456/installation-verification.json').exists())
            else:
                import json
                receipt=json.loads((root/'build/install-mac-0.4.0-8-abcdef123456/installation-verification.json').read_text())
                self.assertTrue(receipt['installed']);self.assertEqual(receipt['userConfirmed'],'not_checked')
                self.assertEqual((pathlib.Path(receipt['backup'])/'old').read_text(),'preserve me')
                self.assertTrue((target/'new').is_file())


if __name__ == "__main__":
    unittest.main()
