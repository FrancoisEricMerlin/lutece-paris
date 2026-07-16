---
name: test-plugin-pr
description: Teste une PR (pull request) GitHub d'un plugin Lutece 7 sur le site site-integration-forms tournant dans l'environnement Docker lutece7-docker. Récupère la PR, la build, la déploie (swap de jar ou rebuild complet selon l'impact SQL), prépare l'accès admin sur base fraîche, et permet de reproduire/valider un comportement. À utiliser dès que l'utilisateur veut tester une PR/pull request d'un plugin Lutece, déployer une version PR (ex. plugin-forms) sur site-integration-forms, reproduire un bug d'une PR, ou valider un correctif en local.
---

# Tester une PR de plugin Lutece 7 sur site-integration-forms

Ce skill déploie et teste une **PR GitHub d'un plugin Lutece 7** sur le site
**site-integration-forms** qui tourne dans l'environnement Docker fourni par le
skill [[lutece7-docker]] (Tomcat 9/JDK17 + MariaDB, datasource JNDI `jdbc/CORE`).

## Prérequis

- L'environnement `lutece7-docker` est **démarré** et **site-integration-forms
  déployé** (conteneurs `lutece7-tomcat` + `lutece7-mariadb`). Sinon, invoquer
  d'abord le skill [[lutece7-docker]] et déployer le site avec `bin/deploy-site.sh`.
- Base MariaDB **vide, initialisée par Liquibase** (`liquibase.enabled.at.startup=true`
  dans le webapp). Pour repartir de zéro : `docker compose down -v && up -d --build`.
- `python3` (pour le hash admin), Docker, Maven + JDK 17 côté hôte.
- Accès réseau/proxy pour GitHub et les dépôts Maven Lutece (skill `set-proxy`).

Les scripts sont dans `<skill-dir>/bin/` et supposent les défauts de `lutece7-docker` :
`DEST=~/src/lutece-docker-dev`, conteneurs `lutece7-tomcat` / `lutece7-mariadb`,
webapp déployé sous `webapps/<artifactId-version>`.

## Deux stratégies de déploiement

| Cas | Stratégie | Coût |
|-----|-----------|------|
| **La PR ne change pas le SQL** (schéma identique à la release) | **Swap du jar** dans `WEB-INF/lib` du webapp déployé + restart. Le descripteur de plugin de la release reste en place → aucune migration. | rapide |
| **La PR change le SQL / ajoute des ressources webapp** | **Rebuild complet du site** avec la version PR + **base vide** (Liquibase rejoue le schéma). | lourd |

`fetch-build-plugin-pr.sh` indique automatiquement le cas (diff SQL vs dernier tag).

## Procédure (cas rapide : swap de jar)

### 1. Récupérer + builder la PR

```bash
bin/fetch-build-plugin-pr.sh <artifactId|git-url> <pr-number> [workdir]
# ex : bin/fetch-build-plugin-pr.sh plugin-forms 635
```

Le script résout l'URL du dépôt depuis le `<scm>` du POM en `~/.m2` (ou accepte
une URL git directe), récupère la PR via `git fetch origin pull/<N>/head` (pas
besoin de `gh` authentifié), signale l'impact SQL, puis build (`mvn clean install
-Dmaven.test.skip=true`). Il affiche le chemin du **jar PR**.

### 2. Déployer le jar + redémarrer

```bash
bin/deploy-plugin-jar.sh <path-to-jar-PR>
```

Remplace `<artifactId>-*.jar` dans le webapp déployé et redémarre Tomcat (attend
`started successfully`).

### 3. Préparer l'accès back-office (base fraîche)

```bash
bin/prepare-admin.sh                 # admin / adminadmin, tous droits
```

Sur une base neuve, le compte `admin` n'a pas de mot de passe connu et **aucun
droit de plugin** n'est assigné → ce script fixe le mot de passe (hash PBKDF2 au
format Lutece) et accorde tous les droits `core_admin_right` à l'utilisateur 1.

### 4. Tester / reproduire

- Back-office : `http://localhost:8080/<contexte>/jsp/admin/AdminLogin.jsp` (`admin`/`adminadmin`)
- Front-office : `http://localhost:8080/<contexte>/jsp/site/Portal.jsp`
- Logs : `cd ~/src/lutece-docker-dev && docker compose logs -f tomcat`
- Base : `docker exec lutece7-mariadb mysql -ulutece -plutece lutece -e "..."`

Pour automatiser des parcours UI complexes (créer un formulaire, soumettre une
réponse), utiliser Playwright Python (skill `webapp-testing`) : connexion sur
`DoAdminLogin.jsp` (champs `access_code` / `password` / `token`).

## Procédure (cas lourd : rebuild complet du site)

Quand la PR touche le SQL / les ressources webapp :

1. Builder la PR (étape 1 ci-dessus → jar + `-webapp.zip` installés en `~/.m2`).
2. Pointer la dépendance du plugin vers la **version PR** (SNAPSHOT) dans le pom
   du site (ou du `forms-starter`) puis `mvn install` ce module.
3. Repartir base vide : `cd ~/src/lutece-docker-dev && docker compose down -v && docker compose up -d --build`.
4. Rebuild + redéploiement du site : `bin/deploy-site.sh <chemin-du-site>` (skill lutece7-docker).
5. `bin/prepare-admin.sh` puis tester.

> **Résolution des SNAPSHOT** : en ligne, Maven peut préférer un SNAPSHOT distant
> plus récent que ton build local. Pour garantir l'usage de TON build : construire
> le site en `-o` (offline) **ou** écraser le jar résolu dans `target/lutece/WEB-INF/lib`
> par ton jar avant de copier le webapp.

## Pièges connus (base Lutece 7 fraîche + Docker)

- **Mot de passe admin** : inconnu par défaut → `prepare-admin.sh` (hash
  `PBKDF2WITHHMACSHA512:210000:<sel16o hex>:<hash128o hex>`, `pbkdf2_hmac('sha512', pw, salt, 210000, dklen=128)`).
- **Droits plugins** : non assignés à l'admin sur base neuve → `prepare-admin.sh`.
- **Cache des formulaires** : une modif faite directement en base (ex.
  `availability_start_date`) n'est pas vue tant que le cache n'est pas invalidé
  → passer par l'UI ou **redémarrer Tomcat**.
- **Formulaire "inactif"** : `Form.isActive()` exige `availability_start_date`
  non-null et passé (et `end_date` null ou futur).
- **`plugins.dat` / droits** : le webapp `WEB-INF/plugins/*.xml` porte la version
  du descripteur ; en swap de jar on la laisse = release → pas de migration.

## Exemple concret : PR #635 de plugin-forms (bug d'indexation Lucene)

PR *LUT-32413* (tri des colonnes liste). Le correctif écrit le `SortedDocValuesField`
de tri sous `entry_code_<code>_iter_<n>` (sans discriminant de field) → une case à
cocher multi-cochée produit plusieurs docvalues de même nom →
`IllegalArgumentException: DocValuesField ... appears more than once`.

Reproduction :
1. `fetch-build-plugin-pr.sh plugin-forms 635` (aucun diff SQL → swap OK).
2. `deploy-plugin-jar.sh .../target/plugin-forms-3.1.6-SNAPSHOT.jar`.
3. `prepare-admin.sh`.
4. Créer un formulaire avec une question **case à cocher** (≥2 options), publier
   (dates de dispo), soumettre une réponse **multi-cochée**.
5. Déclencher l'indexation : back-office
   `jsp/admin/plugins/forms/ManageFormsSearchIndexation.jsp` → *Lancer l'indexation
   totale* (ou attendre le daemon `formsIndexerDaemon`), puis
   `docker compose logs -f tomcat` → l'`IllegalArgumentException` apparaît.

Vérifier le succès d'un correctif : la file `forms_indexer_action` revient à 0 et
la réponse apparaît dans la multivue (`MultiviewForms.jsp?current_selected_panel=forms&id_form=<id>`).
