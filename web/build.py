#!/usr/bin/env python3
"""Bundle the luahellper web obfuscator into web/index.html.
Run from the repo root:  python3 web/build.py
Inlines the pure-JS engine (web/obfuscator.js) into web/template.html — no Lua
VM, no eval, no CDN, so it runs inside sandboxed webviews (Claude Artifacts)."""
import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def build():
    tpl = open(os.path.join(ROOT, "web/template.html"), encoding="utf-8").read()
    engine = open(os.path.join(ROOT, "web/obfuscator.js"), encoding="utf-8").read()
    html = tpl.replace("/*__OBFJS__*/", engine)
    open(os.path.join(ROOT, "web/index.html"), "w", encoding="utf-8").write(html)
    print("wrote web/index.html (%d bytes)" % len(html))

if __name__ == "__main__":
    build()
