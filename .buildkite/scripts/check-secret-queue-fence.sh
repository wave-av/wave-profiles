#!/usr/bin/env bash
# Fail if a Buildkite step targets a secrets queue, or declares secrets:,
# without the schedule-or-default-branch fence.
#
# Scans .buildkite/*.yml (and *.yaml). Queue match is case-insensitive and
# includes agents.queue, an agents list, and the queue= string form. A group
# condition covers the steps inside it. The fence may be ANDed with an
# existing condition; an OR that can bypass it fails.
#
# If a pipeline generator is present, run it with a simulated pull request
# and again with a simulated tag. It must not emit a secrets-queue step or
# a step that declares secrets:. Static `pipeline upload` of a yaml file is
# not a generator.
#
# No secret values are read or printed. A parse we cannot prove is safe
# fails closed.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 - <<'PY'
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

# Routing keys for the queues this fence covers. The allow comment is for
# the private-repo rule on this source line.
SECRET_QUEUES = (
    'fpc-isolated-secrets',  # guard:allow Buildkite queue routing key, not a repo reference
    'master-pc-isolated',  # guard:allow Buildkite queue routing key, not a repo reference
)
SECRET_QUEUE_SET = {q.lower() for q in SECRET_QUEUES}
FENCE = (
    '(build.source == "schedule" || (build.branch == pipeline.default_branch '
    '&& build.source != "trigger_job")) && build.pull_request.id == null '
    '&& build.tag == null'
)
QUEUE_TOKEN = re.compile(
    r'(?i)(?<![A-Za-z0-9_-])(?:' + '|'.join(re.escape(q) for q in SECRET_QUEUES) + r')(?![A-Za-z0-9_-])'
)
KEY_RE = re.compile(r'^(<<|[A-Za-z0-9_][A-Za-z0-9_-]*)\s*:\s*(.*)$')
QUEUE_EQ_RE = re.compile(r'(?i)(?:^|[\s,])queue=([A-Za-z0-9_.-]+)')


class ParseError(Exception):
    pass


class Node(dict):
    def __init__(self, line):
        super().__init__()
        self.line = line


def normalize_ws(text):
    return re.sub(r'\s+', ' ', text).strip()


def strip_comment(line):
    in_s = False
    in_d = False
    i = 0
    while i < len(line):
        c = line[i]
        if in_s:
            if c == "'" and i + 1 < len(line) and line[i + 1] == "'":
                i += 2
                continue
            if c == "'":
                in_s = False
            i += 1
            continue
        if in_d:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_d = False
            i += 1
            continue
        if c == "'":
            in_s = True
        elif c == '"':
            in_d = True
        elif c == '#':
            return line[:i]
        i += 1
    return line


def scalar(text):
    text = text.strip()
    if text in ('', 'null', '~', 'Null', 'NULL'):
        return None
    if text == 'true':
        return True
    if text == 'false':
        return False
    if re.fullmatch(r'-?\d+', text):
        return int(text)
    if len(text) >= 2 and text[0] == "'" and text[-1] == "'":
        return text[1:-1].replace("''", "'")
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        body = text[1:-1]
        body = body.replace('\\"', '"').replace('\\\\', '\\')
        return body
    return text


def parse_flow(text):
    s = text.strip()
    i = 0

    def skip():
        nonlocal i
        while i < len(s) and s[i] in ' \t':
            i += 1

    def parse_quoted():
        nonlocal i
        q = s[i]
        i += 1
        buf = []
        while i < len(s):
            if q == "'" and s[i] == "'" and i + 1 < len(s) and s[i + 1] == "'":
                buf.append("'")
                i += 2
                continue
            if s[i] == '\\' and q == '"':
                if i + 1 >= len(s):
                    raise ParseError('bad flow escape')
                buf.append(s[i + 1])
                i += 2
                continue
            if s[i] == q:
                i += 1
                return ''.join(buf)
            buf.append(s[i])
            i += 1
        raise ParseError('unterminated flow string')

    def parse_value():
        nonlocal i
        skip()
        if i >= len(s):
            raise ParseError('flow ended early')
        if s[i] == '[':
            return parse_seq()
        if s[i] == '{':
            return parse_map()
        if s[i] in '"\'':
            return parse_quoted()
        j = i
        while j < len(s) and s[j] not in ',]}':
            j += 1
        raw = s[i:j].strip()
        i = j
        return scalar(raw)

    def parse_seq():
        nonlocal i
        i += 1
        items = []
        while True:
            skip()
            if i < len(s) and s[i] == ']':
                i += 1
                return items
            items.append(parse_value())
            skip()
            if i < len(s) and s[i] == ',':
                i += 1
                continue
            if i < len(s) and s[i] == ']':
                i += 1
                return items
            raise ParseError('bad flow sequence')

    def parse_map():
        nonlocal i
        i += 1
        node = {}
        while True:
            skip()
            if i < len(s) and s[i] == '}':
                i += 1
                return node
            if i < len(s) and s[i] in '"\'':
                key = parse_quoted()
            else:
                j = i
                while j < len(s) and s[j] != ':':
                    j += 1
                key = s[i:j].strip()
                i = j
            skip()
            if i >= len(s) or s[i] != ':':
                raise ParseError('bad flow map')
            i += 1
            node[key] = parse_value()
            skip()
            if i < len(s) and s[i] == ',':
                i += 1
                continue
            if i < len(s) and s[i] == '}':
                i += 1
                return node
            raise ParseError('bad flow map')

    value = parse_value()
    skip()
    if i != len(s):
        raise ParseError('trailing flow')
    return value


class Parser:
    def __init__(self, text):
        self.lines = [ln.rstrip('\r') for ln in text.splitlines()]
        self.n = len(self.lines)
        self.i = 0
        self.anchors = {}

    def parse_document(self):
        self._skip()
        if self._eof():
            return None
        node = self._parse_block(self._indent())
        self._skip()
        if not self._eof():
            raise ParseError('line %d: trailing content' % self._lineno())
        return node

    def _eof(self):
        return self.i >= self.n

    def _lineno(self, idx=None):
        return (self.i if idx is None else idx) + 1

    def _blank(self, idx):
        return strip_comment(self.lines[idx]).strip() == ''

    def _skip(self):
        while not self._eof() and self._blank(self.i):
            self.i += 1

    def _indent(self, idx=None):
        idx = self.i if idx is None else idx
        raw = self.lines[idx]
        body = strip_comment(raw)
        lead = body[:len(body) - len(body.lstrip(' '))]
        if '\t' in lead or (body.strip() and raw.startswith('\t')):
            raise ParseError('line %d: tab indent is not supported' % self._lineno(idx))
        return len(lead)

    def _content(self, idx=None):
        idx = self.i if idx is None else idx
        return strip_comment(self.lines[idx]).strip()

    def _parse_block(self, indent):
        self._skip()
        if self._eof():
            raise ParseError('expected a block')
        if self._content().startswith('-'):
            return self._parse_seq(self._indent())
        return self._parse_map(self._indent())

    def _parse_seq(self, indent):
        items = []
        start = self.i
        while not self._eof():
            self._skip()
            if self._eof() or self._indent() != indent:
                break
            content = self._content()
            if not content.startswith('-'):
                break
            line_no = self._lineno()
            rest = content[1:].strip()
            dash_indent = self._indent()
            self.i += 1
            items.append(self._parse_item(rest, dash_indent, line_no))
        if self.i == start:
            raise ParseError('line %d: expected a list' % self._lineno())
        return items

    def _parse_item(self, rest, dash_indent, line_no):
        if rest == '':
            self._skip()
            if self._eof() or self._indent() <= dash_indent:
                return None
            return self._parse_block(self._indent())
        return self._parse_item_body(rest, dash_indent, line_no)

    def _parse_item_body(self, rest, dash_indent, line_no):
        if KEY_RE.match(rest):
            node = Node(line_no)
            key, valrest = self._split(rest)
            node[key] = self._parse_value(valrest, dash_indent)
            self._continue_map(node, dash_indent)
            return node
        return self._inline(rest, dash_indent, line_no)

    def _parse_map(self, indent):
        node = Node(self._lineno())
        start = self.i
        while not self._eof():
            self._skip()
            if self._eof() or self._indent() != indent:
                break
            content = self._content()
            if content.startswith('-') or not KEY_RE.match(content):
                break
            key, valrest = self._split(content)
            self.i += 1
            self._assign(node, key, self._parse_value(valrest, indent))
        if self.i == start:
            raise ParseError('line %d: expected a mapping' % self._lineno())
        return node

    def _continue_map(self, node, dash_indent):
        self._skip()
        if self._eof() or self._indent() <= dash_indent:
            return
        key_indent = self._indent()
        while not self._eof():
            self._skip()
            if self._eof() or self._indent() != key_indent:
                break
            content = self._content()
            if not KEY_RE.match(content):
                break
            key, valrest = self._split(content)
            self.i += 1
            self._assign(node, key, self._parse_value(valrest, key_indent))

    def _assign(self, node, key, value):
        if key == '<<':
            maps = value if isinstance(value, list) else [value]
            for item in maps:
                if not isinstance(item, dict):
                    raise ParseError('merge source is not a mapping')
                for k, v in item.items():
                    if k not in node:
                        node[k] = v
            return
        node[key] = value

    def _split(self, text):
        m = KEY_RE.match(text)
        if not m:
            raise ParseError('expected a key')
        return m.group(1), m.group(2)

    def _parse_value(self, rest, parent_indent):
        rest = rest.strip()
        anchor = None
        if rest.startswith('&'):
            parts = rest.split(None, 1)
            anchor = parts[0][1:]
            if not anchor:
                raise ParseError('empty anchor')
            rest = parts[1] if len(parts) > 1 else ''
        if rest == '':
            self._skip()
            if self._eof() or self._indent() <= parent_indent:
                value = None
            else:
                value = self._parse_block(self._indent())
        elif rest.startswith('*') and re.fullmatch(r'\*[A-Za-z_][A-Za-z0-9_-]*', rest):
            name = rest[1:]
            if name not in self.anchors:
                raise ParseError('unknown anchor %s' % name)
            value = self.anchors[name]
        elif rest.startswith('|') or rest.startswith('>'):
            value = self._block_scalar(rest, parent_indent)
        elif rest.startswith('{') or rest.startswith('['):
            try:
                value = parse_flow(rest)
            except ParseError as exc:
                raise ParseError('line %d: %s' % (self._lineno(), exc))
        else:
            value = scalar(rest)
        if anchor is not None:
            self.anchors[anchor] = value
        return value

    def _inline(self, rest, parent_indent, line_no):
        if rest.startswith('{') or rest.startswith('['):
            try:
                value = parse_flow(rest)
            except ParseError as exc:
                raise ParseError('line %d: %s' % (line_no, exc))
            if isinstance(value, dict):
                node = Node(line_no)
                node.update(value)
                return node
            return value
        if rest.startswith('*') and re.fullmatch(r'\*[A-Za-z_][A-Za-z0-9_-]*', rest):
            name = rest[1:]
            if name not in self.anchors:
                raise ParseError('line %d: unknown anchor %s' % (line_no, name))
            return self.anchors[name]
        if rest.startswith('|') or rest.startswith('>'):
            return self._block_scalar(rest, parent_indent)
        return scalar(rest)

    def _block_scalar(self, header, parent_indent):
        fold = header.startswith('>')
        chomp = 'clip'
        if '-' in header:
            chomp = 'strip'
        elif '+' in header:
            chomp = 'keep'
        lines = []
        base = None
        while not self._eof():
            raw = self.lines[self.i]
            if raw.strip() == '':
                lines.append('')
                self.i += 1
                continue
            ind = self._indent()
            if ind <= parent_indent:
                break
            if base is None:
                base = ind
            if ind < base:
                break
            lines.append(raw[base:])
            self.i += 1
        if fold:
            text = fold_lines(lines)
        else:
            text = '\n'.join(lines)
        if chomp == 'strip':
            text = text.rstrip('\n')
        elif chomp == 'clip':
            text = text.rstrip('\n')
            if lines:
                text += '\n' if not fold else ''
            if fold:
                text = text.rstrip('\n')
        return text


def fold_lines(lines):
    out = []
    buf = []
    for line in lines:
        if line == '':
            if buf:
                out.append(' '.join(buf))
                buf = []
            out.append('')
        else:
            buf.append(line.strip())
    if buf:
        out.append(' '.join(buf))
    return '\n'.join(out).strip('\n')


def _scan_expr(expr):
    """Yield (index, kind) for structural characters outside quotes.

    kind is 'open', 'close', 'and', or 'or'. A quote error yields 'bad'.
    """
    i = 0
    in_s = False
    in_d = False
    while i < len(expr):
        c = expr[i]
        if in_s:
            if c == "'" and i + 1 < len(expr) and expr[i + 1] == "'":
                i += 2
                continue
            if c == "'":
                in_s = False
            i += 1
            continue
        if in_d:
            if c == '\\' and i + 1 < len(expr):
                i += 2
                continue
            if c == '"':
                in_d = False
            i += 1
            continue
        if c == "'":
            in_s = True
            i += 1
            continue
        if c == '"':
            in_d = True
            i += 1
            continue
        if c == '(':
            yield i, 'open'
        elif c == ')':
            yield i, 'close'
        elif expr.startswith('&&', i):
            yield i, 'and'
            i += 2
            continue
        elif expr.startswith('||', i):
            yield i, 'or'
            i += 2
            continue
        i += 1
    if in_s or in_d:
        yield i, 'bad'


def _balanced_wrap(expr):
    """True when the whole expression is one parenthesized group."""
    if not (expr.startswith('(') and expr.endswith(')')):
        return False
    depth = 0
    for idx, kind in _scan_expr(expr):
        if kind == 'bad':
            return False
        if kind == 'open':
            depth += 1
        elif kind == 'close':
            depth -= 1
            if depth < 0:
                return False
            if depth == 0 and idx != len(expr) - 1:
                return False
    return depth == 0


def _split_top(expr, op):
    """Split on a top-level && or ||. op is 'and' or 'or'."""
    parts = []
    start = 0
    depth = 0
    for idx, kind in _scan_expr(expr):
        if kind == 'bad':
            return None
        if kind == 'open':
            depth += 1
        elif kind == 'close':
            depth -= 1
            if depth < 0:
                return None
        elif depth == 0 and kind == op:
            parts.append(expr[start:idx])
            start = idx + 2
    if depth != 0:
        return None
    parts.append(expr[start:])
    return parts


def _requires_marked(expr):
    """True when every way to satisfy expr requires the atom F.

    && binds tighter than ||, matching Buildkite condition precedence.
    """
    expr = expr.strip()
    if expr == '':
        return False
    while _balanced_wrap(expr):
        expr = expr[1:-1].strip()
    ors = _split_top(expr, 'or')
    if ors is None:
        return False
    if len(ors) > 1:
        return all(_requires_marked(part) for part in ors)
    ands = _split_top(expr, 'and')
    if ands is None:
        return False
    if len(ands) > 1:
        return any(_requires_marked(part) for part in ands)
    return expr.strip() == 'F'


def expression_requires_fence(expr):
    marked = normalize_ws(expr).replace(FENCE, 'F')
    if 'F' not in marked:
        return False
    return _requires_marked(marked)


def covered_by(ifs):
    parts = []
    for expr in ifs:
        if not isinstance(expr, str) or not expr.strip():
            return False
        parts.append('(' + normalize_ws(expr) + ')')
    if not parts:
        return False
    try:
        return expression_requires_fence(' && '.join(parts))
    except ParseError:
        return False


def queue_names(agents):
    found = []

    def from_string(text):
        if not isinstance(text, str):
            return
        for match in QUEUE_EQ_RE.finditer(text):
            found.append(match.group(1))

    if isinstance(agents, dict):
        q = agents.get('queue')
        if isinstance(q, str):
            found.append(q)
        elif isinstance(q, list):
            for item in q:
                if isinstance(item, str):
                    from_string(item)
                    if re.fullmatch(r'[A-Za-z0-9_.-]+', item) and 'queue=' not in item.lower():
                        found.append(item)
                elif isinstance(item, dict):
                    inner = item.get('queue')
                    if isinstance(inner, str):
                        found.append(inner)
        from_string(' '.join(str(v) for v in agents.values() if isinstance(v, str) and v != q))
    elif isinstance(agents, list):
        for item in agents:
            if isinstance(item, str):
                from_string(item)
            elif isinstance(item, dict):
                found.extend(queue_names(item))
    elif isinstance(agents, str):
        from_string(agents)
    return found


def sensitive_queues(step):
    return [q for q in queue_names(step.get('agents')) if q.lower() in SECRET_QUEUE_SET]


def has_secrets_key(step):
    return isinstance(step, dict) and 'secrets' in step


def walk_steps(steps, ancestor_ifs, filename, failures, fenced):
    if not isinstance(steps, list):
        failures.append('%s: steps is not a list' % filename)
        return
    for step in steps:
        if not isinstance(step, dict):
            continue
        own = step.get('if') if 'if' in step else None
        inherited = list(ancestor_ifs)
        if isinstance(own, str) and own.strip():
            inherited.append(own)
        elif own not in (None, ''):
            inherited.append(own)
        nested = step.get('steps')
        if isinstance(nested, list):
            walk_steps(nested, inherited, filename, failures, fenced)
        queues = sensitive_queues(step)
        secrets = has_secrets_key(step)
        if not queues and not secrets:
            continue
        line = getattr(step, 'line', '?')
        label = step.get('label') or step.get('key') or step.get('name') or '(unlabeled)'
        where = '%s:%s' % (filename, line)
        detail = 'label=%s' % label
        if queues:
            detail += ' queue=%s' % ','.join(queues)
        if secrets:
            detail += ' secrets'
        if covered_by(inherited):
            fenced.append('%s %s' % (where, detail))
        else:
            failures.append('%s %s lacks the secret-queue fence' % (where, detail))


def comment_stripped(text):
    return '\n'.join(strip_comment(ln) for ln in text.splitlines())


def check_text(text, filename):
    failures = []
    fenced = []
    try:
        doc = Parser(text).parse_document()
    except ParseError as exc:
        return ['%s: cannot parse pipeline (%s); failing closed' % (filename, exc)], []
    if doc is None:
        return failures, fenced
    if not isinstance(doc, dict) or not isinstance(doc.get('steps'), list):
        # A generator may print an empty document. A file that names a
        # secrets queue and is not a pipeline fails closed below.
        if QUEUE_TOKEN.search(comment_stripped(text)):
            return ['%s: secrets queue named outside a steps list; failing closed' % filename], []
        return failures, fenced
    walk_steps(doc.get('steps'), [], filename, failures, fenced)
    mentions = QUEUE_TOKEN.findall(comment_stripped(text))
    queue_steps = 0
    # Recount sensitive queue steps (not secrets-key-only) from the walk
    # messages we just recorded, plus failures. Each such step is one
    # occurrence we expect the parser to have claimed. Extra mentions mean
    # the parser missed a queue string.
    claimed = 0
    for row in fenced + failures:
        if ' queue=' in row:
            claimed += row.split(' queue=', 1)[1].split(' ')[0].count(',') + 1
    queue_steps = claimed
    if len(mentions) != queue_steps:
        failures.append(
            '%s: %d secrets-queue mention(s) but %d parsed queue step(s); failing closed'
            % (filename, len(mentions), queue_steps)
        )
    return failures, fenced


def pipeline_files(root):
    files = []
    base = root / '.buildkite'
    if not base.is_dir():
        return files
    for name in sorted(os.listdir(base)):
        if name.endswith('.yml') or name.endswith('.yaml'):
            path = base / name
            if path.is_file():
                files.append(path)
    return files


def discover_generators(root):
    found = []
    upload = root / '.buildkite' / 'upload.sh'
    if upload.is_file():
        text = upload.read_text(encoding='utf-8', errors='replace')
        for match in re.finditer(r'pipeline upload\s+(\S+)', text):
            target = match.group(1)
            if target.startswith('-'):
                continue
            path = Path(target)
            if not path.is_absolute():
                path = root / path
            if path.suffix in ('.yml', '.yaml') and path.is_file():
                continue
            found.append(path)
    base = root / '.buildkite'
    if base.is_dir():
        for dirpath, _dirs, names in os.walk(base):
            for name in names:
                lower = name.lower()
                if 'generat' in lower and 'pipeline' in lower:
                    found.append(Path(dirpath) / name)
    uniq = []
    seen = set()
    for path in found:
        key = str(path)
        if key not in seen:
            seen.add(key)
            uniq.append(path)
    return uniq


def generator_command(path):
    if path.suffix == '.py':
        return ['python3', str(path)]
    if path.suffix == '.mjs':
        return ['node', str(path)]
    return ['bash', str(path)]


def clean_env(extra):
    env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'HOME': os.environ.get('HOME', '/tmp'),
        'LANG': 'C.UTF-8',
    }
    env.update(extra)
    return env


def check_generators(root):
    failures = []
    notes = []
    gens = discover_generators(root)
    if not gens:
        notes.append('no pipeline generator')
        return failures, notes
    scenarios = (
        ('pull request', {
            'BUILDKITE_PULL_REQUEST': '123',
            'BUILDKITE_TAG': '',
            'BUILDKITE_BRANCH': 'pr-head',
            'BUILDKITE_SOURCE': 'webhook',
            'BUILDKITE_PIPELINE_DEFAULT_BRANCH': 'main',
        }),
        ('tag', {
            'BUILDKITE_PULL_REQUEST': 'false',
            'BUILDKITE_TAG': 'v9.9.9-fence',
            'BUILDKITE_BRANCH': 'main',
            'BUILDKITE_SOURCE': 'webhook',
            'BUILDKITE_PIPELINE_DEFAULT_BRANCH': 'main',
        }),
    )
    for path in gens:
        rel = str(path)
        try:
            rel = str(path.relative_to(root))
        except ValueError:
            pass
        if not path.is_file():
            failures.append('%s: generator path is not a file' % rel)
            continue
        for label, extra in scenarios:
            try:
                proc = subprocess.run(
                    generator_command(path),
                    cwd=str(root),
                    env=clean_env(extra),
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                failures.append('%s: generator failed to run for %s (%s)' % (rel, label, type(exc).__name__))
                continue
            if proc.returncode != 0:
                failures.append('%s: generator exited %s for %s; failing closed' % (rel, proc.returncode, label))
                continue
            gen_failures, _fenced = check_text(proc.stdout, '%s (%s stdout)' % (rel, label))
            # A generator must not emit the step at all. check_text passes a
            # fenced step, so treat any fenced or unfenced sensitive step as
            # a hit by scanning the parsed output a second way: any failure
            # from a missing fence, plus fenced rows.
            if gen_failures or _fenced:
                failures.append('%s: generator emitted a secrets-queue or secrets: step for %s' % (rel, label))
        notes.append('generator %s' % rel)
    return failures, notes


def scan_root(root):
    failures = []
    fenced = []
    notes = []
    files = pipeline_files(root)
    if not files:
        failures.append('%s: no .buildkite/*.yml pipeline to scan; failing closed' % root)
    for path in files:
        rel = str(path.relative_to(root))
        text = path.read_text(encoding='utf-8', errors='replace')
        file_failures, file_fenced = check_text(text, rel)
        failures.extend(file_failures)
        fenced.extend(file_fenced)
    gen_failures, gen_notes = check_generators(root)
    failures.extend(gen_failures)
    notes.extend(gen_notes)
    return failures, fenced, notes


def selftest():
    problems = []
    q = SECRET_QUEUES[0]
    q2 = SECRET_QUEUES[1]

    def expect(name, text, ok):
        failures, _fenced = check_text(text, 'fixture')
        passed = not failures
        if passed != ok:
            problems.append('self-test %s: expected %s, failures=%s' % (name, 'pass' if ok else 'fail', failures))

    fenced_step = (
        'steps:\n'
        '  - label: secret job\n'
        '    key: secret-job\n'
        '    command: .buildkite/scripts/job.sh\n'
        "    if: '%s'\n"
        '    agents:\n'
        '      queue: %s\n'
    ) % (FENCE, q)
    expect('exact fence', fenced_step, True)
    expect('missing fence', fenced_step.replace("    if: '%s'\n" % FENCE, ''), False)
    expect('or bypass', fenced_step.replace(
        "if: '%s'" % FENCE,
        'if: \'build.branch == "main" || %s\'' % FENCE,
    ), False)
    expect('anded with existing', fenced_step.replace(
        "if: '%s'" % FENCE,
        'if: \'build.env("ONLY") == "1" && %s\'' % FENCE,
    ), True)
    expect('agents list', (
        'steps:\n'
        '  - label: listed\n'
        '    command: .buildkite/scripts/job.sh\n'
        '    agents:\n'
        '      - queue=%s\n'
    ) % q, False)
    expect('agents string fenced', (
        'steps:\n'
        '  - label: listed\n'
        '    command: .buildkite/scripts/job.sh\n'
        "    if: '%s'\n"
        '    agents: "queue=%s"\n'
    ) % (FENCE, q), True)
    expect('flow agents', (
        'steps:\n'
        '  - label: flow\n'
        '    command: .buildkite/scripts/job.sh\n'
        '    agents: {queue: %s}\n'
    ) % q, False)
    expect('secrets key', (
        'steps:\n'
        '  - label: with-secrets\n'
        '    command: .buildkite/scripts/job.sh\n'
        '    secrets:\n'
        '      - EXAMPLE_NAME\n'
    ), False)
    expect('group fence', (
        'steps:\n'
        '  - group: gated\n'
        "    if: '%s'\n"
        '    steps:\n'
        '      - label: inner\n'
        '        command: .buildkite/scripts/job.sh\n'
        '        agents:\n'
        '          queue: %s\n'
    ) % (FENCE, q2.upper()), True)
    expect('comment only', (
        '# queue: %s\n'
        'steps: []\n'
    ) % q, True)
    expect('plain queue', (
        'steps:\n'
        '  - label: plain\n'
        '    command: .buildkite/scripts/job.sh\n'
        '    agents:\n'
        '      queue: fpc-isolated\n'
    ), True)
    anchored = (
        'steps:\n'
        '  - key: first\n'
        '    command: .buildkite/scripts/job.sh\n'
        '    agents:\n'
        '      queue: fpc-isolated\n'
        '    retry: &retry_policy\n'
        '      automatic:\n'
        '        - exit_status: -1\n'
        '          limit: 1\n'
        '  - wait\n'
        '  - key: secret-job\n'
        '    label: secret job\n'
        '    command: .buildkite/scripts/job.sh\n'
        "    if: '%s'\n"
        '    agents:\n'
        '      queue: %s\n'
        '    retry: *retry_policy\n'
    ) % (FENCE, q)
    expect('anchors', anchored, True)

    root = Path(tempfile.mkdtemp(prefix='fence-gen-'))
    try:
        gen_dir = root / '.buildkite'
        gen_dir.mkdir()
        (gen_dir / 'pipeline.yml').write_text('steps: []\n')
        good = gen_dir / 'generate-pipeline.sh'
        good.write_text(
            '#!/bin/sh\n'
            'if [ "${BUILDKITE_PULL_REQUEST:-false}" != "false" ] || [ -n "${BUILDKITE_TAG:-}" ]; then\n'
            '  printf "steps: []\\n"\n'
            'else\n'
            '  printf "steps:\\n  - label: secret\\n    command: job\\n    agents:\\n      queue: %s\\n"\n'
            'fi\n' % q
        )
        good.chmod(good.stat().st_mode | stat.S_IEXEC)
        failures, _fenced, _notes = scan_root(root)
        if failures:
            problems.append('self-test generator skips: %s' % failures)
        bad = good
        bad.write_text(
            '#!/bin/sh\n'
            'printf "steps:\\n  - label: secret\\n    command: job\\n    agents:\\n      queue: %s\\n"\n' % q
        )
        failures, _fenced, _notes = scan_root(root)
        if not any('emitted' in item for item in failures):
            problems.append('self-test generator emit not caught: %s' % failures)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return problems


def main():
    problems = selftest()
    failures, fenced, notes = scan_root(Path('.').resolve())
    print('check-secret-queue-fence: self-test %s' % ('passed' if not problems else 'FAILED'))
    for item in problems:
        print(item)
    print('check-secret-queue-fence: fenced steps')
    if fenced:
        for item in fenced:
            print('  %s' % item)
    else:
        print('  (none)')
    for note in notes:
        print('check-secret-queue-fence: %s' % note)
    for item in failures:
        print('FAIL %s' % item)
    total = problems + failures
    print('check-secret-queue-fence: %s' % ('ok' if not total else '%d problem(s)' % len(total)))
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
PY
