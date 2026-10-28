#!/usr/bin/env python3
# Apply exact line replacements to text files inside a DMROMFS1 RomFS image (or a
# loose RomFS folder), in place: the profile's romfs_patch.tsv names, per file,
# the stripped stock line, the stripped replacement line and how many times the
# stock line occurs. A replacement keeps the line's own indentation and its CR
# when the file uses CRLF endings, so the patched file is byte-identical to the
# same edit made in a text editor. The image is rebuilt with the same entry
# tree and name pool; only the patched files' data and the offsets behind them
# move. A file whose stock lines are all gone and whose replacement lines are
# all present in the stated counts counts as already patched and is left alone
# (the NSP script's extraction reuse keeps a patched image between runs).
# Every other count mismatch stops the build: a different game version's files
# must not be patched by a table made for another version's.
# Usage: romfs_patch.py <spec.tsv> <RomFS.img | RomFS folder>
import os, struct, sys
from pathlib import Path

HEAD = struct.Struct('<8sQQQ')
ENT = struct.Struct('<QQIHBB')
MAGIC = b'DMROMFS1'


def load_spec(path):
    rules = {}   # guest path -> [(old, new, count)]
    for ln, line in enumerate(Path(path).read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'): continue
        c = line.split('\t')
        if len(c) != 4: raise SystemExit(f'{path}:{ln}: a rule is "<path>\\t<stock line>\\t<replacement line>\\t<count>": {line!r}')
        p, old, new, n = c
        rules.setdefault(p, []).append((old, new, int(n)))
    if not rules: raise SystemExit(f'{path}: no rules')
    return rules


def apply_rules(data, rules, name):
    """(patched bytes, already?) — the counts of every rule must match the spec
    exactly, in one of the two states (wholly stock or wholly patched)."""
    out, state = [], None
    counts = {old: 0 for old, _, _ in rules}
    news = {new: 0 for _, new, _ in rules}
    lines = data.split(b'\n')
    for line in lines:
        cr = line.endswith(b'\r')
        s = (line[:-1] if cr else line).decode('utf-8')
        stripped = s.strip()
        if stripped in counts: counts[stripped] += 1
        if stripped in news: news[stripped] += 1
    stock = all(counts[old] == n and news[new] == 0 for old, new, n in rules)
    done = all(counts[old] == 0 and news[new] == n for old, new, n in rules)
    if done: return data, True
    if not stock:
        want = '; '.join(f'{old!r} x{n} (found stock x{counts[old]}, patched x{news[new]})' for old, new, n in rules)
        raise SystemExit(f'{name}: the patch rules do not match this file: {want}')
    m = {old: new for old, new, _ in rules}
    for line in lines:
        cr = line.endswith(b'\r')
        s = (line[:-1] if cr else line).decode('utf-8')
        stripped = s.strip()
        if stripped in m:
            line = (s[:len(s) - len(s.lstrip())] + m[stripped]).encode('utf-8') + (b'\r' if cr else b'')
        out.append(line)
    return b'\n'.join(out), False


def patch_folder(root, rules):
    changed = 0
    for rel, rs in rules.items():
        f = root / rel
        if not f.is_file(): raise SystemExit(f'{f}: no such file in the RomFS folder')
        got, done = apply_rules(f.read_bytes(), rs, rel)
        if done: print(f'romfs patch: {rel} already patched, left alone')
        else:
            tmp = f.with_name(f.name + '.part'); tmp.write_bytes(got); os.replace(tmp, f)
            print(f'romfs patch: {rel} patched ({len(rs)} rules)'); changed += 1
    return changed


def patch_image(img, rules):
    raw = Path(img)
    size = raw.stat().st_size
    with open(img, 'rb') as f:
        magic, ioff, isz, count = HEAD.unpack(f.read(HEAD.size))
        if magic != MAGIC or ioff < HEAD.size or ioff > size or isz != size - ioff:
            raise SystemExit(f'{img}: not a complete RomFS image')
        f.seek(ioff); index = f.read(isz)
    ents = [list(ENT.unpack_from(index, k * ENT.size)) for k in range(count)]   # a, b, name off, name len, type, pad
    pool = index[count * ENT.size:]
    names = [pool[e[2]:e[2] + e[3]].decode('utf-8') for e in ents]
    paths = [''] * count
    for k in range(count):
        a, b, *_ , t, _ = ents[k]
        if t == 0:
            for c in range(a, a + b): paths[c] = (paths[k] + '/' if paths[k] else '') + names[c]
    by_path = {paths[k]: k for k in range(count) if ents[k][4] == 1}
    patched = {}   # entry index -> new bytes
    for rel, rs in rules.items():
        if rel not in by_path: raise SystemExit(f'{rel}: no such file in {img}')
        k = by_path[rel]; a, b = ents[k][0], ents[k][1]
        with open(img, 'rb') as f: f.seek(a); data = f.read(b)
        got, done = apply_rules(data, rs, rel)
        if done: print(f'romfs patch: {rel} already patched, left alone')
        else: patched[k] = got; print(f'romfs patch: {rel} patched ({len(rs)} rules)')
    if not patched: return 0
    order = sorted((k for k in range(count) if ents[k][4] == 1), key=lambda k: ents[k][0])
    part = str(img) + '.part'
    with open(img, 'rb') as src, open(part, 'wb') as out:
        out.write(b'\0' * HEAD.size)
        off = HEAD.size
        for k in order:
            a, b = ents[k][0], ents[k][1]
            if k in patched: data = patched[k]
            else:
                src.seek(a); data = src.read(b)
            out.write(data); ents[k][0], ents[k][1] = off, len(data); off += len(data)
        idx = bytearray()
        for e in ents: idx += ENT.pack(*e)
        out.write(idx); out.write(pool)
        out.seek(0); out.write(HEAD.pack(MAGIC, off, len(idx) + len(pool), count))
    # Read the rebuilt image back before it replaces the original: the tree
    # must parse and every patched file must hold exactly the patched bytes.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import romfs_image
    check = romfs_image.read_index(part)
    for k, want in patched.items():
        isdir, a, b = check[paths[k]]
        with open(part, 'rb') as f: f.seek(a); got = f.read(b)
        if got != want: os.unlink(part); raise SystemExit(f'{paths[k]}: the rebuilt image does not hold the patched file')
    os.replace(part, img)
    return len(patched)


def main():
    if len(sys.argv) != 3: raise SystemExit(__doc__.splitlines()[-1].strip())
    rules = load_spec(sys.argv[1])
    target = Path(sys.argv[2])
    if target.is_dir(): patch_folder(target, rules)
    elif target.is_file(): patch_image(str(target), rules)
    else: raise SystemExit(f'{target}: no such file or folder')


if __name__ == '__main__':
    main()
