#!/usr/bin/env bash
# ============================================================================
# Déploie un jar de plugin (build PR) dans le webapp déjà déployé, par simple
# remplacement, puis redémarre Tomcat. À n'utiliser QUE si la PR ne change pas
# le schéma SQL (cf. fetch-build-plugin-pr.sh). Le descripteur de plugin de la
# release reste en place -> Lutece ne déclenche aucune migration.
#
# Usage:
#   deploy-plugin-jar.sh <path-to-jar> [dest] [site-context]
#
# Exemple:
#   deploy-plugin-jar.sh ~/src/lutece-pr-tests/lutece-form-plugin-forms/target/plugin-forms-3.1.6-SNAPSHOT.jar
# ============================================================================
set -euo pipefail

JAR="${1:-}"; DEST="${2:-$HOME/src/lutece-docker-dev}"; CTX="${3:-}"
[[ -z "$JAR" || ! -f "$JAR" ]] && { echo "Usage: $0 <path-to-jar> [dest] [site-context]" >&2; exit 1; }
WEBAPPS="$DEST/webapps"
[[ -d "$WEBAPPS" ]] || { echo "!! introuvable: $WEBAPPS" >&2; exit 1; }

if [[ -z "$CTX" ]]; then
  mapfile -t sites < <(find "$WEBAPPS" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | grep -viE '^(ROOT|manager|host-manager|docs|examples)$')
  [[ "${#sites[@]}" -eq 1 ]] || { echo "!! Plusieurs webapps, précise le contexte : ${sites[*]}" >&2; exit 1; }
  CTX="${sites[0]}"
fi
LIB="$WEBAPPS/$CTX/WEB-INF/lib"
[[ -d "$LIB" ]] || { echo "!! introuvable: $LIB" >&2; exit 1; }

BASE=$(basename "$JAR")
ART=$(echo "$BASE" | sed -E 's/-[0-9].*//')   # artifactId = tout avant -<version>
echo ">> Contexte : $CTX ; remplacement de ${ART}-*.jar par $BASE"

# certains fichiers peuvent appartenir à root (créés par Tomcat) -> fallback conteneur
rm -f "$LIB/$ART"-*.jar 2>/dev/null || docker run --rm -v "$LIB":/lib alpine sh -c "rm -f /lib/${ART}-*.jar"
cp "$JAR" "$LIB/"
ls -l "$LIB/$ART"-*.jar

echo ">> Redémarrage Tomcat"
( cd "$DEST" && docker compose restart tomcat >/dev/null 2>&1 )
echo ">> Attente démarrage Lutece..."
for i in $(seq 1 40); do
  ( cd "$DEST" && docker compose logs --since 90s tomcat 2>&1 ) | grep -aq "started successfully" && break
  sleep 3
done
( cd "$DEST" && docker compose logs --since 90s tomcat 2>&1 ) | grep -a "started successfully" | tail -1 \
  || echo "(pas de 'started successfully' détecté — vérifie: docker compose logs -f tomcat)"
