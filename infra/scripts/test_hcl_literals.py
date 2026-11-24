"""Tests for hcl_literals (fake values only). Run: python3 -m unittest scripts/test_hcl_literals.py"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hcl_literals as h  # noqa: E402

FIXTURE = r'''
# comment
plain        = "fake-plain"   // trailing comment
escaped      = "a\"b\\c\ndé"
literal_dollar = "cost $${x} and %%{y}"
number       = 42
negative     = -3.5e2
yes          = true
nothing      = null
/* block
   comment */
strings      = ["fake-a", "fake-b",]
multi_list   = [
  "fake-c",   # comment inside
  "fake-d"
]
empty_list   = []
list_of_maps = [
  { name = "one", secret = "fake-1" },
  { name = "two", "quoted key" = "fake-2" },
]
map_of_lists = {
  coder   = ["x", "y"]
  forgejo : []
}
oidc = {
  actual  = "fake-oidc-1"
  forgejo = "fake-oidc-2",
}
doc = <<EOF
line one
  line two
EOF
indented = <<-EOT
    keep
      relative
    EOT
'''


class ParseTests(unittest.TestCase):
    def setUp(self):
        self.v = dict(h.parse(FIXTURE))

    def test_scalars(self):
        self.assertEqual(self.v["plain"], "fake-plain")
        self.assertEqual(self.v["escaped"], 'a"b\\c\ndé')
        self.assertEqual(self.v["literal_dollar"], "cost ${x} and %{y}")
        self.assertEqual(self.v["number"], 42)
        self.assertEqual(self.v["negative"], -350.0)
        self.assertIs(self.v["yes"], True)
        self.assertIsNone(self.v["nothing"])

    def test_lists(self):
        self.assertEqual(self.v["strings"], ["fake-a", "fake-b"])
        self.assertEqual(self.v["multi_list"], ["fake-c", "fake-d"])
        self.assertEqual(self.v["empty_list"], [])
        self.assertEqual(self.v["list_of_maps"], [
            {"name": "one", "secret": "fake-1"},
            {"name": "two", "quoted key": "fake-2"},
        ])

    def test_maps(self):
        self.assertEqual(self.v["map_of_lists"], {"coder": ["x", "y"], "forgejo": []})
        self.assertEqual(self.v["oidc"], {"actual": "fake-oidc-1", "forgejo": "fake-oidc-2"})

    def test_heredocs(self):
        self.assertEqual(self.v["doc"], "line one\n  line two\n")
        self.assertEqual(self.v["indented"], "keep\n  relative\n")

    def test_to_env(self):
        self.assertEqual(h.to_env("s"), "s")
        self.assertEqual(h.to_env(["a", "b"]), '["a", "b"]')
        self.assertEqual(h.to_env({"k": "v"}), '{"k": "v"}')

    def test_unsupported(self):
        for text in ('x = "${var.y}"', "x = var.y", 'x = file("p")', 'x = "a%{if 1}b"'):
            with self.assertRaises(h.Unsupported) as cm:
                list(h.parse(text))
            self.assertEqual(cm.exception.var, "x")

    def test_errors_hide_content(self):
        with self.assertRaises(h.HclError) as cm:
            list(h.parse('ok = "fine"\nbad = "fake-secret-value'))
        msg = str(cm.exception)
        self.assertNotIn("fake-secret-value", msg)
        self.assertEqual(cm.exception.var, "bad")


class SensitiveTests(unittest.TestCase):
    def test_sensitive_blocks(self):
        tf = '''
variable "a" {
  type      = string
  sensitive = true
}
variable "b" {
  type = map(object({ x = string }))
  default = {}
}
variable "c" {
  validation {
    condition = true
  }
  sensitive = true
}
'''
        self.assertEqual(h.sensitive_variables(tf), {"a", "c"})


if __name__ == "__main__":
    unittest.main()
