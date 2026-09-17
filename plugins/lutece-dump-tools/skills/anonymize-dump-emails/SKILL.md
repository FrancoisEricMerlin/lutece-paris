---
name: anonymize-dump-emails
description: Anonymise les adresses e-mail contenues dans un dump SQL (mysqldump / mariadb-dump, .sql ou .sql.gz) de façon déterministe et en flux, sans casser l'échappement SQL ni les jointures. À utiliser dès que l'utilisateur veut anonymiser, pseudonymiser ou nettoyer un dump de production (RGPD) avant de le charger en dev/recette, le joindre à un ticket ou le partager, ou parle de masquer les mails/e-mails d'un export de base Lutece.
---

# Anonymiser les e-mails d'un dump SQL

Ce skill fournit `bin/anonymize-dump-emails.py`, un script **Python 3 sans dépendance**
qui remplace toutes les adresses e-mail d'un dump SQL par des pseudonymes.
Le dump anonymisé se charge ensuite tel quel dans une base locale, par exemple dans
`db-init/` de l'environnement [[lutece7-docker]].

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
| `--exclude REGEX` | Adresses à laisser intactes (regex, insensible à la casse, répétable) : boîtes fonctionnelles, expéditeurs techniques. |
| `--map FILE` | Écrit la correspondance `original;anonymise` en CSV. **Fichier sensible**, à ne jamais livrer avec le dump. |
| `-q` | Pas de statistiques. |

## Procédure recommandée

1. Demander à l'utilisateur le dump source, la destination et si des adresses doivent
   être préservées (boîtes techniques `noreply@`, comptes de test).
2. Lancer le script avec `--salt` si le dump sort du périmètre de l'équipe (ticket,
   prestataire). Sans `--map`, sauf demande explicite.
3. Lire les statistiques sur stderr. Un message `ATTENTION : N ligne(s) contenant des
   octets de contrôle ... ont été modifiées` signale qu'un motif ressemblant à un e-mail a
   été remplacé dans un BLOB binaire (PDF, image stockés en base) : comparer ces lignes
   entre source et sortie, et exclure le motif avec `--exclude` si c'est du bruit.
4. Vérifier qu'il ne reste aucune adresse réelle (`-a` force le mode texte, sinon grep se
   tait sur un dump contenant des BLOB) :

   ```bash
   grep -aoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' dump.anon.sql \
     | grep -vE '@example\.org$' | sort | uniq -c | sort -rn | head -30
   ```

   Seules les adresses exclues volontairement doivent apparaître. Des résidus du type
   `Zfj@2jFYuo.fUte` ou `u@m.MOV`, présents en nombre identique, sont du bruit de BLOB
   binaire que ce grep large attrape mais que le script ignore (TLD suivi de chiffres) :
   ils existaient déjà dans la source et ne sont pas des adresses.
5. Rappeler que le compte admin conserve son mot de passe : pour se connecter en local,
   utiliser `reset-admin.sh` du skill [[lutece7-docker]] et retrouver le login dans
   `core_admin_user.access_code` (le login n'est pas l'e-mail).

## Limites

- Ne traite que les **e-mails**. Noms, prénoms, téléphones, adresses postales, IBAN et
  contenus libres des réponses de formulaires (`forms_response`, `genatt_response`)
  restent en clair. Pour ces colonnes, compléter par des `UPDATE` ciblés après import.
- Ne détecte pas les adresses stockées en **binaire ou hexadécimal** (`--hex-blob` sur
  des colonnes texte, BLOB sérialisés, base64).
- Inversement, un BLOB binaire stocké en clair peut contenir par hasard un motif valide
  d'e-mail : il serait remplacé et le BLOB corrompu. Le script avertit sur stderr quand
  une ligne contenant des octets de contrôle est modifiée (voir procédure).
- Un e-mail scindé sur deux lignes (retour à la ligne dans une valeur `TEXT`) n'est pas
  reconnu. Rare dans un dump `mysqldump` standard, qui échappe `\n`.
