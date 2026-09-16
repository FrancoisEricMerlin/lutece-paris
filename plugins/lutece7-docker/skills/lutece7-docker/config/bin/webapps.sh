#!/usr/bin/env bash
# ============================================================================
# Liste les webapps déployés dans webapps/ (chaque répertoire = un contexte
# Tomcat, démarré à chaque (re)démarrage du conteneur) et permet d'en supprimer.
#
# Usage:
#   bin/webapps.sh                          # liste : contexte, taille, date, base, état HTTP
#   bin/webapps.sh --remove <contexte>      # supprime webapps/<contexte> (confirmation demandée)
#   bin/webapps.sh --remove <contexte> --drop-db   # ... et supprime aussi SA base dédiée
#   bin/webapps.sh --remove <contexte> -y   # sans confirmation (usage interactif humain)
#
# Tomcat dédéploie de lui-même un contexte dont le répertoire disparaît
# (autoDeploy) : aucun redémarrage n'est nécessaire après une suppression.
#
# Base : lue dans META-INF/context.xml du webapp (datasource dédiée), sinon
# la base partagée ${DB_NAME} du context.xml global (jdbc/CORE). --drop-db ne
# supprime JAMAIS la base partagée ${DB_NAME}, seulement une base dédiée.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBAPPS_DIR="$SCRIPT_DIR/webapps"
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && . "$SCRIPT_DIR/.env" && set +a
PORT="${TOMCAT_HTTP_PORT:-8080}"
SHARED_DB="${DB_NAME:-lutece}"
MARIADB_CONTAINER="${MARIADB_CONTAINER:-lutece7-mariadb}"

# Base ciblée par un webapp : datasource dédiée (META-INF/context.xml) sinon la base partagée
webapp_db() {
  local ctx="$1" url
  url="$(grep -o 'url="[^"]*"' "$WEBAPPS_DIR/$ctx/META-INF/context.xml" 2>/dev/null | head -1 || true)"
  if [[ -n "$url" ]]; then
    # jdbc:mysql://hote:port/base?params -> base (les params peuvent contenir des "/", ex. serverTimezone=Europe/Paris)
    sed -E 's|^url="||; s|["?].*$||; s|.*/||' <<<"$url"
  else
    echo "$SHARED_DB"
  fi
}

# État HTTP du contexte : 200/302 = démarré, 404 = non déployé, 000 = Tomcat injoignable
webapp_http() {
  curl -s -o /dev/null --max-time 8 -w '%{http_code}' "http://localhost:$PORT/$1/jsp/site/Portal.jsp" || echo 000
}

list_webapps() {
  local ctx size date db code state lq n=0
  printf '%-40s %7s  %-11s  %-32s  %-9s  %s\n' CONTEXTE TAILLE MODIFIE BASE HTTP LIQUIBASE
  for dir in "$WEBAPPS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    ctx="$(basename "$dir")"; n=$((n+1))
    # du peut rendre 1 sur un sous-répertoire illisible : ne pas laisser set -e interrompre la liste
    size="$(du -sh "$dir" 2>/dev/null | cut -f1 || true)"
    date="$(date -r "$dir" '+%d/%m %H:%M' 2>/dev/null || echo '?')"
    db="$(webapp_db "$ctx")"; [[ "$db" == "$SHARED_DB" ]] && db="$db (partagée)"
    code="$(webapp_http "$ctx")"
    case "$code" in 200|302) state="démarré";; 404) state="absent";; 000) state="tomcat ?";; *) state="HTTP $code";; esac
    lq="$(grep -E '^liquibase.enabled.at.startup=' "$dir/WEB-INF/conf/plugins/liquibase-plugin.properties" 2>/dev/null | cut -d= -f2 || true)"
    printf '%-40s %7s  %-11s  %-32s  %-9s  %s\n' "$ctx" "$size" "$date" "$db" "$state" "${lq:--}"
  done
  echo
  echo "$n webapp(s) dans $WEBAPPS_DIR — chacun est redéployé à chaque redémarrage du conteneur."
  echo "Supprimer : bin/webapps.sh --remove <contexte> [--drop-db]"
}

remove_webapp() {
  local ctx="$1" drop_db="$2" yes="$3" db
  if [[ ! -d "$WEBAPPS_DIR/$ctx" ]]; then
    echo "!! Contexte inconnu : $ctx" >&2; echo "   Contextes : $(ls "$WEBAPPS_DIR")" >&2; exit 1
  fi
  db="$(webapp_db "$ctx")"
  echo ">> Suppression de webapps/$ctx ($(du -sh "$WEBAPPS_DIR/$ctx" 2>/dev/null | cut -f1 || true)), base associée : $db"
  if [[ "$drop_db" == 1 ]]; then
    if [[ "$db" == "$SHARED_DB" ]]; then
      echo "!! La base $db est la base partagée du conteneur : elle ne sera PAS supprimée (--drop-db ignoré)."
      drop_db=0
    else
      echo ">> La base dédiée $db sera supprimée sur $MARIADB_CONTAINER."
    fi
  fi
  if [[ "$yes" != 1 ]]; then
    read -r -p "Confirmer ? [o/N] " answer
    [[ "$answer" =~ ^[oOyY]$ ]] || { echo "Annulé."; exit 0; }
  fi
  rm -rf "$WEBAPPS_DIR/$ctx"
  echo ">> webapps/$ctx supprimé ; Tomcat dédéploie le contexte /$ctx de lui-même."
  if [[ "$drop_db" == 1 ]]; then
    docker exec "$MARIADB_CONTAINER" sh -c 'mysql -uroot -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`'"$db"'\`"'
    echo ">> Base $db supprimée."
  fi
}

ctx=""; drop_db=0; yes=0; mode=list
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) mode=remove; ctx="${2:-}"; shift 2;;
    --drop-db) drop_db=1; shift;;
    -y|--yes) yes=1; shift;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Option inconnue : $1" >&2; exit 1;;
  esac
done

if [[ "$mode" == remove ]]; then
  [[ -n "$ctx" ]] || { echo "Usage: $0 --remove <contexte> [--drop-db] [-y]" >&2; exit 1; }
  remove_webapp "$ctx" "$drop_db" "$yes"
else
  list_webapps
fi
