#!/usr/bin/env python3
"""Build a Sparkle appcast from a versioned app zip and sign_update output.

Signatures come ONLY from Sparkle's sign_update. This script never handles keys.
"""
import argparse
import base64
from pathlib import Path
import re
import xml.etree.ElementTree as ET

SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE_NS)

def render_appcast(version: str, build: int, archive: Path, signature_line: str,
                   owner: str, repo: str) -> bytes:
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('version must be x.y.z')
    if build < 1 or not archive.is_file():
        raise ValueError('build number or archive invalid')
    signature_match = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', signature_line)
    if not signature_match or len(base64.b64decode(signature_match.group(1), validate=True)) != 64:
        raise ValueError('invalid EdDSA signature from sign_update')
    if re.search(r'^[a-zA-Z0-9_.-]+$', owner) is None or re.search(r'^[a-zA-Z0-9_.-]+$', repo) is None:
        raise ValueError('invalid repository path')
    channel = ET.Element('rss', {'version': '2.0'})
    feed = ET.SubElement(channel, 'channel')
    ET.SubElement(feed, 'title').text = 'FreeLingo Updates'
    ET.SubElement(feed, 'link').text = f'https://github.com/{owner}/{repo}/releases'
    ET.SubElement(feed, 'description').text = 'Signed FreeLingo updates for macOS'
    item = ET.SubElement(feed, 'item')
    ET.SubElement(item, 'title').text = f'FreeLingo {version}'
    ET.SubElement(item, 'pubDate').text = __import__('email.utils', fromlist=['formatdate']).formatdate(usegmt=True)
    ET.SubElement(item, f'{{{SPARKLE_NS}}}minimumSystemVersion').text = '15.0'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{owner}/{repo}/releases/download/v{version}/{archive.name}',
        'length': str(archive.stat().st_size),
        'type': 'application/octet-stream',
        f'{{{SPARKLE_NS}}}version': str(build),
        f'{{{SPARKLE_NS}}}shortVersionString': version,
        f'{{{SPARKLE_NS}}}edSignature': signature_match.group(1),
    })
    return ET.tostring(channel, encoding='utf-8', xml_declaration=True) + b'\n'

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--version', required=True)
    p.add_argument('--build', type=int, required=True)
    p.add_argument('--archive', type=Path, required=True)
    p.add_argument('--signature-file', type=Path, required=True)
    p.add_argument('--output', type=Path, default=Path('appcast.xml'))
    p.add_argument('--owner', default='igrizlikov')
    p.add_argument('--repo', default='FreeLingo')
    a = p.parse_args()
    a.output.write_bytes(render_appcast(a.version, a.build, a.archive,
                                         a.signature_file.read_text(), a.owner, a.repo))
    print(f'Wrote {a.output}')
