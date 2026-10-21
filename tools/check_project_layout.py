"""Read-only checks for the reorganized project, source provenance and paths."""
import ast
import hashlib
import json
import posixpath
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT/'tools/project_layout.json').read_text(encoding='utf-8'))
BOARD = ROOT/CONFIG['mainboard']
REPORT = BOARD/'reports/yolo_wbc_bccd15'
ERRORS = []
PUBLISHED = '--published' in sys.argv
PRIVATE_FROZEN_ASSETS = {'camera_val.npz', 'data_manifest.json', 'rtl_vectors.zip'}
OMITTED_PRIVATE_ASSETS = []


def check(condition, message):
    if not condition:
        ERRORS.append(message)


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def locate_source(name):
    name = name.replace('\\', '/')
    return ROOT/CONFIG['source_locations'][name] if name in CONFIG['source_locations'] else BOARD/name


def canonical_old_path(name):
    name = name.replace('\\', '/')
    prefix = '08_csi_dsi_cs500_7cun/'
    if name.startswith(prefix):
        tail = name[len(prefix):]
        return CONFIG['source_locations'].get(tail, CONFIG['mainboard']+'/'+tail)
    if name.startswith('HDMI_OUT/'):
        return CONFIG['hdmi']+'/'+name[len('HDMI_OUT/'):]
    return name


def parse_td(text):
    # TD uses XML-like syntax with literal P&R and :: tag names.
    # Normalize only this inspection copy, never the actual project file.
    text = re.sub(r'(</?)([A-Za-z_][\w:.-]*)', lambda m: m[1]+m[2].replace('::', '__'), text)
    return ET.fromstring(re.sub(r'&(?!#\d+;|#x[0-9A-Fa-f]+;|[A-Za-z]+;)', '&amp;', text))


def project_shape(node, project_dir, historical=False):
    attrs = dict(node.attrib)
    if node.tag == 'Project':
        attrs.pop('Path', None)
    elif node.tag == 'File' and 'Path' in attrs:
        rel = posixpath.normpath(posixpath.join(project_dir, attrs['Path'].replace('\\', '/')))
        attrs['Path'] = canonical_old_path(rel) if historical else rel
    return node.tag, sorted(attrs.items()), (node.text or '').strip(), [project_shape(c, project_dir, historical) for c in node]


def check_projects():
    count = 0
    for old, new in [('08_csi_dsi_cs500_7cun/td_project/camera_to_dsi_display.al', CONFIG['mainboard']+'/td_project/camera_to_dsi_display.al'),
                     ('HDMI_OUT/HDMI_OUT.al', CONFIG['hdmi']+'/HDMI_OUT.al')]:
        file = ROOT/new
        tree = parse_td(file.read_text(encoding='utf-8-sig'))
        check(Path(tree.attrib['Path']).resolve() == file.parent.resolve(), f'Wrong project root: {new}')
        for item in tree.iter('File'):
            path = item.get('Path')
            if path:
                count += 1
                check((file.parent/path).exists(), f'Missing TD reference: {new}: {path}')
        original = subprocess.check_output(['git', 'show', CONFIG['baseline_commit']+':'+old], cwd=ROOT)
        before = parse_td(original.decode('utf-8-sig'))
        check(project_shape(before, posixpath.dirname(old), True) == project_shape(tree, posixpath.dirname(new)),
              f'TD settings changed beyond file locations: {new}')
    return count


def check_sources():
    hashes = read(REPORT/'current/physical/source_hashes.json')
    for name, want in hashes.items():
        path = locate_source(name)
        check(path.is_file(), f'Missing released source: {name}')
        if path.is_file():
            if name.replace('\\', '/') == 'td_project/camera_to_dsi_display.al':
                original = subprocess.check_output(['git', 'show', CONFIG['baseline_commit']+':08_csi_dsi_cs500_7cun/td_project/camera_to_dsi_display.al'], cwd=ROOT)
                crlf = original.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
                check(want in {hashlib.sha256(original).hexdigest(), hashlib.sha256(crlf).hexdigest()}, 'Build-time project hash does not match the preserved baseline')
                # check_projects separately proves all non-path settings unchanged.
            else:
                check(sha(path) == want, f'Released source content changed: {name}')
    active = read(BOARD/'user_source/hdl_source/yolo/model/active_model.json')
    for name, want in active['assets'].items():
        path = BOARD/'user_source/hdl_source/yolo'/name
        check(path.is_file() and sha(path) == want, f'YOLO model asset mismatch: {name}')
    for name, want in read(REPORT/'current/summary.json')['frozen_assets'].items():
        path = ROOT/'yolo/wbc_bccd/frozen'/name
        if PUBLISHED and name in PRIVATE_FROZEN_ASSETS and not path.is_file():
            OMITTED_PRIVATE_ASSETS.append(name)
            continue
        check(path.is_file() and sha(path) == want, f'Frozen training asset mismatch: {name}')
    return len(hashes)


def check_documents_and_bit():
    doc = ROOT/CONFIG['official_report']
    manifest = read(doc/'release_manifest.json')
    summary = read(REPORT/'current/physical/build_result.json')
    state = read(BOARD/'deployment_state.json')
    bit = REPORT/'current/physical/camera_to_dsi_display.bit'
    check(sha(bit) == summary['bit_sha256'] == manifest['bit_sha256'] == state['bit_sha256'], 'Bit identity mismatch')
    check(sha(doc/'main.pdf') == sha(doc.parent/'作品报告.pdf') == manifest['pdf_sha256'], 'Official PDF identity mismatch')
    for name, want in manifest['files'].items():
        path = doc/name
        check(path.is_file() and sha(path) == want, f'Official document content changed: {name}')
    for name, want in manifest['original_template_hashes'].items():
        path = doc.parent/name
        check(path.is_file() and sha(path) == want, f'Template content changed: {name}')
    return manifest['pdf_sha256'], summary['bit_sha256']


def check_links():
    files = [ROOT/'README.md', ROOT/'docs/README.md', ROOT/'docs/competition/README.md', BOARD/'README.md',
             ROOT/'yolo/README.md', ROOT/'old/README.md', REPORT/'README.md', *list((ROOT/'docs/reports').glob('*.md'))]
    count = 0
    pattern = re.compile(r'\]\((<[^>\n]+>|[^()\n]*(?:\([^()\n]*\)[^()\n]*)*)\)')
    for file in files:
        for match in pattern.finditer(file.read_text(encoding='utf-8-sig')):
            target = match[1].strip().removeprefix('<').removesuffix('>')
            if not target or target.startswith(('#','https:','http:','mailto:','codex:','app:')):
                continue
            target = unquote(target.partition('#')[0])
            count += 1
            check((file.parent/target).exists(), f'Missing current documentation link: {file.relative_to(ROOT)} -> {target}')
    return count


def main():
    projects = check_projects()
    sources = check_sources()
    pdf_hash, bit_hash = check_documents_and_bit()
    python_files = list(ROOT.rglob('*.py'))
    for file in python_files:
        try:
            ast.parse(file.read_text(encoding='utf-8-sig'), filename=str(file))
        except SyntaxError as exc:
            ERRORS.append(f'Python syntax: {file.relative_to(ROOT)}: {exc}')
    links = check_links()
    logo = ROOT/CONFIG['hdmi']/'uisrc/01_rtl/osd_anlogic_logo.v'
    rom = re.search(r'\$readmemh\("([^"]+)"', logo.read_text(encoding='utf-8'))
    check(rom is not None and Path(rom[1]).is_file(), 'HDMI logo ROM path is missing')
    # A release check covers files Git will publish, without disturbing local TD runs.
    if PUBLISHED:
        names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
        inspected = [ROOT/name for name in names.decode('utf-8').split('\0') if name]
    else:
        inspected = ROOT.rglob('*')
    for file in inspected:
        if file.is_file() and (file.suffix.lower() in {'.log','.logw','.pyc','.aux','.toc','.wlf','.vcd','.vvp'} or file.name == 'transcript'):
            ERRORS.append(f'Transient file remains: {file.relative_to(ROOT)}')
        if file.is_dir() and (file.name in {'__pycache__','.pytest_cache','.mypy_cache'} or file.name.endswith('_Runs')):
            ERRORS.append(f'Cache directory remains: {file.relative_to(ROOT)}')
    result = {'status': 'FAIL' if ERRORS else 'PASS', 'TD_file_references': projects, 'released_source_manifest_entries': sources,
              'unchanged_source_byte_hashes': sources-1, 'TD_project_changes_only_paths': True,
              'Python_files_parsed': len(python_files), 'current_document_links': links,
              'scope': 'published_files' if PUBLISHED else 'local_full_tree',
              'omitted_private_frozen_assets': sorted(OMITTED_PRIVATE_ASSETS),
              'bit_sha256': bit_hash, 'official_pdf_sha256': pdf_hash, 'errors': ERRORS}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return bool(ERRORS)


if __name__ == '__main__':
    sys.exit(main())
