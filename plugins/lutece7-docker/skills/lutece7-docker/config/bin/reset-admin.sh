#!/usr/bin/env bash
# ============================================================================
# Réinitialise le mot de passe d'un utilisateur admin Lutece dans core_admin_user.
#
# Lutece reconnaît le format `PLAINTEXT:<motdepasse>` : on écrit donc
# password = 'PLAINTEXT:adminadmin' (pas de hash PBKDF2 à calculer).
# Utile en local après chargement d'un dump où les mots de passe sont inconnus.
#
# Usage:
#   bin/reset-admin.sh [access_code|all] [mot_de_passe]
# Exemples:
#   bin/reset-admin.sh                 # admin -> adminadmin
#   bin/reset-admin.sh admin           # admin -> adminadmin
#   bin/reset-admin.sh all             # TOUS les comptes -> adminadmin
#   bin/reset-admin.sh admin s3cret    # admin -> s3cret
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }

DB_NAME="${DB_NAME:-lutece}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root}"

ACCESS_CODE="${1:-admin}"
PASSWORD="${2:-adminadmin}"

# Cible : un access_code précis, ou tous les comptes si "all"
if [ "$ACCESS_CODE" = "all" ]; then
  WHERE="1=1"; LABEL="TOUS les comptes admin"
else
  WHERE="access_code = '${ACCESS_CODE//\'/\'\'}'"; LABEL="access_code='$ACCESS_CODE'"
fi

echo ">> Réinitialisation ($LABEL) -> mot de passe '$PASSWORD'"

cd "$SCRIPT_DIR"
docker compose exec -T mariadb mysql -uroot -p"$DB_ROOT_PASSWORD" "$DB_NAME" <<SQL
UPDATE core_admin_user
   SET password                = CONCAT('PLAINTEXT:', '${PASSWORD//\'/\'\'}'),
       reset_password          = 0,
       password_max_valid_date = NULL,
       account_max_valid_date  = NULL
 WHERE $WHERE;
SELECT id_user, access_code, LEFT(password,25) AS pwd FROM core_admin_user WHERE $WHERE;
SQL

echo ">> Terminé. Connexion possible avec le mot de passe : $PASSWORD"
echo "   (nécessite que le back-office utilise l'auth base de données Lutece,"
echo "    pas le SSO/identity-store de la Ville)"
