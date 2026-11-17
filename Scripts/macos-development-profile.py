#!/usr/bin/env python3
"""Explicit AAUV macOS Development profile checks; no provisioning or signing."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

BUNDLE = 'com.pendingname.aauv'
CONTAINER = 'iCloud.com.pendingname.aauv'
SOURCE_CAPABILITIES = {
    'com.apple.security.device.audio-input': True,
    'com.apple.developer.aps-environment': 'development',
    'com.apple.developer.icloud-container-identifiers': [CONTAINER],
    'com.apple.developer.icloud-services': ['CloudKit'],
}


class ProfileError(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise ProfileError(reason)


def command(args):
    result = subprocess.run(args, capture_output=True, timeout=60)
    require(result.returncode == 0, 'Local verification tool failed: ' + Path(args[0]).name)
    return result


def decode_profile(raw):
    require(0 < len(raw) <= 8 * 1024 * 1024, 'Profile size is invalid')
    # -noverify disables certificate-chain evaluation, not the CMS content signature.
    result = subprocess.run(['/usr/bin/openssl', 'smime', '-verify', '-inform', 'DER', '-noverify'],
                            input=raw, capture_output=True, timeout=20)
    require(result.returncode == 0, 'Profile CMS content signature verification failed')
    try:
        profile = plistlib.loads(result.stdout)
    except Exception as error:
        raise ProfileError('Profile CMS payload is not a property list') from error
    require(isinstance(profile, dict), 'Profile payload must be a dictionary')
    return profile


def string_list(value):
    return isinstance(value, list) and bool(value) and all(isinstance(x, str) and bool(x.strip()) for x in value)


def claims_for_profile(profile, identity_sha1, device_id, source, now=None):
    require(isinstance(identity_sha1, str) and re.fullmatch(r'[A-Fa-f0-9]{40}', identity_sha1) is not None,
            'Profile mode requires the explicitly approved 40-character certificate SHA-1')
    require(isinstance(device_id, str) and bool(device_id.strip()), 'An explicit registered target Mac device ID is required')
    require(source == SOURCE_CAPABILITIES and type(source.get('com.apple.security.device.audio-input')) is bool,
            'Mac source capabilities changed; review the profile policy before packaging')
    team_ids = profile.get('TeamIdentifier')
    require(isinstance(team_ids, list) and len(team_ids) == 1 and isinstance(team_ids[0], str)
            and re.fullmatch(r'[A-Z0-9]{10}', team_ids[0]) is not None, 'Profile must select one exact team')
    team = team_ids[0]
    ent = profile.get('Entitlements')
    require(isinstance(ent, dict), 'Profile entitlements are missing')
    require(ent.get('com.apple.developer.team-identifier') == team, 'Profile entitlement team does not match')
    require(ent.get('com.apple.application-identifier') == team + '.' + BUNDLE, 'Profile must authorize the exact AAUV Mac App ID')
    if 'application-identifier' in ent:
        require(ent['application-identifier'] == team + '.' + BUNDLE, 'Conflicting application identifier')
    certificates = profile.get('DeveloperCertificates')
    require(isinstance(certificates, list) and bool(certificates) and all(isinstance(x, bytes) for x in certificates),
            'Profile developer certificates are invalid')
    require(identity_sha1.upper() in {hashlib.sha1(x).hexdigest().upper() for x in certificates},
            'Approved signing certificate is not included in this profile')
    now = now or datetime.now(timezone.utc)
    expiry = profile.get('ExpirationDate')
    if isinstance(expiry, datetime) and expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    require(isinstance(expiry, datetime) and expiry > now, 'Profile has expired or has no expiry')
    platforms = profile.get('Platform')
    require(string_list(platforms) and set(platforms).issubset({'OSX', 'macOS'}), 'A macOS Development profile is required')
    devices = profile.get('ProvisionedDevices')
    require(string_list(devices) and device_id in devices, 'Profile must include the explicitly selected target Mac')
    require(profile.get('ProvisionsAllDevices', False) is False, 'An explicit Development device-list profile is required')
    require(ent.get('com.apple.developer.icloud-container-identifiers') == [CONTAINER], 'Profile iCloud container must match AAUV exactly')
    service = ent.get('com.apple.developer.icloud-services')
    require(service == '*' or (string_list(service) and 'CloudKit' in service), 'Profile does not authorize CloudKit')
    environment = ent.get('com.apple.developer.icloud-container-environment')
    require(environment == 'Development' or
            (string_list(environment) and 'Development' in environment and set(environment).issubset({'Development', 'Production'})),
            'Profile does not authorize the Development environment')
    require(ent.get('com.apple.developer.aps-environment') == 'development', 'Profile must authorize Development APNs')
    claims = dict(source)
    claims.update({'com.apple.application-identifier': team + '.' + BUNDLE,
                   'com.apple.developer.team-identifier': team,
                   'com.apple.developer.icloud-container-environment': 'Development'})
    return claims


def verify_certificate_team(profile, identity_sha1, expected_team):
    certificate = next(x for x in profile['DeveloperCertificates']
                       if hashlib.sha1(x).hexdigest().upper() == identity_sha1.upper())
    result = subprocess.run(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-noout', '-subject', '-nameopt', 'RFC2253'],
                            input=certificate, capture_output=True, timeout=20)
    require(result.returncode == 0, 'Selected public certificate is not valid DER')
    subject = result.stdout.decode().strip().removeprefix('subject=').strip()
    teams = re.findall(r'(?:^|,)OU=([A-Z0-9]{10})(?=,|$)', subject)
    require(teams == [expected_team], 'Selected public certificate team does not match the profile')


def verify_signed_app(app, raw_profile, claims, identity_sha1):
    require((app / 'Contents/embedded.provisionprofile').read_bytes() == raw_profile, 'Embedded profile differs from the verified input')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == BUNDLE, 'Signed app bundle identifier differs')
    actual = command(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
    require(plistlib.dumps(plistlib.loads(actual.stdout), fmt=plistlib.FMT_BINARY, sort_keys=True)
            == plistlib.dumps(claims, fmt=plistlib.FMT_BINARY, sort_keys=True),
            'Actual signed entitlements differ from the concrete requested claims')
    metadata = command(['/usr/bin/codesign', '-d', '--verbose=4', str(app)]).stderr.decode().splitlines()
    require('TeamIdentifier=' + claims['com.apple.developer.team-identifier'] in metadata, 'Actual signing team differs')
    require('Identifier=' + BUNDLE in metadata, 'Actual code signing identifier differs')
    with tempfile.TemporaryDirectory(prefix='aauv-public-certificate-') as temp:
        prefix = str(Path(temp) / 'certificate')
        command(['/usr/bin/codesign', '-d', '--extract-certificates=' + prefix, str(app)])
        leaf = Path(prefix + '0')
        require(leaf.is_file() and hashlib.sha1(leaf.read_bytes()).hexdigest().upper() == identity_sha1.upper(),
                'Actual public signing certificate differs from the approved SHA-1')
    arches = command(['/usr/bin/lipo', '-archs', str(app / 'Contents/MacOS/AAUV')]).stdout.decode().split()
    require(set(arches) == {'arm64', 'x86_64'}, 'Signed Mac application must contain both architectures')
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'verify'])
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--identity-sha1', required=True)
    parser.add_argument('--device-id', required=True)
    parser.add_argument('--source-entitlements', type=Path, required=True)
    parser.add_argument('--output-entitlements', type=Path)
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    try:
        raw = args.profile.read_bytes()
        source = plistlib.loads(args.source_entitlements.read_bytes())
        profile = decode_profile(raw)
        claims = claims_for_profile(profile, args.identity_sha1, args.device_id, source)
        verify_certificate_team(profile, args.identity_sha1, claims['com.apple.developer.team-identifier'])
        if args.operation == 'prepare':
            require(args.output_entitlements is not None and args.app is None, 'Prepare requires a new entitlement output only')
            with args.output_entitlements.open('xb') as f:
                f.write(plistlib.dumps(claims))
            args.output_entitlements.chmod(0o600)
        else:
            require(args.app is not None and args.output_entitlements is None, 'Verify requires the signed app only')
            verify_signed_app(args.app, raw, claims, args.identity_sha1)
        print(json.dumps({'status': 'development_profile_' + args.operation + '_passed',
                          'profileSHA256': hashlib.sha256(raw).hexdigest(), 'bundleID': BUNDLE,
                          'environment': 'Development', 'targetMacIncluded': True,
                          'concreteClaims': len(claims), 'CMSContentSignatureVerified': True,
                          'AppleProfileChainTrustAssessed': False, 'signingInvoked': False,
                          'appLaunchedOrCloudKitCalled': False}))
    except (ProfileError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        parser.exit(2, 'AAUV profile check failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
