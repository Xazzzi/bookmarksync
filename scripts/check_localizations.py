#!/usr/bin/env python3
"""Check native localization resources without Xcode (Python 3 standard library)."""
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'BookmarkSync' / 'Localization'
ENTRY = re.compile(r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");\s*$')
FORMAT = re.compile(r'%(?:\d+\$)?(?:@|l?d)')


def load_table(language):
    table = {}
    path = RESOURCES / f'{language}.lproj' / 'Localizable.strings'
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('/*'):
            continue
        match = ENTRY.fullmatch(line)
        assert match, f'{path}: invalid entry: {line}'
        key, value = map(json.loads, match.groups())
        assert key not in table, f'{path}: duplicate key {key!r}'
        assert value, f'{path}: empty translation {key!r}'
        table[key] = value
    return table


def main():
    english = load_table('en')
    chinese = load_table('zh-Hans')
    assert english.keys() == chinese.keys(), 'Language keys differ'
    for key in english:
        assert FORMAT.findall(english[key]) == FORMAT.findall(chinese[key]), key

    # Catch new untranslated SwiftUI literals, including help text and metadata.
    literal = r'"((?:[^"\\]|\\.)*)"'
    calls = re.compile(r'(?:Text|Button|Picker|TextField|MenuBarExtra|WindowGroup|\.help)\(' + literal)
    metadata = re.compile(r'MetadataRow\(label: ' + literal)
    onboarding = re.compile(r'(?:title|description): ' + literal)
    used = set()
    for path in (ROOT / 'BookmarkSync').rglob('*.swift'):
        source = path.read_text().split('#Preview', 1)[0]
        matches = calls.findall(source) + metadata.findall(source)
        if path.name == 'OnboardingView.swift':
            matches += onboarding.findall(source)
        for raw in matches:
            # Purely numeric change badges and empty strings are not language.
            if not raw or raw.startswith(('\\(', '+\\(', '~\\(', '-\\(')):
                continue
            key = json.loads('"' + raw + '"')
            used.add(key)
    assert not (used - english.keys()), f'Untranslated UI literals: {used - english.keys()}'

    for language in ['en', 'zh-Hans']:
        data = plistlib.loads((RESOURCES / f'{language}.lproj' / 'Localizable.stringsdict').read_bytes())
        plural = data['bookmarks_found']
        assert plural['NSStringLocalizedFormatKey'] == '%#@count@'
        assert plural['count']['NSStringFormatValueTypeKey'] == 'ld'
        assert 'other' in plural['count']
    info = plistlib.loads((ROOT / 'BookmarkSync' / 'Info.plist').read_bytes())
    assert info['CFBundleDevelopmentRegion'] == 'en'
    assert set(info['CFBundleLocalizations']) == {'en', 'zh-Hans'}
    print(f'OK: {len(english)} bilingual strings, {len(used)} UI literals, matching format arguments and plural resources.')


if __name__ == '__main__':
    main()
