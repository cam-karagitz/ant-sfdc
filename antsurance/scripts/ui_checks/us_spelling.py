#!/usr/bin/env python3
"""Find British spellings in what a person can read, and say the American one.

The demo is for US insurers, so the app, what Claude is told to write, and the documents a
customer gets are in American English. This scans only text a person sees:

  component templates   text between tags, and attributes such as label, title, placeholder
  component scripts     string literals (not comments, not identifiers)
  Apex                  string literals, which is where prompts and messages live
  metadata XML          labels, descriptions, help text, error messages, screen text
  generators            string literals in scripts/*.py, since they write the metadata
  customer documents    everything under kit/ (Markdown outside code, script strings)

Left alone on purpose: identifiers, CSS, picklist API values, and every form of "cancel"
("cancelled" and "cancellation" are standard in US insurance, and Cancelled is a stored status).

Usage:
  scripts/ui_checks/us_spelling.py                 scan the project, exit 1 if anything is found
  scripts/ui_checks/us_spelling.py PATH [PATH...]  scan only these files or folders
  scripts/ui_checks/us_spelling.py --fix PATH...   rewrite the words in place, then report what is left
  scripts/ui_checks/us_spelling.py --by-folder     also print a count for each component or folder
"""
import io
import os
import re
import sys
import tokenize

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
DEFAULT_PATHS = ['force-app/main/default', 'scripts', 'kit']
SKIP_DIRS = {'node_modules', '__pycache__', '.git', 'staticresources', '__tests__', 'eval', 'dist'}

# stem -> American stem, for words that take the usual endings.
ISE_STEMS = (
    'organ recogn summar priorit author categor final custom optim minim maxim standard normal special '
    'real apolog item util capital initial visual memor digit penal subsid sympath critic legal modern '
    'personal central general harmon formal emphas character familiar stabil neutral immun hospital '
    'jeopard monet local global mobil social commercial computer synchron serial material minimal '
    'rational revolution scrutin symbol system theor vandal victim equal external internal national '
    'natural patron polar popular public random regular simil steril tranquil'
).split()
OUR_STEMS = 'col behavi fav hon lab neighb harb rum hum vap od arm endeav flav sav splend rig vig'.split()

# (pattern, replacement) pairs; patterns are matched case-insensitively on whole words.
RULES = [
    (r'analys(e|ed|es|ing|er|ers)', r'analyz\1'),
    (r'paralys(e|ed|es|ing)', r'paralyz\1'),
    (r'catalys(e|ed|es|ing)', r'catalyz\1'),
    (r'(%s)is(e|ed|es|ing|er|ers|ation|ations|able)' % '|'.join(ISE_STEMS), r'\1iz\2'),
    (r'(%s)our(s|ed|ing|ful|fully|less|able|ably|ite|ites|hood|hoods|ly|al|ally|ist)?' % '|'.join(OUR_STEMS), r'\1or\2'),
    (r'(label|model|total|travel|signal|fuel|channel|level|tunnel|counsel|marvel|quarrel|dial|equal|initial|panel)l(ed|ing|er|ers)', r'\1\2'),
    (r'jewellery', 'jewelry'),
    (r'counsellor(s?)', r'counselor\1'),
    (r'licenc(e|es|ed|ing)', r'licens\1'),
    (r'cent(re|res)', lambda m: 'center' + ('s' if m.group(1) == 'res' else '')),
    (r'centred', 'centered'),
    (r'(met|lit|kilomet|centimet|millimet|theat|fib|calib|lust|somb|spect)(re|res)', lambda m: m.group(1) + 'er' + ('s' if m.group(2) == 'res' else '')),
    (r'grey(s|ed|ing|ish)?', r'gray\1'),
    (r'enquir(y|ies|e|ed|es|ing)', r'inquir\1'),
    (r'catalogu(e|es|ed|ing)', lambda m: 'catalog' + {'e': '', 'es': 's', 'ed': 'ed', 'ing': 'ing'}[m.group(1).lower()]),
    (r'programme(s?)', r'program\1'),
    (r'judgement(s?)', r'judgment\1'),
    (r'(def|off|pret)ence(s?)', r'\1ense\2'),
    (r'whilst', 'while'),
    (r'amongst', 'among'),
    (r'learnt', 'learned'),
    (r'cheque(s?)', r'check\1'),
    (r'tyre(s?)', r'tire\1'),
    (r'kerb(s|side)?', r'curb\1'),
    (r'storey(s?)', lambda m: 'stories' if m.group(1) else 'story'),
    (r'aluminium', 'aluminum'),
    (r'plough(s|ed|ing)?', r'plow\1'),
    (r'draught(s|y)?', r'draft\1'),
    (r'artefact(s?)', r'artifact\1'),
    (r'practis(e|ed|es|ing)', r'practic\1'),
    (r'fulfil(s|ment)?', lambda m: 'fulfill' + (m.group(1) or '')),
    (r'enrol(s|ment|ments)?', lambda m: 'enroll' + (m.group(1) or '')),
    (r'instalment(s?)', r'installment\1'),
    (r'(skil|wil)ful(ly)?', r'\1lful\2'),
    (r'ageing', 'aging'),
    (r'mould(s|y|ed|ing)?', r'mold\1'),
    (r'sceptic(s|al|ism)?', r'skeptic\1'),
    (r'maths', 'math'),
    (r'per cent', 'percent'),
    (r'towards', 'toward'),
]
COMPILED = [(re.compile(r'(?<![\w$#@/\\.-])(?:%s)(?![\w(])' % pattern, re.IGNORECASE), fix) for pattern, fix in RULES]

# XML elements whose text a person reads. API names (fullName, name, field, value of a picklist) are not here.
XML_TEXT = re.compile(
    r'<(label|masterLabel|pluralLabel|description|inlineHelpText|helpText|errorMessage|title|subtitle|'
    r'text|fieldText|stringValue|pausedText|interviewLabel|relatedListLabel|startsWith|message|body|'
    r'header|footer|placeholder|tooltip|caption|summary|subject|content)>([^<]+)</\1>'
)
# Template attributes that hold code or names, not words.
HTML_SKIP_ATTRS = re.compile(r'^(class|id|key|for|href|src|style|slot|type|name|variant|size|role|autocomplete|rel|target|tabindex|'
                             r'icon-name|icon-position|field-name|object-api-name|record-id|lwc:.*|data-.*|on[a-z]+|for:.*|iterator:.*)$')


def american(match_text, replacement):
    """The replacement in the same capitals as the word it replaces."""
    if match_text.isupper():
        return replacement.upper()
    if match_text[:1].isupper():
        return replacement[:1].upper() + replacement[1:]
    return replacement


def findings_in(text):
    """Each British word in a piece of readable text, as (start, end, word, fix)."""
    found = []
    for pattern, fix in COMPILED:
        for match in pattern.finditer(text):
            word = match.group(0)
            if re.fullmatch(r'cancel\w*', word, re.IGNORECASE):
                continue
            replacement = match.expand(fix) if isinstance(fix, str) else fix(match)
            # The replacement is built from the lower-case rule, so put the capitals back.
            replacement = american(word, replacement.lower() if word.isupper() or word[:1].isupper() else replacement)
            if replacement.lower() != word.lower():
                found.append((match.start(), match.end(), word, replacement))
    return found


def looks_like_code(literal):
    """A string that is a name, a path or a selector, not words for a person."""
    text = literal.strip()
    if not text or ' ' in text:
        return False
    # One capitalised word ("Analyse") is a label; anything with code punctuation or inner capitals is a name.
    return (bool(re.search(r'[_./:#$\\={}<>\[\]]', text)) or bool(re.search(r'[a-z][A-Z]', text))
            or text.islower() or text.isupper() or '-' in text)


def spans_html(source):
    without_comments = re.sub(r'<!--.*?-->', lambda m: ' ' * len(m.group(0)) if '\n' not in m.group(0) else re.sub(r'[^\n]', ' ', m.group(0)), source, flags=re.S)
    for match in re.finditer(r'>([^<>]+)<', without_comments):
        yield match.start(1), match.group(1)
    for match in re.finditer(r'([\w:.-]+)\s*=\s*"([^"{}]*)"', without_comments):
        if not HTML_SKIP_ATTRS.match(match.group(1)):
            yield match.start(2), match.group(2)


def spans_code(source, quotes):
    """String literals in JavaScript or Apex, skipping comments."""
    i, n = 0, len(source)
    while i < n:
        two = source[i:i + 2]
        if two == '//':
            i = source.find('\n', i)
            i = n if i < 0 else i
        elif two == '/*':
            end = source.find('*/', i + 2)
            i = n if end < 0 else end + 2
        elif source[i] in quotes:
            quote, start = source[i], i + 1
            i += 1
            while i < n and source[i] != quote:
                i += 2 if source[i] == '\\' else 1
                if quote != '`' and i < n and source[i - 1] == '\n':
                    break
            literal = source[start:i]
            if not looks_like_code(literal):
                yield start, literal
            i += 1
        else:
            i += 1


def spans_python(source):
    lines = source.split('\n')
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    try:
        for token in tokenize.generate_tokens(io.StringIO(source).readline):
            if token.type == tokenize.STRING and not looks_like_code(token.string.strip('rbfuRBFU\'"')):
                yield starts[token.start[0] - 1] + token.start[1], token.string
    except (tokenize.TokenError, IndentationError, SyntaxError):
        yield 0, source


def spans_xml(source):
    for match in XML_TEXT.finditer(source):
        yield match.start(2), match.group(2)


def spans_markdown(source):
    blanked = re.sub(r'```.*?```', lambda m: re.sub(r'[^\n]', ' ', m.group(0)), source, flags=re.S)
    blanked = re.sub(r'`[^`\n]*`', lambda m: ' ' * len(m.group(0)), blanked)
    yield 0, blanked


def spans_for(path, source):
    name = path.lower()
    if name.endswith('.html'):
        return spans_html(source)
    if name.endswith(('.js', '.ts')):
        return spans_code(source, '\'"`')
    if name.endswith(('.cls', '.trigger', '.apex')):
        return spans_code(source, "'")
    if name.endswith('.py'):
        return spans_python(source)
    if name.endswith('.xml') or name.endswith('.page') or name.endswith('.component'):
        return spans_xml(source)
    if name.endswith(('.md', '.txt')):
        return spans_markdown(source)
    if name.endswith('.sh'):
        return iter([(0, re.sub(r'(^|\s)#[^\n]*', lambda m: ' ' * len(m.group(0)), source))])
    return iter(())


def files_under(paths):
    for path in paths:
        full = path if os.path.isabs(path) else os.path.join(ROOT, path)
        if os.path.isfile(full):
            yield full
            continue
        for folder, dirs, names in os.walk(full):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for name in sorted(names):
                if name.endswith(('.html', '.js', '.cls', '.trigger', '.apex', '.py', '.xml', '.page', '.md', '.sh', '.txt')):
                    yield os.path.join(folder, name)


def scan(path, fix):
    try:
        source = open(path, encoding='utf-8').read()
    except (UnicodeDecodeError, OSError):
        return []
    hits = []
    for offset, text in spans_for(path, source):
        for start, end, word, replacement in findings_in(text):
            hits.append((offset + start, offset + end, word, replacement))
    hits = sorted(set(hits))
    if fix and hits:
        for start, end, _, replacement in reversed(hits):
            source = source[:start] + replacement + source[end:]
        open(path, 'w', encoding='utf-8').write(source)
        return scan(path, False)
    lines = source.split('\n')
    out, position, line_no = [], 0, 0
    starts = []
    for line in lines:
        starts.append(position)
        position += len(line) + 1
    for start, _, word, replacement in hits:
        while line_no + 1 < len(starts) and starts[line_no + 1] <= start:
            line_no += 1
        out.append((line_no + 1, word, replacement, lines[line_no].strip()[:110]))
    return out


def folder_of(path):
    parts = os.path.relpath(path, ROOT).split(os.sep)
    if 'lwc' in parts:
        return 'lwc/' + parts[parts.index('lwc') + 1]
    if 'classes' in parts:
        return 'classes/' + os.path.splitext(parts[-1])[0]
    return os.sep.join(parts[:-1]) if len(parts) > 1 else parts[0]


def main(argv):
    fix = '--fix' in argv
    by_folder = '--by-folder' in argv
    paths = [a for a in argv if not a.startswith('--')] or DEFAULT_PATHS
    if fix and paths == DEFAULT_PATHS:
        print('--fix needs the files or folders to rewrite: name them.')
        return 2
    total, counts = 0, {}
    for path in files_under(paths):
        if os.path.abspath(path) == os.path.abspath(__file__):
            continue
        for line_no, word, replacement, context in scan(path, fix):
            total += 1
            counts[folder_of(path)] = counts.get(folder_of(path), 0) + 1
            print(f'{os.path.relpath(path, ROOT)}:{line_no}: "{word}" should be "{replacement}"   | {context}')
    if by_folder and counts:
        print()
        for folder, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
            print(f'{count:4}  {folder}')
    print(f'\n{total} British spelling{"" if total == 1 else "s"} found.' if total else 'American spelling throughout.')
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
