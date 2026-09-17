#!/usr/bin/env python3
"""
Anonymise les adresses e-mail (et, sur demande, les GUID) contenus dans un dump SQL
(mysqldump / mariadb-dump, pg_dump en texte, ou tout fichier texte).

Principes :
  - Traitement en flux, ligne par ligne : fonctionne sur des dumps de plusieurs Go.
  - Remplacement DÉTERMINISTE : une même valeur donne toujours le même pseudonyme
    (hash SHA-256 salé), ce qui préserve les jointures, l'unicité et les contraintes
    UNIQUE entre tables.
  - Le remplacement ne contient que des caractères sûrs pour une chaîne SQL
    (pas de quote, pas d'antislash), donc l'échappement du dump est préservé.
  - Longueur bornée : e-mail ~30 caractères, GUID 36 caractères (même format UUID v4).

Exemples :
  anonymize-dump-emails dump.sql dump.anon.sql
  anonymize-dump-emails dump.sql.gz dump.anon.sql.gz
  zcat dump.sql.gz | anonymize-dump-emails | gzip > dump.anon.sql.gz
  anonymize-dump-emails --keep-domain --exclude 'noreply@.*' dump.sql dump.anon.sql
  anonymize-dump-emails --salt "$(date +%s)" --map mapping.csv dump.sql dump.anon.sql
  anonymize-dump-emails --guid --guid-table forms_response --guid-table genatt_response dump.sql dump.anon.sql
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

# UUID 8-4-4-4-12, bornes hexa strictes pour ne pas mordre dans un hash plus long
GUID_RE = re.compile(
    r"(?<![0-9A-Fa-f])"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    r"(?![0-9A-Fa-f])"
)

# début d'un INSERT (mono ou multi-lignes) : mémorise la table courante
INSERT_RE = re.compile(r"^INSERT\s+(?:IGNORE\s+)?INTO\s+`?([A-Za-z0-9_$]+)`?", re.IGNORECASE)

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
    p = argparse.ArgumentParser(description="Anonymise les e-mails (et GUID) d'un dump SQL (flux, déterministe).")
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
                   help="regex (insensible à la casse) des adresses ou GUID à laisser intacts ; répétable")
    p.add_argument("--guid", action="store_true",
                   help="anonymiser aussi les GUID/UUID (8-4-4-4-12) par un UUID v4 déterministe")
    p.add_argument("--guid-table", action="append", default=[], metavar="TABLE",
                   help="avec --guid : ne traiter que les INSERT de cette table ; répétable. "
                        "Sans cette option, tous les GUID du dump sont remplacés (y compris les UUID techniques)")
    p.add_argument("--map", metavar="FILE",
                   help="écrire la correspondance original;anonymisé (CSV). ATTENTION : fichier sensible")
    p.add_argument("-q", "--quiet", action="store_true", help="pas de statistiques sur stderr")
    args = p.parse_args()

    excludes = [re.compile(r, re.IGNORECASE) for r in args.exclude]
    guid_tables = {t.lower() for t in args.guid_table}
    mapping = {}
    mapping_bin = {}
    guid_mapping = {}
    stats = {"lines": 0, "replaced": 0, "kept": 0, "binary_modified": 0, "binary_resized": 0,
             "guid_replaced": 0, "guid_kept": 0}

    def digest(value):
        return hashlib.sha256((args.salt + value.lower()).encode("utf-8")).hexdigest()

    def anonymize(local, domain):
        original = f"{local}@{domain}"
        cached = mapping.get(original)
        if cached is not None:
            return cached
        target_domain = domain if args.keep_domain else args.domain
        anon = f"{args.prefix}_{digest(original)[:12]}@{target_domain}"
        mapping[original] = anon
        return anon

    def anonymize_same_length(local, domain):
        """Pseudonyme de MÊME LONGUEUR que l'original, pour une adresse en clair dans un fichier
        binaire (PDF, image, archive) : ne pas décaler les offsets internes du fichier."""
        original = f"{local}@{domain}"
        cached = mapping_bin.get(original)
        if cached is not None:
            return cached
        total = len(original)
        h = digest(original)
        target_domain = domain if args.keep_domain else args.domain
        if total - 1 - len(target_domain) < 1:
            target_domain = "x.fr" if total >= 6 else "fr"   # adresses très courtes
        local_len = total - 1 - len(target_domain)
        prefix = args.prefix + "_"
        if local_len > len(prefix) + 4:
            local_part = prefix + h[: local_len - len(prefix)]
        else:
            local_part = h[:local_len]
        anon = f"{local_part}@{target_domain}"
        if len(anon) != total:            # sécurité : ne jamais changer la longueur
            anon = (anon + h)[:total]
        mapping_bin[original] = anon
        return anon

    def anonymize_guid(original):
        key = original.lower()
        cached = guid_mapping.get(key)
        if cached is not None:
            return cached
        h = digest(key)
        # format UUID v4 : version 4, variant 8..b
        anon = f"{h[0:8]}-{h[8:12]}-4{h[13:16]}-{'89ab'[int(h[16], 16) % 4]}{h[17:20]}-{h[20:32]}"
        guid_mapping[key] = anon
        return anon

    def repl(m):
        local, domain = m.group(1), m.group(2)
        original = f"{local}@{domain}"
        if any(rx.search(original) for rx in excludes):
            stats["kept"] += 1
            return original
        stats["replaced"] += 1
        return anonymize(local, domain)

    def repl_bin(m):
        local, domain = m.group(1), m.group(2)
        original = f"{local}@{domain}"
        if any(rx.search(original) for rx in excludes):
            stats["kept"] += 1
            return original
        stats["replaced"] += 1
        return anonymize_same_length(local, domain)

    def repl_guid(m):
        original = m.group(0)
        if any(rx.search(original) for rx in excludes):
            stats["guid_kept"] += 1
            return original
        stats["guid_replaced"] += 1
        return anonymize_guid(original)

    current_table = None
    with open_in(args.input) as fin, open_out(args.output) as fout:
        for line in fin:
            stats["lines"] += 1
            m = INSERT_RE.match(line)
            if m:
                current_table = m.group(1).lower()
            new_line = line
            is_bin = ("@" in line or "-" in line) and CTRL_RE.search(line) is not None
            if "@" in new_line:
                # ligne binaire (BLOB en clair) : pseudonyme de même longueur, offsets du fichier préservés
                new_line = EMAIL_RE.sub(repl_bin if is_bin else repl, new_line)
            if args.guid and "-" in new_line and (not guid_tables or current_table in guid_tables):
                new_line = GUID_RE.sub(repl_guid, new_line)   # un UUID anonymisé fait toujours 36 caractères
            if new_line != line and is_bin:
                stats["binary_modified"] += 1
                if len(new_line) != len(line):
                    stats["binary_resized"] += 1
            fout.write(new_line)

    if args.map:
        with open(args.map, "w", encoding="utf-8") as fmap:
            fmap.write("original;anonymise\n")
            for original, anon in sorted(mapping.items()):
                fmap.write(f"{original};{anon}\n")
            for original, anon in sorted(mapping_bin.items()):
                fmap.write(f"{original};{anon};dans un fichier binaire, longueur conservee\n")
            for original, anon in sorted(guid_mapping.items()):
                fmap.write(f"{original};{anon}\n")

    if not args.quiet:
        sys.stderr.write(
            f"lignes traitées : {stats['lines']}\n"
            f"occurrences remplacées : {stats['replaced']}\n"
            f"adresses distinctes anonymisées : {len(set(mapping) | set(mapping_bin))}\n"
            f"occurrences conservées (--exclude) : {stats['kept']}\n"
        )
        if args.guid:
            scope = ", ".join(sorted(guid_tables)) if guid_tables else "toutes les tables"
            sys.stderr.write(
                f"GUID remplacés ({scope}) : {stats['guid_replaced']} occurrences, "
                f"{len(guid_mapping)} distincts, {stats['guid_kept']} conservés (--exclude)\n"
            )
        if stats["binary_modified"]:
            sys.stderr.write(
                f"NOTE : {stats['binary_modified']} ligne(s) contenant des octets de contrôle (fichiers binaires "
                f"stockés en clair : PDF, images…) ont été modifiées, {len(mapping_bin)} adresse(s) distincte(s) "
                "remplacée(s) par un pseudonyme de même longueur pour préserver les offsets du fichier.\n"
            )
        if stats["binary_resized"]:
            sys.stderr.write(
                f"ATTENTION : {stats['binary_resized']} ligne(s) binaire(s) ont changé de longueur : "
                "un motif a été remplacé sans conservation de longueur, le fichier peut être corrompu. "
                "Vérifier ces lignes ou exclure le motif avec --exclude.\n"
            )


if __name__ == "__main__":
    main()
