#!/usr/bin/env python3
"""
Anonymise les adresses e-mail contenues dans un dump SQL (mysqldump / mariadb-dump,
pg_dump en texte, ou tout fichier texte).

Principes :
  - Traitement en flux, ligne par ligne : fonctionne sur des dumps de plusieurs Go.
  - Remplacement DÉTERMINISTE : une même adresse donne toujours la même adresse
    anonymisée (hash SHA-256 salé), ce qui préserve les jointures, l'unicité
    et les contraintes UNIQUE entre tables.
  - Le remplacement ne contient que des caractères sûrs pour une chaîne SQL
    (pas de quote, pas d'antislash), donc l'échappement du dump est préservé.
  - Longueur bornée (~30 caractères) pour rester dans les VARCHAR usuels.

Exemples :
  anonymize-dump-emails dump.sql dump.anon.sql
  anonymize-dump-emails dump.sql.gz dump.anon.sql.gz
  zcat dump.sql.gz | anonymize-dump-emails | gzip > dump.anon.sql.gz
  anonymize-dump-emails --keep-domain --exclude 'noreply@.*' dump.sql dump.anon.sql
  anonymize-dump-emails --salt "$(date +%s)" --map mapping.csv dump.sql dump.anon.sql
"""

import argparse
import gzip
import hashlib
import io
import re
import sys

EMAIL_RE = re.compile(
    r"(?<![A-Za-z0-9._%+\-])"          # début de la partie locale
    r"([A-Za-z0-9._%+\-]+)"            # partie locale (DEFINER=`root`@`localhost` ne matche pas : pas de TLD)
    r"@"
    r"([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,})"  # domaine avec TLD
    r"(?![A-Za-z0-9\-])"
)

# octets de contrôle : signature d'un BLOB binaire (PDF, image, objet sérialisé) stocké en clair
CTRL_RE = re.compile(r"[\x00-\x08\x0e-\x1f]")


def open_in(path):
    if path in (None, "-"):
        return io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="surrogateescape", newline="")
    if path.endswith(".gz"):
        return io.TextIOWrapper(gzip.open(path, "rb"), encoding="utf-8", errors="surrogateescape", newline="")
    return open(path, "r", encoding="utf-8", errors="surrogateescape", newline="")


def open_out(path):
    if path in (None, "-"):
        return io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="surrogateescape", newline="")
    if path.endswith(".gz"):
        return io.TextIOWrapper(gzip.open(path, "wb"), encoding="utf-8", errors="surrogateescape", newline="")
    return open(path, "w", encoding="utf-8", errors="surrogateescape", newline="")


def main():
    p = argparse.ArgumentParser(description="Anonymise les e-mails d'un dump SQL (flux, déterministe).")
    p.add_argument("input", nargs="?", default="-", help="dump en entrée (.sql ou .sql.gz, '-' = stdin)")
    p.add_argument("output", nargs="?", default="-", help="dump en sortie ('-' = stdout, .gz accepté)")
    p.add_argument("--domain", default="example.org",
                   help="domaine des adresses générées (défaut : example.org)")
    p.add_argument("--keep-domain", action="store_true",
                   help="conserver le domaine d'origine, n'anonymiser que la partie locale")
    p.add_argument("--prefix", default="user",
                   help="préfixe de la partie locale générée (défaut : user)")
    p.add_argument("--salt", default="",
                   help="sel ajouté au hash ; sans sel, le résultat est reproductible d'un dump à l'autre")
    p.add_argument("--exclude", action="append", default=[], metavar="REGEX",
                   help="regex (insensible à la casse) des adresses à laisser intactes ; répétable")
    p.add_argument("--map", metavar="FILE",
                   help="écrire la correspondance original;anonymisé (CSV). ATTENTION : fichier sensible")
    p.add_argument("-q", "--quiet", action="store_true", help="pas de statistiques sur stderr")
    args = p.parse_args()

    excludes = [re.compile(r, re.IGNORECASE) for r in args.exclude]
    mapping = {}
    stats = {"lines": 0, "replaced": 0, "kept": 0, "binary_modified": 0}

    def anonymize(local, domain):
        original = f"{local}@{domain}"
        cached = mapping.get(original)
        if cached is not None:
            return cached
        digest = hashlib.sha256((args.salt + original.lower()).encode("utf-8")).hexdigest()[:12]
        target_domain = domain if args.keep_domain else args.domain
        anon = f"{args.prefix}_{digest}@{target_domain}"
        mapping[original] = anon
        return anon

    def repl(m):
        local, domain = m.group(1), m.group(2)
        original = f"{local}@{domain}"
        if any(rx.search(original) for rx in excludes):
            stats["kept"] += 1
            return original
        stats["replaced"] += 1
        return anonymize(local, domain)

    with open_in(args.input) as fin, open_out(args.output) as fout:
        for line in fin:
            stats["lines"] += 1
            if "@" in line:
                new_line = EMAIL_RE.sub(repl, line)
                if new_line != line and CTRL_RE.search(line):
                    stats["binary_modified"] += 1
                line = new_line
            fout.write(line)

    if args.map:
        with open(args.map, "w", encoding="utf-8") as fmap:
            fmap.write("original;anonymise\n")
            for original, anon in sorted(mapping.items()):
                fmap.write(f"{original};{anon}\n")

    if not args.quiet:
        sys.stderr.write(
            f"lignes traitées : {stats['lines']}\n"
            f"occurrences remplacées : {stats['replaced']}\n"
            f"adresses distinctes anonymisées : {len(mapping)}\n"
            f"occurrences conservées (--exclude) : {stats['kept']}\n"
        )
        if stats["binary_modified"]:
            sys.stderr.write(
                f"ATTENTION : {stats['binary_modified']} ligne(s) contenant des octets de contrôle "
                "(BLOB binaires ?) ont été modifiées. Un motif ressemblant à un e-mail dans un BLOB "
                "a pu être remplacé : vérifier ces lignes ou exclure le motif avec --exclude.\n"
            )


if __name__ == "__main__":
    main()
