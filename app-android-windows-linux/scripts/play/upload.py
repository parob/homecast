#!/usr/bin/env python3
"""Create the edit + resumable session in Python, then PUT the AAB via curl."""
import argparse
import os
import tempfile
import subprocess
import sys
import requests
from google.auth.transport.requests import Request as GAuthRequest
from google.oauth2 import service_account

SCOPES = ['https://www.googleapis.com/auth/androidpublisher']
API = 'https://androidpublisher.googleapis.com/androidpublisher/v3'
UPLOAD = 'https://androidpublisher.googleapis.com/upload/androidpublisher/v3'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json-key', required=True)
    ap.add_argument('--package', required=True)
    ap.add_argument('--aab', required=True)
    ap.add_argument('--track', default='internal')
    ap.add_argument('--release-notes', default=None)
    args = ap.parse_args()

    creds = service_account.Credentials.from_service_account_file(args.json_key, scopes=SCOPES)
    creds.refresh(GAuthRequest())
    token = creds.token
    s = requests.Session()
    s.headers.update({'Authorization': f'Bearer {token}'})

    print(f"Creating edit for {args.package}...", flush=True)
    r = s.post(f'{API}/applications/{args.package}/edits', json={}, timeout=60)
    r.raise_for_status()
    edit_id = r.json()['id']
    print(f"  editId={edit_id}", flush=True)

    try:
        size = os.path.getsize(args.aab)
        print(f"Initiating resumable upload ({size} bytes / {size/1024/1024:.1f} MB)...", flush=True)
        init_url = f'{UPLOAD}/applications/{args.package}/edits/{edit_id}/bundles?uploadType=resumable'
        r = s.post(init_url, headers={
            'X-Upload-Content-Type': 'application/octet-stream',
            'X-Upload-Content-Length': str(size),
            'Content-Length': '0',
        }, timeout=60)
        if not r.ok:
            print(f"HTTP {r.status_code} body: {r.text[:2000]}", file=sys.stderr)
        r.raise_for_status()
        upload_url = r.headers['Location']
        print(f"  upload session ready", flush=True)

        # Use curl --upload-file for the big PUT
        print("Uploading via curl...", flush=True)
        # `--retry` without `--retry-all-errors`: curl then retries only what is
        # actually transient (5xx, timeouts, connection failures). It used to
        # retry everything, which meant a 403 — a permission or validation
        # answer that will never change — re-uploaded the whole 16 MB bundle
        # four times before failing anyway.
        response_path = os.path.join(tempfile.gettempdir(), 'play_upload_response.json')
        cmd = [
            'curl', '--http1.1', '--fail-with-body', '--progress-bar',
            '--retry', '3', '--max-time', '1800',
            '-H', f'Authorization: Bearer {token}',
            '-H', 'Content-Type: application/octet-stream',
            '--upload-file', args.aab,
            upload_url, '-o', response_path,
        ]
        ret = subprocess.call(cmd)
        if ret != 0:
            # Say WHAT Play objected to. `--fail-with-body` wrote the error
            # document to the same file the success path reads; this used to
            # raise without ever opening it, so a rejection arrived as the bare
            # word "403" and every diagnosis after that was guesswork.
            try:
                with open(response_path) as f:
                    detail = f.read().strip()
            except OSError:
                detail = '(no response body captured)'
            raise RuntimeError(f"curl exited {ret}; Play said: {detail}")
        import json as _j
        with open(response_path) as f:
            bundle = _j.load(f)
        version_code = bundle['versionCode']
        print(f"  uploaded versionCode={version_code}", flush=True)

        print(f"Assigning to track '{args.track}'...", flush=True)
        release = {'name': str(version_code), 'status': 'completed',
                   'versionCodes': [str(version_code)]}
        if args.release_notes:
            release['releaseNotes'] = [{'language': 'en-US', 'text': args.release_notes}]
        r = s.put(
            f'{API}/applications/{args.package}/edits/{edit_id}/tracks/{args.track}',
            json={'track': args.track, 'releases': [release]}, timeout=60)
        if not r.ok:
            print(f"HTTP {r.status_code} body: {r.text[:2000]}", file=sys.stderr)
        r.raise_for_status()

        print("Committing edit...", flush=True)
        r = s.post(f'{API}/applications/{args.package}/edits/{edit_id}:commit', timeout=120)
        if not r.ok:
            print(f"HTTP {r.status_code} body: {r.text[:2000]}", file=sys.stderr)
        r.raise_for_status()
        print(f"DONE — versionCode {version_code} on track '{args.track}'", flush=True)
    except Exception as e:
        print(f"Aborting edit due to error: {e}", file=sys.stderr)
        try:
            s.delete(f'{API}/applications/{args.package}/edits/{edit_id}', timeout=30)
        except Exception:
            pass
        raise


if __name__ == '__main__':
    main()
