import importlib.util
from pathlib import Path
import tempfile
import base64
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('create_appcast',root/'scripts/create_appcast.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as d:
    f=Path(d)/'FreeLingo-0.6.0-AppleSilicon.zip';f.write_bytes(b'hello')
    signature=base64.b64encode(b'Z'*64).decode()
    xml=module.render_appcast('0.6.0',10,f, f'sparkle:edSignature="{signature}" length="5"','igrizlikov','FreeLingo')
    e=ET.fromstring(xml)
    enc=e.find('channel/item/enclosure')
    assert enc.attrib['url'].endswith('/v0.6.0/'+f.name)
    assert enc.attrib['length']=='5'
    assert enc.attrib['{'+module.SPARKLE_NS+'}version']=='10'
    assert enc.attrib['{'+module.SPARKLE_NS+'}edSignature']==signature
    try:
        module.render_appcast('a.6.0',10,f, f'sparkle:edSignature="{signature}"','igrizlikov','FreeLingo')
    except ValueError: pass
    else: raise AssertionError('invalid version must be rejected')
    print('OK: appcast signature and release URL validated')
