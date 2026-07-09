#!/usr/bin/env bash
# ============================================================================
# Build un site Lutece 7 (profil dev) et le déploie dans webapps/.
#
# Usage:
#   bin/deploy-site.sh /chemin/vers/le/site-lutece [profil-maven] [nom-webapp]
#
# Exemples:
#   bin/deploy-site.sh ~/src/gitlab/c80/site-decider
#   bin/deploy-site.sh ~/src/gitlab/c80/site-decider dev monsite
#   WEBAPP_NAME=monsite bin/deploy-site.sh ~/src/gitlab/c80/site-decider
#
# Nom de la webapp (= contexte Tomcat) : paramétrable via WEBAPP_NAME (.env ou
# variable d'environnement) ou 3e argument. Défaut : `lutece` -> contexte /lutece.
#
# Profil Maven par défaut : `dev` (datasource JNDI jdbc/CORE), requis en conteneur.
#
# Le packaging `lutece-site` ne produit pas de WAR autonome : le webapp complet
# (core + tous les jars plugins + overlay du site) est assemblé par `lutece:exploded`
# dans target/lutece. On copie ce répertoire dans webapps/<nom-webapp> ; Tomcat
# déploie un répertoire explosé comme un contexte.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBAPPS_DIR="$SCRIPT_DIR/webapps"

# Charge .env (WEBAPP_NAME, TOMCAT_HTTP_PORT, ...) s'il existe
if [[ -f "$SCRIPT_DIR/.env" ]]; then set -a; . "$SCRIPT_DIR/.env"; set +a; fi

SITE_DIR="${1:-}"
PROFILE="${2:-dev}"
# Nom de la webapp : 3e arg > WEBAPP_NAME (.env/env) > défaut `lutece`
CTX="${3:-${WEBAPP_NAME:-lutece}}"

if [[ -z "$SITE_DIR" || ! -f "$SITE_DIR/pom.xml" ]]; then
  echo "Usage: $0 /chemin/vers/le/site-lutece [profil-maven] [nom-webapp]" >&2
  echo "  (le chemin doit contenir un pom.xml ; nom-webapp par défaut: lutece)" >&2
  exit 1
fi

SITE_DIR="$(cd "$SITE_DIR" && pwd)"
echo ">> Build du site : $SITE_DIR (profil: $PROFILE, webapp: $CTX)"

# Assemblage du webapp complet dans target/lutece
( cd "$SITE_DIR" && mvn -P"$PROFILE" clean lutece:exploded )

SRC="$SITE_DIR/target/lutece"
if [[ ! -d "$SRC" ]]; then
  echo "!! Webapp explosé introuvable : $SRC" >&2
  exit 1
fi

DEST="$WEBAPPS_DIR/$CTX"
echo ">> Déploiement : $DEST"
# Le conteneur Tomcat (root) peut avoir écrit des fichiers runtime dans le webapp
# monté (embedded SOLR, opt/…) que l'utilisateur hôte ne peut pas supprimer.
# On tente un rm normal, puis on retombe sur une suppression via conteneur root.
if [ -e "$DEST" ]; then
  rm -rf "$DEST" 2>/dev/null || {
    echo ">> fichiers root-owned détectés — suppression via conteneur"
    docker run --rm -v "$WEBAPPS_DIR":/w busybox rm -rf "/w/$CTX"
  }
fi
cp -r "$SRC" "$DEST"

PORT="${TOMCAT_HTTP_PORT:-8080}"
echo ">> Déployé (contexte /$CTX)"
echo ">> Front office: http://localhost:$PORT/$CTX/jsp/site/Portal.jsp"
echo ">> Back office : http://localhost:$PORT/$CTX/jsp/admin/AdminMenu.jsp"
