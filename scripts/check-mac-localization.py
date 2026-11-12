"""Check compiler extraction, Italian coverage, placeholders, and count plurals.

Run after a Debug build with build/DerivedData as the derived data path.
"""
import itertools
import json
import plistlib
import re
import sys
from pathlib import Path

TOKEN = re.compile(r'%(?:(\d+)\$)?(@|lld|llu|ld|lu|d|u|(?:\.\d+)?[fgs])')
COUNT = re.compile(r'%(?:\d+\$)?(?:lld|d)')


def placeholders(value):
    # Escaped percent signs are literals, not format arguments.
    return sorted((int(m[1]) if m[1] else index, m[2])
                  for index, m in enumerate(TOKEN.finditer(value.replace('%%', '')), 1))


def leaves(node):
    if 'stringUnit' in node:
        unit = node['stringUnit']
        assert unit['state'] == 'translated', 'Untranslated string unit'
        yield unit['value']
    for variations in node.get('variations', {}).values():
        for child in variations.values():
            yield from leaves(child)


def has_plurals(node):
    return set(node.get('variations', {}).get('plural', {})) >= {'one', 'other'}


def check(key, localization):
    substitutions = localization.get('substitutions', {})
    if COUNT.search(key):
        assert has_plurals(localization) or (substitutions and all(
            has_plurals(value) for value in substitutions.values())), f'Missing plurals: {key}'
    expanded = list(leaves(localization))
    assert expanded, f'Missing translation: {key}'
    for name, substitution in substitutions.items():
        assert has_plurals(substitution), f'Missing substitution plurals: {key}'
        specifier = substitution['formatSpecifier']
        arg = substitution['argNum']
        expanded = [base.replace(f'%#@{name}@', variant.replace('%arg', f'%{arg}${specifier}'))
                    for base, variant in itertools.product(expanded, leaves(substitution))]
    for value in expanded:
        assert key == '' or value.strip(), f'Empty translation: {key}'
        assert '%#@' not in value, f'Unresolved substitution: {key}'
        assert placeholders(key) == placeholders(value), f'Placeholder mismatch: {key}: {value}'


def load_extraction(path):
    data = path.read_bytes()
    try:
        return json.loads(data)
    except (ValueError, UnicodeError):
        return plistlib.loads(data)


def main():
    # The widget and File Provider extensions read only their own catalogs, so their strings must be there
    # (including the shared API files the File Provider compiles). Shared/ is compiled into the app too; the
    # app never shows those strings, so either catalog covers them.
    def load(folder):
        return {p.stem: json.loads(p.read_text())['strings'] for p in Path(folder).glob('*.xcstrings')}
    app, widget, provider = load('ImmichGallery'), load('ImmichGalleryWidget'), load('ImmichGalleryFileProvider')
    catalogs = {table: {**app.get(table, {}), **widget.get(table, {})} for table in {*app, *widget}}
    checked = set()
    derived = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('build/DerivedData')
    for path in derived.rglob('*.stringsdata'):
        own = (widget if 'ImmichGalleryWidget.build' in path.parts
               else provider if 'ImmichGalleryFileProvider.build' in path.parts else catalogs)
        for table, entries in load_extraction(path).get('tables', {}).items():
            for entry in entries:
                key = entry['key']
                assert key in own.get(table, {}), f'Missing catalog key: {table}: {key} ({path.name})'
                checked.add((table, key))
    assert checked, 'Build first to extract localizable strings'
    for table, catalog in [*app.items(), *widget.items(), *provider.items()]:
        for key, entry in catalog.items():
            localizations = entry.get('localizations', {})
            assert 'it' in localizations, f'Missing Italian translation: {table}: {key}'
            if COUNT.search(key):
                assert 'en' in localizations, f'Missing English count forms: {key}'
            for localization in localizations.values():
                check(key, localization)
    print(f'Checked {len(checked)} extracted keys and {sum(map(len, [*app.values(), *widget.values(), *provider.values()]))} catalog keys: '
          'Italian coverage, placeholders, and count plurals passed.')


def self_test():
    unit = lambda value: {'stringUnit': {'state': 'translated', 'value': value}}
    check('%@', unit('%@'))
    check('%@ %lld', {'variations': {'plural': {
        'one': unit('%2$lld %1$@'), 'other': unit('%2$lld %1$@')}}})
    for key, value in [('%@', unit('%lld')), ('%lld items', unit('%lld elementi')),
                       ('Hello', {'stringUnit': {'state': 'new', 'value': 'Ciao'}}),
                       ('Hello', {}), ('Hello', unit(''))]:
        try:
            check(key, value)
        except AssertionError:
            continue
        raise AssertionError(f'Invalid fixture passed: {key}')


if __name__ == '__main__':
    self_test()
    main()
