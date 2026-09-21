#!/usr/bin/env python3
"""Rebuild dist/index.html's app template from the .dc.html design source.

The bundler that produced dist/index.html is not available here, but the only
thing that needs to change on an edit is the app template it carries. This
reproduces exactly what that bundler does to the source:

  onClick=/onChange=   ->  sc-camel-on-click=/sc-camel-on-change=
  <select>             ->  <sc-raw-select>
  local asset src=     ->  the manifest's asset uuid
  Google Fonts <link>  ->  the inlined @font-face css in tools/fonts-inline.html
  drops the bundler thumbnail <template>

Everything else in dist (the asset manifest, the fonts themselves) is left
untouched. Run after editing the .dc.html:  python3 tools/build-dist.py
"""
import io, json, re, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Darul-Ilm Challenge.dc.html")
DIST = os.path.join(ROOT, "dist", "index.html")
FONTS = os.path.join(ROOT, "tools", "fonts-inline.html")
TPL = re.compile(r'(<script type="__bundler/template">)(.*?)(</script>)', re.S)

ASSETS = {
    'src="./support.js"':            'src="59d5d649-5f9a-471a-ae1c-fe59751c9301"',
    'src="assets/darul-ilm-logo.jpeg"': 'src="bc2c7d68-ace4-4a69-af4e-85d2547fca71"',
}

def to_template(src, fonts):
    t = src.replace('onClick="', 'sc-camel-on-click="')
    t = t.replace('onChange="', 'sc-camel-on-change="')
    t = t.replace("<select ", "<sc-raw-select ").replace("</select>", "</sc-raw-select>")
    for a, b in ASSETS.items():
        t = t.replace(a, b)
    t = re.sub(r'<link href="https://fonts\.googleapis\.com/css2\?[^"]*" rel="stylesheet" />', fonts, t)
    t = re.sub(r'<template id="__bundler_thumbnail">.*?</template>\n?', '', t, flags=re.S)
    return t

def main():
    src = io.open(SRC, encoding="utf-8").read()
    fonts = io.open(FONTS, encoding="utf-8").read()
    full = io.open(DIST, encoding="utf-8").read()
    m = TPL.search(full)
    if not m:
        sys.exit("dist/index.html: no __bundler/template block found")

    tpl = to_template(src, fonts)
    # json.dumps makes a valid JS string; "</" is then escaped so the embedded
    # markup cannot close the surrounding <script> tag early.
    enc = json.dumps(tpl, ensure_ascii=False).replace("</", "<\\u002F")
    out = full[: m.start(2)] + enc + full[m.end(2):]
    io.open(DIST, "w", encoding="utf-8").write(out)

    assert json.loads(TPL.search(out).group(2)) == tpl, "round-trip failed"
    print("dist/index.html rebuilt — template %d chars, file %d chars" % (len(tpl), len(out)))

if __name__ == "__main__":
    main()
