#!/usr/bin/env bash
# ============================================================================
# Build un site Lutece 7 (profil dev) et le déploie dans webapps/.
#
# Usage:
#   bin/deploy-site.sh /chemin/vers/le/site-lutece [profil-maven]
#
# Exemple:
#   bin/deploy-site.sh ~/src/gitlab/c80/site-decider
#
# Profil Maven par défaut : `dev` (datasource JNDI jdbc/CORE), requis en conteneur.
#
# Le packaging `lutece-site` ne produit pas de WAR autonome : le webapp complet
# (core + tous les jars plugins + overlay du site) est assemblé par `lutece:exploded`
# dans target/lutece. On copie ce répertoire dans webapps/<artifactId-version> ;
# Tomcat déploie un répertoire explosé comme un contexte.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBAPPS_DIR="$SCRIPT_DIR/webapps"

SITE_DIR="${1:-}"
PROFILE="${2:-dev}"

if [[ -z "$SITE_DIR" || ! -f "$SITE_DIR/pom.xml" ]]; then
  echo "Usage: $0 /chemin/vers/le/site-lutece [profil-maven]" >&2
  echo "  (le chemin doit contenir un pom.xml)" >&2
  exit 1
fi

SITE_DIR="$(cd "$SITE_DIR" && pwd)"
echo ">> Build du site : $SITE_DIR (profil: $PROFILE)"

pushd "$SITE_DIR" >/dev/null

# Contexte = artifactId-version (résolu depuis le POM effectif)
ARTIFACT_ID="$(mvn -q -Dexec.executable=echo -Dexec.args='${project.artifactId}' \
  --non-recursive exec:exec 2>/dev/null | tail -1)"
VERSION="$(mvn -q -Dexec.executable=echo -Dexec.args='${project.version}' \
  --non-recursive exec:exec 2>/dev/null | tail -1)"
CTX="${ARTIFACT_ID}-${VERSION}"

# Assemblage du webapp complet dans target/lutece
mvn -P"$PROFILE" clean lutece:exploded

popd >/dev/null

SRC="$SITE_DIR/target/lutece"
if [[ ! -d "$SRC" ]]; then
  echo "!! Webapp explosé introuvable : $SRC" >&2
  exit 1
fi

DEST="$WEBAPPS_DIR/$CTX"
echo ">> Déploiement : $DEST"
rm -rf "$DEST"
cp -r "$SRC" "$DEST"

PORT="${TOMCAT_HTTP_PORT:-8080}"
echo ">> Déployé (contexte /$CTX)"
echo ">> Front office: http://localhost:$PORT/$CTX/jsp/site/Portal.jsp"
echo ">> Back office : http://localhost:$PORT/$CTX/jsp/admin/AdminMenu.jsp"
