#!/usr/bin/env python3
"""Push Play Store listing metadata + images for an app via the Publisher API."""
import argparse
import os
import sys
import requests
from google.auth.transport.requests import Request as GAuthRequest
from google.oauth2 import service_account

SCOPES = ['https://www.googleapis.com/auth/androidpublisher']
API = 'https://androidpublisher.googleapis.com/androidpublisher/v3'
UPLOAD = 'https://androidpublisher.googleapis.com/upload/androidpublisher/v3'


def upload_image(s, pkg, edit_id, lang, image_type, path):
    """Upload one image via simple multipart=media."""
    url = (f'{UPLOAD}/applications/{pkg}/edits/{edit_id}/listings/{lang}/'
           f'{image_type}?uploadType=media')
    with open(path, 'rb') as f:
        r = s.post(url, data=f.read(),
                   headers={'Content-Type': 'image/png'}, timeout=120)
    if not r.ok:
        print(f"  upload {image_type} {os.path.basename(path)} failed: HTTP {r.status_code}: {r.text[:500]}",
              file=sys.stderr)
        r.raise_for_status()
    print(f"  uploaded {image_type}: {os.path.basename(path)}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json-key', required=True)
    ap.add_argument('--package', required=True)
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
        lang = 'en-US'

        # 1. Listing text
        listing = {
            'language': lang,
            'title': 'Homecast',
            'shortDescription': 'Apple Home, everywhere. Control HomeKit from Android.',
            'fullDescription': (
                "Homecast extends your Apple HomeKit smart home to Android — and to APIs, "
                "webhooks, and AI assistants.\n\n"
                "WHAT HOMECAST ADDS\n"
                " - Control HomeKit devices from Android (lights, thermostats, locks, "
                "scenes, automations)\n"
                " - REST and GraphQL APIs for your HomeKit devices\n"
                " - Webhooks — get notified when device states change\n"
                " - API tokens scoped to specific homes\n"
                " - Share access via link (with optional passcode) — no Apple ID required\n"
                " - Invite people with role-based permissions (admin, control, view-only)\n"
                " - Connect AI assistants like Claude or ChatGPT via MCP and OAuth\n\n"
                "The dashboard works similarly to the Home app — view and control devices "
                "organised by home and room. Supports custom collections, compact mode, and "
                "background customisation.\n\n"
                "REQUIRES HOMECAST FOR MAC\n"
                "This app requires the Homecast Mac app running on your home network. "
                "Download it separately from the Mac App Store to get started.\n\n"
                "Free tier includes up to 10 accessories. Subscribe for unlimited."
            ),
            'video': '',
        }
        print(f"Updating listing for {lang}...", flush=True)
        r = s.put(f'{API}/applications/{pkg}/edits/{edit_id}/listings/{lang}',
                  json=listing, timeout=60)
        if not r.ok:
            print(f"  listing PUT failed: HTTP {r.status_code}: {r.text[:500]}", file=sys.stderr)
        r.raise_for_status()
        print("  listing text updated", flush=True)

        # 2. App details (default language, contact)
        print("Updating app details (default language + contact)...", flush=True)
        r = s.put(f'{API}/applications/{pkg}/edits/{edit_id}/details',
                  json={
                      'defaultLanguage': lang,
                      'contactEmail': 'rob@parob.com',
                      'contactWebsite': 'https://homecast.cloud',
                  }, timeout=60)
        if not r.ok:
            print(f"  details PUT failed: HTTP {r.status_code}: {r.text[:500]}", file=sys.stderr)
        r.raise_for_status()
        print("  details updated", flush=True)

        # 3. Images
        assets = '/tmp/play-assets'
        screenshots_dir = '/Users/r.parker/Documents/GitHub/homecast/app-ios-macos/screenshots'

        if os.path.exists(f'{assets}/icon-512.png'):
            # Delete existing icons first to overwrite cleanly
            s.delete(f'{API}/applications/{pkg}/edits/{edit_id}/listings/{lang}/icon', timeout=30)
            upload_image(s, pkg, edit_id, lang, 'icon', f'{assets}/icon-512.png')

        if os.path.exists(f'{assets}/feature-1024x500.png'):
            s.delete(f'{API}/applications/{pkg}/edits/{edit_id}/listings/{lang}/featureGraphic',
                     timeout=30)
            upload_image(s, pkg, edit_id, lang, 'featureGraphic',
                         f'{assets}/feature-1024x500.png')

        # Phone screenshots — up to 8
        s.delete(f'{API}/applications/{pkg}/edits/{edit_id}/listings/{lang}/phoneScreenshots',
                 timeout=30)
        phone_shots = sorted(f for f in os.listdir(screenshots_dir)
                              if f.endswith('.png') and not f.startswith('.'))[:8]
        for shot in phone_shots:
            upload_image(s, pkg, edit_id, lang, 'phoneScreenshots',
                         os.path.join(screenshots_dir, shot))

        # 4. Commit
        print("Committing edit...", flush=True)
        r = s.post(f'{API}/applications/{pkg}/edits/{edit_id}:commit', timeout=120)
        if not r.ok:
            print(f"HTTP {r.status_code}: {r.text[:2000]}", file=sys.stderr)
        r.raise_for_status()
        print("DONE — listing pushed.", flush=True)
    except Exception as e:
        print(f"Aborting edit due to error: {e}", file=sys.stderr)
        try:
            s.delete(f'{API}/applications/{pkg}/edits/{edit_id}', timeout=30)
        except Exception:
            pass
        raise


if __name__ == '__main__':
    main()
