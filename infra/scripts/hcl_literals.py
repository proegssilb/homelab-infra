"""Parse the literal subset of HCL that terraform.tfvars files use.

Handles `name = value` assignments whose values are strings (quoted, with
escapes, or heredocs), numbers, bools, null, lists/tuples and maps/objects,
nested in any combination, plus `#`, `//` and `/* */` comments. Interpolation
(`${...}`, `%{...}`), function calls and references are not literals: the
assignment is reported as unsupported.

Errors carry a line number and a short reason only, never file content, so
they are safe to print even when the file holds secrets.
"""

import json
import re


class HclError(Exception):
    def __init__(self, reason: str, line: int):
        super().__init__(f"line {line}: {reason}")
        self.line = line


class Unsupported(HclError):
    pass


_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
_NUMBER = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
_HEREDOC = re.compile(r"<<(-?)([A-Za-z_][A-Za-z0-9_]*)[ \t]*\n")
_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}


class _Parser:
    def __init__(self, text: str):
        self.s = text
        self.i = 0

    @property
    def line(self) -> int:
        return self.s.count("\n", 0, self.i) + 1

    def _skip(self, newlines: bool = True) -> None:
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t\r" or (newlines and c == "\n"):
                self.i += 1
            elif c == "#" or self.s.startswith("//", self.i):
                nl = self.s.find("\n", self.i)
                self.i = len(self.s) if nl < 0 else nl
            elif self.s.startswith("/*", self.i):
                end = self.s.find("*/", self.i + 2)
                if end < 0:
                    raise HclError("unterminated /* comment", self.line)
                self.i = end + 2
            else:
                return

    def _peek(self) -> str:
        return self.s[self.i] if self.i < len(self.s) else ""

    def assignments(self):
        """Yield (name, value) pairs; raises Unsupported/HclError naming the line."""
        while True:
            self._skip()
            if self.i >= len(self.s):
                return
            m = _IDENT.match(self.s, self.i)
            if not m:
                raise HclError("expected a variable name", self.line)
            name = m.group()
            self.i = m.end()
            self._skip(newlines=False)
            if self._peek() != "=":
                raise HclError(f"expected '=' after {name}", self.line)
            self.i += 1
            self._skip(newlines=False)
            try:
                value = self.value()
            except HclError as e:
                e.var = name
                raise
            yield name, value

    def value(self):
        self._skip()
        c = self._peek()
        if c == '"':
            return self._string()
        if c == "[":
            return self._list()
        if c == "{":
            return self._map()
        if self.s.startswith("<<", self.i):
            return self._heredoc()
        m = _NUMBER.match(self.s, self.i)
        if m:
            self.i = m.end()
            text = m.group()
            return float(text) if any(ch in text for ch in ".eE") else int(text)
        m = _IDENT.match(self.s, self.i)
        if m:
            word = m.group()
            if word in ("true", "false", "null"):
                self.i = m.end()
                return {"true": True, "false": False, "null": None}[word]
            raise Unsupported("reference or function call, not a literal", self.line)
        raise HclError("unexpected character", self.line)

    def _string(self) -> str:
        start_line = self.line
        self.i += 1
        out = []
        while self.i < len(self.s):
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\n":
                break
            if c == "\\":
                nxt = self.s[self.i + 1: self.i + 2]
                if nxt in _ESCAPES:
                    out.append(_ESCAPES[nxt])
                    self.i += 2
                elif nxt == "u":
                    out.append(chr(int(self.s[self.i + 2: self.i + 6], 16)))
                    self.i += 6
                elif nxt == "U":
                    out.append(chr(int(self.s[self.i + 2: self.i + 10], 16)))
                    self.i += 10
                else:
                    raise HclError("unknown escape in string", self.line)
                continue
            if c in "$%" and self.s.startswith("{", self.i + 1):
                raise Unsupported("template interpolation in string", self.line)
            if c in "$%" and self.s[self.i + 1: self.i + 3] in ("${", "%{"):
                out.append(c + "{")  # $${ / %%{ is a literal ${ / %{
                self.i += 3
                continue
            out.append(c)
            self.i += 1
        raise HclError("unterminated string", start_line)

    def _heredoc(self) -> str:
        m = _HEREDOC.match(self.s, self.i)
        if not m:
            raise HclError("malformed heredoc opener", self.line)
        indent, tag = m.group(1) == "-", m.group(2)
        self.i = m.end()
        lines = []
        while self.i <= len(self.s):
            nl = self.s.find("\n", self.i)
            line = self.s[self.i:] if nl < 0 else self.s[self.i:nl]
            if line.strip() == tag:
                self.i = len(self.s) if nl < 0 else nl
                break
            if "${" in line.replace("$${", "") or "%{" in line.replace("%%{", ""):
                raise Unsupported("template interpolation in heredoc", self.line)
            lines.append(line)
            if nl < 0:
                raise HclError(f"heredoc not closed", self.line)
            self.i = nl + 1
        if indent:
            widths = [len(l) - len(l.lstrip(" \t")) for l in lines if l.strip()]
            cut = min(widths, default=0)
            lines = [l[cut:] for l in lines]
        return "".join(l + "\n" for l in lines)

    def _list(self) -> list:
        self.i += 1
        out = []
        while True:
            self._skip()
            if self._peek() == "]":
                self.i += 1
                return out
            out.append(self.value())
            self._skip()
            if self._peek() == ",":
                self.i += 1
            elif self._peek() != "]":
                raise HclError("expected ',' or ']' in list", self.line)

    def _map(self) -> dict:
        self.i += 1
        out = {}
        while True:
            self._skip()
            if self._peek() == "}":
                self.i += 1
                return out
            if self._peek() == '"':
                key = self._string()
            else:
                m = _IDENT.match(self.s, self.i)
                if not m:
                    raise HclError("expected a map key", self.line)
                key = m.group()
                self.i = m.end()
            self._skip(newlines=False)
            if self._peek() not in "=:" or not self._peek():
                raise HclError("expected '=' or ':' after map key", self.line)
            self.i += 1
            out[key] = self.value()
            self._skip(newlines=False)
            if self._peek() == ",":
                self.i += 1


def parse(text: str):
    """Yield (name, value) per assignment. Stops at the first error."""
    yield from _Parser(text).assignments()


def to_env(value) -> str:
    """How a value travels in TF_VAR_<name>: strings raw, everything else JSON."""
    return value if isinstance(value, str) else json.dumps(value)


_VAR_BLOCK = re.compile(r'variable\s+"([^"]+)"\s*\{')


def sensitive_variables(variables_tf: str) -> set[str]:
    """Names of variables declared with `sensitive = true` (brace-matched blocks)."""
    names = set()
    for m in _VAR_BLOCK.finditer(variables_tf):
        depth, j = 1, m.end()
        while j < len(variables_tf) and depth:
            depth += {"{": 1, "}": -1}.get(variables_tf[j], 0)
            j += 1
        if re.search(r"^\s*sensitive\s*=\s*true\b", variables_tf[m.end():j], re.M):
            names.add(m.group(1))
    return names
