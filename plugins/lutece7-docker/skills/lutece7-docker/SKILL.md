---
name: lutece7-docker
description: Déploie un environnement de développement local Lutece 7 avec Docker (Tomcat 9/JDK17 + MariaDB), incluant l'autorité de certification de la Mairie de Paris dans le cacerts de la JVM. À utiliser dès que l'utilisateur veut créer/lancer un environnement de dev Lutece 7, déployer un site Lutece 7 en local, ou monter Tomcat + MariaDB pour Lutece 7.
---

# Lutece 7 — Environnement Docker de développement

Ce skill déploie un environnement local **réutilisable** pour des sites **Lutece 7** :

- **Tomcat 9 / JDK 17** — Lutece 7 utilise `javax.servlet` (incompatible Tomcat 10+, qui est Jakarta). JDK 17 car certaines libs Lutece (`grubusiness` / `library-notifygru`) sont compilées en Java 17 ; JDK 11 provoque `UnsupportedClassVersionError`.
- **MariaDB 10.11** — données persistées, dump SQL optionnel chargé au 1er démarrage.
- **Datasource JNDI `jdbc/CORE`** — fournie par Tomcat, attendue par le profil `dev` de Lutece.
- **AC RACINE MAIRIE DE PARIS** importée dans le **cacerts de la JVM** du conteneur Tomcat (permet à Lutece de dialoguer en HTTPS avec les services internes de la Ville : SSO Keycloak, identity-store, SOLR…).

## Contenu bundle (`<skill-dir>/config/`)

- **docker-compose.yml** — services `tomcat` (image construite) + `mariadb`
- **Dockerfile.tomcat** — importe `certs/*` dans `$JAVA_HOME/lib/security/cacerts` via `keytool`
- **certs/AC RACINE MAIRIE DE PARIS** — CA racine de la Ville (déposez-y d'autres PEM au besoin)
- **.env.example** — ports, nom BDD, credentials, versions d'images
- **tomcat/conf/context.xml** — Resource JNDI `jdbc/CORE` (valeurs via propriétés système `-Ddb.*`)
- **tomcat/lib/mysql-connector-j-9.5.0.jar** — driver JDBC (requis au niveau conteneur)
- **db-init/** — dumps `*.sql` chargés au 1er boot (sinon base vide)
- **webapps/** — dépôt du webapp du site déployé
- **bin/deploy-site.sh** — build (profil `dev`) + déploiement d'un site

## Prérequis

- Docker + plugin `docker compose`
- Maven + JDK 17 côté hôte (pour builder les sites)
- Si le proxy de la Ville est nécessaire pour les pulls Docker / builds Maven, le configurer (voir skill `set-proxy`). Attention : un `HTTP_PROXY` avec `/` final casse l'installeur — pas de slash final.

## Déploiement

### 1. Installer l'environnement dans un dossier de travail

Par défaut `~/src/lutece-docker-dev` (adaptable). Copier le bundle puis créer le `.env` :

```bash
DEST=~/src/lutece-docker-dev
mkdir -p "$DEST"
cp -r ${CLAUDE_PLUGIN_ROOT}/skills/lutece7-docker/config/. "$DEST/"
cp "$DEST/.env.example" "$DEST/.env"     # puis ajuster si besoin
```

### 2. (Optionnel) Déposer un dump SQL

```bash
cp /chemin/vers/dump.sql "$DEST/db-init/01-core.sql"
```
Sans dump, MariaDB crée une base vide `${DB_NAME}`. Le dump n'est chargé qu'au **1er** démarrage (volume vierge) ; pour rejouer : `docker compose down -v && docker compose up -d`.

### 3. Construire et démarrer (le `--build` importe le CA dans le cacerts)

```bash
cd "$DEST"
docker compose up -d --build
```

### 4. Builder et déployer un site Lutece 7

```bash
cd "$DEST"
bin/deploy-site.sh /chemin/vers/le/site-lutece
```

Le packaging `lutece-site` **ne produit pas de WAR autonome** : le helper assemble le webapp complet (`core` + jars plugins + overlay) via `mvn -Pdev clean lutece:exploded` (→ `target/lutece`) et copie ce répertoire dans `webapps/<artifactId-version>`. Tomcat déploie un répertoire explosé comme un contexte.

## Après démarrage

Contexte = `<artifactId>-<version>` (ex. `site-decider-3.0.0`), port par défaut `8080` :

```
  Front office  http://localhost:8080/<contexte>/jsp/site/Portal.jsp
  Back office   http://localhost:8080/<contexte>/jsp/admin/AdminMenu.jsp

  Logs: docker compose logs -f tomcat
```

## Convention de déploiement des sites

Les sites doivent être buildés avec un profil exposant la datasource en **JNDI `jdbc/CORE`** (profil `dev` de la plupart des sites Ville : `TomcatConnectionService` + `portal.ds=jdbc/CORE`).

> Le profil `default` (connexion directe `localhost`) **ne fonctionne pas** en conteneur : depuis le conteneur Tomcat, « localhost » n'est pas le conteneur MariaDB. C'est Tomcat (`tomcat/conf/context.xml`) qui fournit la connexion réelle, pointant sur le service `mariadb`.

## Vérifier l'import du CA

```bash
docker compose exec tomcat keytool -list \
  -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit \
  | grep -i paris
```

## Commandes utiles

```bash
docker compose up -d --build        # (re)construire + démarrer
docker compose logs -f tomcat       # logs Tomcat / Lutece
docker compose ps                   # état des conteneurs
docker compose restart tomcat       # redéployer après copie d'un webapp
docker compose down                 # arrêter (conserve les données)
docker compose down -v              # arrêter + supprimer la base
mysql -h 127.0.0.1 -P 3307 -u lutece -plutece lutece   # accès BDD direct
```

## Dépannage

- **`UnsupportedClassVersionError` (class file 61.0)** — une lib est compilée en Java 17 ; l'image est bien en JDK 17 (`TOMCAT_IMAGE=tomcat:9.0-jdk17-temurin`).
- **Front redirige vers `*.paris.mdp` / back office « Error loading user information »** — le profil `dev` route l'auth via le SSO/identity-store de la Ville, injoignable hors réseau interne. Pour un usage 100 % local, basculer sur l'auth base de données (surcharges `mylutece*.properties`, `oauth2`, `identitystore*` dans le webapp déployé).
- **Conflits de dépendances Maven au build du site** — le POM du site abuse souvent de ranges ouverts `[x,)` sur des plugins passés en Lutece 8. Figer les versions fautives sur leur dernière release core 7 ; le jeu de référence est celui de recette/prod.
- **`keytool` échoue au build** — vérifier que `certs/` contient bien un PEM valide ; mot de passe cacerts par défaut `changeit`.
- **Port déjà utilisé** — changer `TOMCAT_HTTP_PORT` / `DB_PORT` dans `.env`.

## Ajouter d'autres autorités de certification

Déposer les fichiers PEM dans `<dest>/certs/` puis reconstruire :
```bash
docker compose up -d --build
```
