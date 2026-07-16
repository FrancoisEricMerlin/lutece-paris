#!/usr/bin/env bash
# ============================================================================
# Récupère une PR GitHub d'un plugin Lutece, la build, et signale l'impact SQL.
#
# Usage:
#   fetch-build-plugin-pr.sh <artifactId|git-url> <pr-number> [workdir]
#
# Exemples:
#   fetch-build-plugin-pr.sh plugin-forms 635
#   fetch-build-plugin-pr.sh https://github.com/lutece-platform/lutece-form-plugin-forms.git 635
#
# - Si le 1er argument est un artifactId, l'URL du dépôt est résolue depuis le
#   <scm> du POM présent dans ~/.m2 (le plugin doit déjà avoir été résolu une fois).
# - La PR est récupérée sans authentification via `git fetch origin pull/<N>/head`.
# - Un diff SQL vs le dernier tag de release indique si un simple swap de jar
#   suffit (aucun changement de schéma) ou s'il faut un rebuild complet du site.
# ============================================================================
set -euo pipefail

ART="${1:-}"; PR="${2:-}"; WORKDIR="${3:-$HOME/src/lutece-pr-tests}"
if [[ -z "$ART" || -z "$PR" ]]; then
  echo "Usage: $0 <artifactId|git-url> <pr-number> [workdir]" >&2; exit 1
fi

# --- Résolution de l'URL du dépôt --------------------------------------------
if [[ "$ART" == http*://* || "$ART" == *.git ]]; then
  REPO_URL="$ART"
else
  POM=$(ls -t "$HOME"/.m2/repository/fr/paris/lutece/plugins/"$ART"/*/"$ART"-*.pom 2>/dev/null \
        | grep -viE 'sources|javadoc' | head -1 || true)
  [[ -z "$POM" ]] && { echo "!! POM introuvable pour '$ART' dans ~/.m2. Passe l'URL git en 1er argument." >&2; exit 1; }
  SCM=$(grep -m1 -oE 'github\.com/[A-Za-z0-9_./-]+' "$POM" | head -1 || true)
  [[ -z "$SCM" ]] && { echo "!! <scm> github introuvable dans $POM" >&2; exit 1; }
  REPO_URL="https://${SCM%.git}.git"
fi
NAME=$(basename "$REPO_URL" .git)
echo ">> Dépôt : $REPO_URL  (PR #$PR)"

# --- Clone + fetch PR --------------------------------------------------------
mkdir -p "$WORKDIR"; cd "$WORKDIR"
[[ -d "$NAME/.git" ]] || git clone -q "$REPO_URL" "$NAME"
cd "$NAME"
git fetch -q origin "pull/$PR/head:pr-$PR" -f
git checkout -q "pr-$PR"
echo ">> Derniers commits :"; git log --oneline -5

# --- Impact schéma (SQL) vs dernier tag de release ---------------------------
BASE=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [[ -n "$BASE" ]]; then
  SQLDIFF=$(git diff --name-only "$BASE"..HEAD -- '*.sql' 2>/dev/null || true)
  if [[ -n "$SQLDIFF" ]]; then
    echo "!! ATTENTION : la PR modifie du SQL vs $BASE — le swap de jar NE SUFFIT PAS."
    echo "   Fais un rebuild complet du site + base vide (Liquibase). Fichiers :"
    echo "$SQLDIFF" | sed 's/^/     /'
  else
    echo ">> Aucun changement SQL vs $BASE → le swap de jar est sûr (deploy-plugin-jar.sh)."
  fi
fi

# --- Build (sans tests, JDK/toolchain de l'hôte) -----------------------------
echo ">> Build (mvn clean install -Dmaven.test.skip=true)..."
mvn -q clean install -Dmaven.test.skip=true
JAR=$(ls -t target/*.jar 2>/dev/null | grep -viE 'sources|javadoc|tests' | head -1 || true)
[[ -z "$JAR" ]] && { echo "!! jar introuvable dans target/" >&2; exit 1; }
echo ">> JAR PR : $(pwd)/$JAR"
