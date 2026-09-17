---
name: anonymize-dump-emails
description: Anonymise les adresses e-mail et, sur demande, les GUID d'usagers (UUID MyLutece / identity store) contenus dans un dump SQL (mysqldump / mariadb-dump, .sql ou .sql.gz), de façon déterministe et en flux, sans casser l'échappement SQL ni les jointures. À utiliser dès que l'utilisateur veut anonymiser, pseudonymiser ou nettoyer un dump de production (RGPD) avant de le charger en dev/recette, le joindre à un ticket ou le partager, ou parle de masquer les mails, e-mails, GUID ou identifiants d'usagers d'un export de base Lutece.
---

# Anonymiser les e-mails et GUID d'un dump SQL

Ce skill fournit `bin/anonymize-dump-emails.py`, un script **Python 3 sans dépendance**
qui remplace toutes les adresses e-mail d'un dump SQL par des pseudonymes et, avec `--guid`,
les GUID d'usagers (UUID 8-4-4-4-12) des tables choisies par des UUID v4 déterministes.
Le dump anonymisé se charge ensuite tel quel dans une base locale, par exemple dans
`db-init/` de l'environnement [[lutece7-docker]].

## Règle : mode minimal, aucune donnée réelle dans la conversation

Le dump est un export de production. Le script s'exécute localement et n'envoie rien, mais
**tout ce qu'une commande affiche est transmis au modèle**. Par défaut, ne faire remonter que
des **compteurs et des états**, jamais de valeurs :

- Ne jamais afficher d'adresse e-mail, de GUID, de nom, de login ou de contenu de réponse du
  dump source, ni le contenu de `--map`. Pas de `head` sur les lignes du dump, pas de listes
  `sort | uniq -c` de valeurs réelles, pas d'extraits de BLOB.
- Inventaires (domaines, tables porteuses d'UUID, adresses techniques) : produire **des
  nombres par table ou par domaine**, pas les valeurs. Si l'utilisateur doit arbitrer sur des
  valeurs précises (adresses fonctionnelles à préserver), lui indiquer la commande à lancer
  lui-même dans son terminal (`! …`) plutôt que d'en afficher le résultat.
- Vérifications de sortie : `grep -c` (nombre de résiduels), `wc -l`, `cmp`, checksums.
  Les seules valeurs affichables sont les pseudonymes générés (`user_…@example.org`, UUID
  anonymisés), qui ne sont pas des données personnelles.
- Écrire les fichiers intermédiaires dans le scratchpad de la session, jamais dans le projet.

L'utilisateur peut lever cette règle explicitement pour une commande donnée.

## Garanties du script

- **Flux ligne par ligne** : fonctionne sur des dumps de plusieurs Go, mémoire constante
  hors table de correspondance (une entrée par adresse distincte). Environ 200 000 lignes/s.
- **Déterministe** : une même adresse donne toujours le même pseudonyme (SHA-256 salé,
  insensible à la casse). Les jointures entre tables, les contraintes `UNIQUE` et les
  identifiants de connexion (`core_admin_user.email`, comptes MyLutece, `forms_response`…)
  restent cohérents.
- **Sûr pour SQL** : le pseudonyme (`user_5d180b409765@example.org`) ne contient ni quote
  ni antislash. L'échappement du dump est préservé, y compris dans du JSON échappé.
  Il fait environ 30 caractères et tient dans les `VARCHAR` usuels.
- **Pas de faux positifs** sur `DEFINER=`root`@`localhost`` ou `'user'@'%'` : le domaine
  doit avoir un TLD.
- **Fichiers binaires stockés en clair** (`core_physical_file.file_value` : PDF, images) : une
  adresse en clair dans une ligne contenant des octets de contrôle est remplacée par un pseudonyme
  de **même longueur** (`5d180b40@example.org`, `56062@x.fr`), pour ne pas décaler les offsets
  internes du fichier. Cas réel : un lien `mailto:` dans un PDF généré. Le script le signale par
  une ligne `NOTE :` ; un `ATTENTION :` indique au contraire qu'une ligne binaire a changé de
  longueur, ce qui ne doit pas arriver.
- **Entrées/sorties** : `.sql`, `.sql.gz`, stdin/stdout.

## Usage

```bash
SCRIPT=${CLAUDE_PLUGIN_ROOT}/skills/anonymize-dump-emails/bin/anonymize-dump-emails.py

# fichier vers fichier, gzip détecté par l'extension
$SCRIPT dump.sql dump.anon.sql
$SCRIPT dump.sql.gz dump.anon.sql.gz

# en pipeline
zcat dump.sql.gz | $SCRIPT | gzip > dump.anon.sql.gz
mysqldump -u lutece -p lutece | $SCRIPT > dump.anon.sql

# garder le domaine, préserver les adresses techniques
$SCRIPT --keep-domain --exclude '^noreply@' --exclude '@example\.org$' dump.sql dump.anon.sql

# rendre le résultat non reproductible et conserver la correspondance
$SCRIPT --salt "$(date +%s)" --map mapping.csv dump.sql dump.anon.sql

# e-mails + GUID d'usagers d'un site forms (réponses et attribut MyLutece "Id de l'utilisateur")
$SCRIPT --guid --guid-table forms_response --guid-table genatt_response dump.sql dump.anon.sql
```

Les statistiques (lignes traitées, occurrences remplacées, adresses distinctes,
occurrences conservées) sortent sur **stderr** ; `-q` les masque.

## Options

| Option | Effet |
|--------|-------|
| `--keep-domain` | Conserve le domaine d'origine, n'anonymise que la partie locale. Utile pour garder la distinction `@paris.fr` / externe. |
| `--domain DOM` | Domaine des pseudonymes (défaut `example.org`). |
| `--prefix PFX` | Préfixe de la partie locale (défaut `user`). |
| `--salt SEL` | Sel du hash. Sans sel, deux dumps donnent les mêmes pseudonymes, ce qui permet de comparer des exports. Avec un sel secret, la ré-identification par dictionnaire devient impossible. |
| `--exclude REGEX` | Adresses ou GUID à laisser intacts (regex, insensible à la casse, répétable) : boîtes fonctionnelles, expéditeurs techniques, UUID à préserver. |
| `--guid` | Remplace aussi les GUID/UUID par un UUID v4 déterministe (même GUID, même pseudonyme, jointures conservées). Sans `--guid-table`, **tous** les UUID du dump sont remplacés, y compris les techniques. |
| `--guid-table TABLE` | Avec `--guid` : ne traite que les `INSERT` de cette table (répétable, INSERT multi-lignes suivis). Recommandé pour épargner les UUID techniques. |
| `--map FILE` | Écrit la correspondance `original;anonymise` (e-mails puis GUID) en CSV. **Fichier sensible**, à ne jamais livrer avec le dump. |
| `-q` | Pas de statistiques. |

## GUID : inventorier avant de remplacer

Un dump Lutece contient des UUID **techniques** qu'il faut conserver (`workflow_action.uid_action`,
`workflow_state.uid_state`, `workflow_task.uid_task`, `workflow_workflow.uid_workflow`,
`forms_lucene_lock.uuid`, clés d'export/import) et des UUID **d'usagers** : `forms_response.guid`
et, dans `genatt_response.response_value`, les réponses des entrées de type « Attribut de
l'utilisateur MyLutece » (question « Id de l'utilisateur »). Le même GUID apparaît dans les deux
tables : `--guid-table forms_response --guid-table genatt_response` les remplace de façon cohérente.

Pour inventorier les tables porteuses d'UUID dans un autre dump (INSERT multi-lignes suivis) :

```bash
awk '/^INSERT INTO `/{match($0,/`[a-z_]+`/); t=substr($0,RSTART,RLENGTH)}
     { s=$0; while (match(s,/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/)) { c[t]++; s=substr(s,RSTART+RLENGTH) } }
     END{for(k in c) print c[k], k}' dump.sql | sort -rn
```

Puis, base chargée, vérifier quelles colonnes et quelles questions portent ces valeurs
(`genatt_response` joint à `genatt_entry` / `genatt_entry_type`).

## Procédure recommandée

1. Demander à l'utilisateur le dump source, la destination et si des adresses doivent
   être préservées (boîtes techniques `noreply@`, comptes de test). Demander si les GUID
   d'usagers doivent aussi être anonymisés : inventorier alors les tables (section précédente).
2. Lancer le script avec `--salt` si le dump sort du périmètre de l'équipe (ticket,
   prestataire). Sans `--map`, sauf demande explicite.
3. Lire les statistiques sur stderr : elles ne contiennent que des compteurs. Une ligne
   `NOTE : N ligne(s) contenant des octets de contrôle ... même longueur` est normale : une
   adresse en clair dans un fichier stocké en base a été pseudonymisée sans changer la taille du
   fichier. Un `ATTENTION : ... ont changé de longueur` demande vérification : comparer la
   longueur des lignes concernées entre source et sortie (jamais leur contenu), et exclure le
   motif avec `--exclude` si c'est du bruit.
4. Vérifier qu'il ne reste aucune adresse réelle (`-a` force le mode texte, sinon grep se
   tait sur un dump contenant des BLOB) :

   ```bash
   # nombre d'adresses résiduelles (TLD suivi d'un séparateur, ce qui écarte le bruit de BLOB)
   grep -aoP '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?![A-Za-z0-9-])' dump.anon.sql \
     | grep -vE '@example\.org$' | grep -cvE '\.\.|@\.'
   # avec --guid : nombre de GUID d'origine encore présents (liste extraite de la base source, jamais affichée)
   grep -aciFf guids_source.txt dump.anon.sql
   ```

   Le résultat attendu est `0`, ou le nombre d'adresses volontairement exclues. En cas de
   résidu, afficher le **domaine** ou la **table** concernés, pas la valeur. Des résidus du type
   `x@y..z` sont du bruit de BLOB binaire que le grep large attrape mais que le script ignore.
5. Rappeler que le compte admin conserve son mot de passe : pour se connecter en local,
   utiliser `reset-admin.sh` du skill [[lutece7-docker]] et retrouver le login dans
   `core_admin_user.access_code` (le login n'est pas l'e-mail).

## Limites

- Ne traite que les **e-mails** et, sur demande, les **GUID**. Noms, prénoms, téléphones,
  adresses postales, IBAN et contenus libres des réponses de formulaires (`genatt_response`)
  restent en clair. Pour ces colonnes, compléter par des `UPDATE` ciblés après import.
- Un GUID remplacé ne correspond plus à rien dans l'identity store : les écrans qui
  interrogent l'identité de l'usager à partir du GUID (MyLutece, notifications GRU)
  ne trouveront personne en local. C'est le but, mais à savoir pour les tests.
- Ne détecte pas les adresses stockées en **binaire ou hexadécimal** (`--hex-blob` sur
  des colonnes texte, BLOB sérialisés, base64).
- Dans un fichier binaire stocké en clair, seule une adresse en zone texte non compressée
  (métadonnées PDF, lien `mailto:`, XML) est visible et remplacée à longueur constante. Une
  adresse dans un flux compressé ou une image reste en clair pour qui décompresse le fichier.
- Un e-mail scindé sur deux lignes (retour à la ligne dans une valeur `TEXT`) n'est pas
  reconnu. Rare dans un dump `mysqldump` standard, qui échappe `\n`.
