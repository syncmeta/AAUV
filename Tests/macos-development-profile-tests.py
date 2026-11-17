#!/usr/bin/env python3
"""Targeted profile/signature policy regressions; never signs or launches an app.

Optional real input is supplied explicitly through AAUV_TEST_MAC_PROFILE,
AAUV_TEST_SIGNING_SHA1 and AAUV_TEST_MAC_DEVICE_ID. No cache or Keychain scan.
AAUV_TEST_SIGNED_MAC_APP additionally enables read-only post-signature checks.
"""
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('macos_development_profile', ROOT/'Scripts/macos-development-profile.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
CERTIFICATE = b'synthetic-public-certificate'
IDENTITY = hashlib.sha1(CERTIFICATE).hexdigest().upper()
NOW = datetime(2030, 1, 1, tzinfo=timezone.utc)


def profile():
    return {'TeamIdentifier':['SYNTHETIC1'], 'DeveloperCertificates':[CERTIFICATE],
            'ExpirationDate':NOW+timedelta(days=1), 'Platform':['OSX'],
            'ProvisionedDevices':['SYNTHETIC-MAC'],
            'Entitlements':{
                'com.apple.application-identifier':'SYNTHETIC1.com.pendingname.aauv',
                'com.apple.developer.team-identifier':'SYNTHETIC1',
                'com.apple.developer.icloud-container-identifiers':[helper.CONTAINER],
                'com.apple.developer.icloud-services':'*',
                'com.apple.developer.icloud-container-environment':['Production','Development'],
                'com.apple.developer.aps-environment':'development'}}


class ProfilePolicyTests(unittest.TestCase):
    def test_authorization_choices_become_concrete_signature_claims(self):
        claims = helper.claims_for_profile(profile(), IDENTITY, 'SYNTHETIC-MAC', dict(helper.SOURCE_CAPABILITIES), NOW)
        self.assertEqual(len(claims), 7)
        self.assertEqual(claims['com.apple.developer.icloud-services'], ['CloudKit'])
        self.assertEqual(claims['com.apple.developer.icloud-container-environment'], 'Development')
        self.assertNotIn('com.apple.security.get-task-allow', claims)
        for services, environment in [(['CloudKit'],'Development'), (['CloudKit','CloudDocuments'],['Development'])]:
            value = profile()
            value['Entitlements']['com.apple.developer.icloud-services'] = services
            value['Entitlements']['com.apple.developer.icloud-container-environment'] = environment
            self.assertEqual(helper.claims_for_profile(value, IDENTITY, 'SYNTHETIC-MAC', dict(helper.SOURCE_CAPABILITIES), NOW), claims)

    def test_incompatible_profiles_reject_before_signing(self):
        mutations = [
            ('team', lambda p:p.update(TeamIdentifier=['DIFFERENT1'])),
            ('entitlement-team', lambda p:p['Entitlements'].update({'com.apple.developer.team-identifier':'DIFFERENT1'})),
            ('wildcard-app', lambda p:p['Entitlements'].update({'com.apple.application-identifier':'SYNTHETIC1.*'})),
            ('other-app', lambda p:p['Entitlements'].update({'com.apple.application-identifier':'SYNTHETIC1.com.pendingname.other'})),
            ('conflicting-alias', lambda p:p['Entitlements'].update({'application-identifier':'SYNTHETIC1.other'})),
            ('certificate', lambda p:p.update(DeveloperCertificates=[b'other-public-certificate'])),
            ('certificate-type', lambda p:p.update(DeveloperCertificates=['not-DER'])),
            ('expired', lambda p:p.update(ExpirationDate=NOW)),
            ('platform', lambda p:p.update(Platform=['iOS'])),
            ('mixed-platform', lambda p:p.update(Platform=['OSX','iOS'])),
            ('empty-device-list', lambda p:p.update(ProvisionedDevices=[])),
            ('other-device', lambda p:p.update(ProvisionedDevices=['OTHER-MAC'])),
            ('all-devices', lambda p:p.update(ProvisionsAllDevices=True)),
            ('container-wildcard', lambda p:p['Entitlements'].update({'com.apple.developer.icloud-container-identifiers':['*']})),
            ('extra-container', lambda p:p['Entitlements'].update({'com.apple.developer.icloud-container-identifiers':[helper.CONTAINER,'iCloud.other']})),
            ('service-not-cloudkit', lambda p:p['Entitlements'].update({'com.apple.developer.icloud-services':['CloudDocuments']})),
            ('service-malformed', lambda p:p['Entitlements'].update({'com.apple.developer.icloud-services':['CloudKit',1]})),
            ('production-only', lambda p:p['Entitlements'].update({'com.apple.developer.icloud-container-environment':['Production']})),
            ('environment-wildcard', lambda p:p['Entitlements'].update({'com.apple.developer.icloud-container-environment':['*','Development']})),
            ('production-push', lambda p:p['Entitlements'].update({'com.apple.developer.aps-environment':'production'})),
        ]
        for label, mutate in mutations:
            with self.subTest(label=label):
                value = copy.deepcopy(profile())
                mutate(value)
                with self.assertRaises(helper.ProfileError):
                    helper.claims_for_profile(value, IDENTITY, 'SYNTHETIC-MAC', dict(helper.SOURCE_CAPABILITIES), NOW)

    def test_identity_device_and_source_require_explicit_concrete_values(self):
        for identity in ['-', 'Apple Development: NAME', 'F'*39, 'G'*40]:
            with self.subTest(identity=identity), self.assertRaises(helper.ProfileError):
                helper.claims_for_profile(profile(), identity, 'SYNTHETIC-MAC', dict(helper.SOURCE_CAPABILITIES), NOW)
        with self.assertRaises(helper.ProfileError):
            helper.claims_for_profile(profile(), IDENTITY, '', dict(helper.SOURCE_CAPABILITIES), NOW)
        source = dict(helper.SOURCE_CAPABILITIES, **{'com.apple.security.device.audio-input':1})
        with self.assertRaises(helper.ProfileError):
            helper.claims_for_profile(profile(), IDENTITY, 'SYNTHETIC-MAC', source, NOW)

    def test_raw_unsigned_plist_is_not_a_cms_profile(self):
        with self.assertRaises(helper.ProfileError):
            helper.decode_profile(plistlib.dumps(profile()))

    def test_post_sign_gate_rejects_entitlement_type_coercion_before_further_checks(self):
        claims = helper.claims_for_profile(profile(), IDENTITY, 'SYNTHETIC-MAC', dict(helper.SOURCE_CAPABILITIES), NOW)
        actual = dict(claims, **{'com.apple.security.device.audio-input':1})
        with tempfile.TemporaryDirectory(prefix='aauv-claim-type-test-') as temp:
            app = Path(temp)/'app'
            (app/'Contents').mkdir(parents=True)
            (app/'Contents/embedded.provisionprofile').write_bytes(b'synthetic-profile')
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':helper.BUNDLE}))
            output = subprocess.CompletedProcess([], 0, stdout=plistlib.dumps(actual), stderr=b'')
            with patch.object(helper, 'command', return_value=output) as commands:
                with self.assertRaises(helper.ProfileError):
                    helper.verify_signed_app(app, b'synthetic-profile', claims, IDENTITY)
                self.assertEqual(commands.call_count, 1)

    def test_existing_output_is_preserved_before_any_build(self):
        with tempfile.TemporaryDirectory(prefix='aauv-profile-test-') as temp:
            path = Path(temp)/'old package.zip'
            path.write_bytes(b'preserve-existing-output')
            result = subprocess.run(['/bin/sh', str(ROOT/'Scripts/package-macos.sh'), str(path)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), b'preserve-existing-output')
            self.assertIn(b'never replaced', result.stderr)

    def test_local_mode_still_reaches_build_without_profile_or_identity(self):
        with tempfile.TemporaryDirectory(prefix='aauv-local-mode-test-') as temp:
            folder = Path(temp)
            stub = folder/'xcodebuild'
            stub.write_text('#!/bin/sh\nexit 97\n')
            stub.chmod(0o755)
            env = {k:v for k,v in os.environ.items() if not k.startswith('AAUV_MAC_')}
            env['PATH'] = str(folder)+os.pathsep+os.environ['PATH']
            result = subprocess.run(['/bin/sh', str(ROOT/'Scripts/package-macos.sh'), str(folder/'new.zip')],
                                    env=env, capture_output=True)
            self.assertEqual(result.returncode, 97)
            self.assertFalse((folder/'new.zip').exists())


REAL_NAMES = ['AAUV_TEST_MAC_PROFILE','AAUV_TEST_SIGNING_SHA1','AAUV_TEST_MAC_DEVICE_ID']
REAL = all(os.environ.get(x) for x in REAL_NAMES)


@unittest.skipUnless(REAL, 'Optional explicit genuine profile inputs were not supplied')
class RealProfileTests(unittest.TestCase):
    def setUp(self):
        self.raw = Path(os.environ[REAL_NAMES[0]]).read_bytes()
        self.identity = os.environ[REAL_NAMES[1]]
        self.device = os.environ[REAL_NAMES[2]]
        self.source = plistlib.loads((ROOT/'AAUV-App-macOS.entitlements').read_bytes())

    def test_genuine_cms_and_exact_authorization(self):
        profile = helper.decode_profile(self.raw)
        claims = helper.claims_for_profile(profile, self.identity, self.device, self.source)
        helper.verify_certificate_team(profile, self.identity, claims['com.apple.developer.team-identifier'])
        self.assertEqual(len(claims), 7)
        self.assertEqual(claims['com.apple.developer.icloud-container-environment'], 'Development')

    def test_actual_certificate_cannot_authorize_a_different_team(self):
        with self.assertRaises(helper.ProfileError):
            helper.verify_certificate_team(helper.decode_profile(self.raw), self.identity, 'DIFFERENT1')

    def test_changed_genuine_signed_payload_fails_cms(self):
        offset = self.raw.index(b'com.pendingname.aauv')
        corrupt = bytearray(self.raw)
        corrupt[offset] ^= 1
        with self.assertRaises(helper.ProfileError):
            helper.decode_profile(bytes(corrupt))

    def test_real_profile_rejects_unapproved_certificate(self):
        with self.assertRaises(helper.ProfileError):
            helper.claims_for_profile(helper.decode_profile(self.raw), '0'*40, self.device, self.source)

    def test_shell_profile_preflight_runs_before_build_without_signing(self):
        with tempfile.TemporaryDirectory(prefix='aauv-profile-test-') as temp:
            folder = Path(temp)
            bin_dir = folder/'bin'
            bin_dir.mkdir()
            called = folder/'build-started'
            stub = bin_dir/'xcodebuild'
            stub.write_text('#!/bin/sh\ntouch "$AAUV_TEST_BUILD_MARKER"\nexit 97\n')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
                       AAUV_MAC_PROVISIONING_PROFILE=os.environ[REAL_NAMES[0]],
                       AAUV_MAC_SIGNING_IDENTITY=self.identity, AAUV_MAC_DEVICE_ID=self.device,
                       AAUV_TEST_BUILD_MARKER=str(called))
            args = ['/bin/sh', str(ROOT/'Scripts/package-macos.sh'), str(folder/'new.zip')]
            good = subprocess.run(args, env=env, capture_output=True)
            self.assertEqual(good.returncode, 97)
            self.assertTrue(called.is_file())
            self.assertIn(b'development_profile_prepare_passed', good.stdout)
            called.unlink()
            env['AAUV_MAC_SIGNING_IDENTITY'] = '0'*40
            bad = subprocess.run(args, env=env, capture_output=True)
            self.assertEqual(bad.returncode, 2)
            self.assertFalse(called.exists())
            self.assertFalse((folder/'new.zip').exists())

    @unittest.skipUnless(os.environ.get('AAUV_TEST_SIGNED_MAC_APP'), 'Optional preexisting signed app not supplied')
    def test_preexisting_signed_candidate_passes_real_post_sign_gate_read_only(self):
        claims = helper.claims_for_profile(helper.decode_profile(self.raw), self.identity, self.device, self.source)
        helper.verify_signed_app(Path(os.environ['AAUV_TEST_SIGNED_MAC_APP']), self.raw, claims, self.identity)


if __name__ == '__main__':
    if any(os.environ.get(x) for x in REAL_NAMES) and not REAL:
        raise SystemExit('Supply all three explicit real-profile test inputs, or none.')
    unittest.main()
