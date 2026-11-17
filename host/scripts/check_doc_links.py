import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids = set()
        self.links = []
        self.feed(path.read_text())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a":
            if "name" in attrs:
                self.ids.add(attrs["name"])
            if "href" in attrs:
                self.links.append(attrs["href"])


def main():
    root = Path(sys.argv[1]).resolve()
    pages = {path: Page(path) for path in root.rglob("*.html")}
    if not pages:
        raise SystemExit(f"{root}: no HTML documentation found")

    failures = set()
    for path, page in pages.items():
        for link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc or url.path.startswith("/"):
                continue
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            if not target.exists():
                failures.add((str(path.relative_to(root)), link, "missing file"))
            elif url.fragment and target in pages and unquote(url.fragment) not in pages[target].ids:
                failures.add((str(path.relative_to(root)), link, "missing fragment"))

    for path, link, reason in sorted(failures):
        print(f"{path}: {link}: {reason}", file=sys.stderr)
    if failures:
        raise SystemExit(1)
    print(f"Checked local links in {len(pages)} HTML pages")


if __name__ == "__main__":
    main()
