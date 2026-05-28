#!/usr/bin/env python3
"""Promote an existing versionCode from one Play track to another."""
import argparse
import sys
import requests
from google.auth.transport.requests import Request as GAuthRequest
from google.oauth2 import service_account

SCOPES = ['https://www.googleapis.com/auth/androidpublisher']
API = 'https://androidpublisher.googleapis.com/androidpublisher/v3'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json-key', required=True)
    ap.add_argument('--package', required=True)
    ap.add_argument('--version-code', required=True, type=int)
    ap.add_argument('--from-track', default='internal')
    ap.add_argument('--to-track', required=True)
    ap.add_argument('--release-notes', default=None)
    ap.add_argument('--user-fraction', type=float, default=None,
                    help='If set, do a staged rollout at this fraction (0 < f < 1)')
    ap.add_argument('--draft', action='store_true',
                    help='Create the release with status=draft (required when the app itself is in draft state)')
    args = ap.parse_args()

    creds = service_account.Credentials.from_service_account_file(args.json_key, scopes=SCOPES)
    creds.refresh(GAuthRequest())
    s = requests.Session()
    s.headers.update({'Authorization': f'Bearer {creds.token}'})

    pkg = args.package
    print(f"Creating edit for {pkg}...", flush=True)
    r = s.post(f'{API}/applications/{pkg}/edits', json={}, timeout=60)
    r.raise_for_status()
    edit_id = r.json()['id']
    print(f"  editId={edit_id}", flush=True)

    try:
        # Verify the versionCode is currently on the source track.
        print(f"Reading '{args.from_track}' track...", flush=True)
        r = s.get(f'{API}/applications/{pkg}/edits/{edit_id}/tracks/{args.from_track}', timeout=30)
        r.raise_for_status()
        src = r.json()
        found = False
        for rel in src.get('releases', []):
            if str(args.version_code) in rel.get('versionCodes', []):
                found = True
                break
        if not found:
            print(f"  WARNING: versionCode {args.version_code} not found in '{args.from_track}'. Continuing anyway.", flush=True)
        else:
            print(f"  versionCode {args.version_code} confirmed on '{args.from_track}'.", flush=True)

        # Build the destination release
        if args.draft:
            release = {'name': str(args.version_code), 'status': 'draft',
                       'versionCodes': [str(args.version_code)]}
        elif args.user_fraction is not None:
            release = {'name': str(args.version_code), 'status': 'inProgress',
                       'userFraction': args.user_fraction,
                       'versionCodes': [str(args.version_code)]}
        else:
            release = {'name': str(args.version_code), 'status': 'completed',
                       'versionCodes': [str(args.version_code)]}
        if args.release_notes:
            release['releaseNotes'] = [{'language': 'en-US', 'text': args.release_notes}]

        print(f"Assigning versionCode {args.version_code} to '{args.to_track}'"
              + (f" (staged {int(args.user_fraction*100)}%)" if args.user_fraction is not None else " (100%)") + "...", flush=True)
        r = s.put(
            f'{API}/applications/{pkg}/edits/{edit_id}/tracks/{args.to_track}',
            json={'track': args.to_track, 'releases': [release]}, timeout=60)
        if not r.ok:
            print(f"HTTP {r.status_code}: {r.text[:2000]}", file=sys.stderr)
        r.raise_for_status()

        print("Committing edit...", flush=True)
        r = s.post(f'{API}/applications/{pkg}/edits/{edit_id}:commit', timeout=120)
        if not r.ok:
            print(f"HTTP {r.status_code}: {r.text[:2000]}", file=sys.stderr)
        r.raise_for_status()
        print(f"DONE — versionCode {args.version_code} promoted to '{args.to_track}'", flush=True)
    except Exception as e:
        print(f"Aborting edit due to error: {e}", file=sys.stderr)
        try:
            s.delete(f'{API}/applications/{pkg}/edits/{edit_id}', timeout=30)
        except Exception:
            pass
        raise


if __name__ == '__main__':
    main()
