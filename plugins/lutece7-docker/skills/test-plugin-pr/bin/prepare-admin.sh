#!/usr/bin/env bash
# ============================================================================
# Prépare l'accès back-office sur une base fraîche (initialisée par Liquibase) :
#   1. (Ré)initialise le mot de passe de l'utilisateur `admin` à une valeur connue
#      en injectant un hash au format Lutece (PBKDF2WITHHMACSHA512:210000:salt:hash).
#   2. Accorde TOUS les droits (core_admin_right) à l'utilisateur admin (id 1) :
#      sur une base neuve, les droits des plugins (FORMS_*, etc.) ne lui sont pas
#      assignés automatiquement -> "Accès refusé" sinon.
#
# Usage:
#   prepare-admin.sh [password] [db-container] [db-name] [db-user] [db-pass]
#
# Défauts : adminadmin  lutece7-mariadb  lutece  lutece  lutece
# ============================================================================
set -euo pipefail

PW="${1:-adminadmin}"; DB="${2:-lutece7-mariadb}"; DBNAME="${3:-lutece}"; DBUSER="${4:-lutece}"; DBPASS="${5:-lutece}"

HASH=$(python3 - "$PW" <<'PY'
import hashlib, os, sys
pw = sys.argv[1].encode()
salt = os.urandom(16)
h = hashlib.pbkdf2_hmac('sha512', pw, salt, 210000, dklen=128).hex()
print(f"PBKDF2WITHHMACSHA512:210000:{salt.hex()}:{h}")
PY
)

docker exec "$DB" mysql -u"$DBUSER" -p"$DBPASS" "$DBNAME" -e \
"UPDATE core_admin_user SET password='$HASH', reset_password=0 WHERE access_code='admin';
 INSERT IGNORE INTO core_user_right (id_right,id_user)
   SELECT id_right,1 FROM core_admin_right
   WHERE id_right NOT IN (SELECT id_right FROM core_user_right WHERE id_user=1);
 SELECT COUNT(*) AS droits_admin FROM core_user_right WHERE id_user=1;"

echo ">> Connexion back-office : admin / $PW  (tous droits accordés)"
