#!/usr/bin/env python3
"""Renders Antsurance document pages in the org to PDF, downloads them and converts each page to PNG.

Usage: render_docs.py <outdir> <label>|<page>|<soql returning one Id>[|key=value&key=value] ...
Records are looked up by SOQL each run, because demo data reloads change their Ids.

The PDF comes back through the debug log of an anonymous Apex run, as base64 in chunks, so nothing is
stored in the org (its data storage is small, and a temporary file there can fail on a full org).
"""
import base64, glob, json, os, re, subprocess, sys

ORG = os.environ.get('SF_TARGET_ORG')
if not ORG:
    sys.exit('Set SF_TARGET_ORG to the alias of the org to render from.')
ENV = dict(os.environ, SF_DISABLE_TELEMETRY='true')
CHUNK = 20000
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for f in glob.glob(out + '/*.pdf') + glob.glob(out + '/*.png'):
    os.remove(f)

for item in sys.argv[2:]:
    parts = item.split('|')
    label, page, soql = parts[0], parts[1], parts[2]
    extra = parts[3] if len(parts) > 3 else ''
    lines = [f"SObject record = Database.query('{soql.replace(chr(39), chr(92) + chr(39))}');",
             f"PageReference page = new PageReference('/apex/{page}');", "page.getParameters().put('id', record.Id);"]
    for pair in filter(None, extra.split('&')):
        key, value = pair.split('=', 1)
        lines.append(f"page.getParameters().put('{key}', '{value}');")
    lines += ['String encoded = EncodingUtil.base64Encode(page.getContentAsPDF());',
              f'for (Integer at = 0; at < encoded.length(); at += {CHUNK}) {{',
              f"    System.debug(LoggingLevel.ERROR, 'PDFCHUNK ' + encoded.substring(at, Math.min(at + {CHUNK}, encoded.length())) + ' PDFEND');",
              '}']
    apex = os.path.join(out, label + '.apex')
    open(apex, 'w').write('\n'.join(lines))
    run = subprocess.run(['sf', 'apex', 'run', '--file', apex, '--target-org', ORG, '--json'], capture_output=True, text=True, env=ENV)
    try:
        result = json.loads(run.stdout).get('result') or json.loads(run.stdout).get('data') or {}
    except ValueError:
        print(label, 'no JSON from sf:', run.stdout[:300], run.stderr[:300]); continue
    if not result.get('success'):
        print(label, 'FAILED', result.get('compileProblem') or '', result.get('exceptionMessage') or '', (result.get('exceptionStackTrace') or '')[:300]); continue
    chunks = re.findall(r'PDFCHUNK (\S+) PDFEND', result.get('logs', ''))
    pdf = os.path.join(out, label + '.pdf')
    open(pdf, 'wb').write(base64.b64decode(''.join(chunks)))
    subprocess.run(['pdfseparate', pdf, os.path.join(out, label + '-p%d.pdf')], capture_output=True)
    pages = sorted(glob.glob(os.path.join(out, label + '-p*.pdf')))
    for one in pages:
        # CoreGraphics (sips) draws the PDF's built-in Helvetica faithfully; poppler substitutes it badly.
        subprocess.run(['sips', '-s', 'format', 'png', '-Z', '1700', one, '--out', one[:-4] + '.png'], capture_output=True)
        os.remove(one)
    print(f'{label}: {len(pages)} page(s), {os.path.getsize(pdf)} bytes')
