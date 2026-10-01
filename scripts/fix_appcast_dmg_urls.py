#!/usr/bin/env python3
"""Point every full-DMG enclosure in an appcast at its own release (issue #274).

generate_appcast takes one --download-url-prefix, the release being published,
and applies it to every item it regenerates from a local DMG, so older items end
up at releases/download/v<new>/Canopy-<old>.dmg, which 404s. release.sh always
attaches Canopy-<V>.dmg to v<V>, so the file name alone says where it lives.
Delta enclosures are left alone: they already resolve.

Usage: fix_appcast_dmg_urls.py <appcast.xml>   rewrites in place, prints each change
"""
import re
import sys

DMG_URL = re.compile(r'(url="https://github\.com/[^"]*/releases/download/)v([^/"]+)/(Canopy-(\d+\.\d+\.\d+)\.dmg)"')


def fix(xml):
    """Returns the rewritten xml and a list of (old_tag, version) changes."""
    changes = []

    def repl(match):
        prefix, tag, name, version = match.groups()
        if tag == version:
            return match.group(0)
        changes.append((tag, version))
        return '%sv%s/%s"' % (prefix, version, name)

    return DMG_URL.sub(repl, xml), changes


if __name__ == "__main__":
    path = sys.argv[1]
    xml = open(path).read()
    new, changes = fix(xml)
    for tag, version in changes:
        print("  Canopy-%s.dmg: v%s -> v%s" % (version, tag, version))
    if new != xml:
        open(path, "w").write(new)
