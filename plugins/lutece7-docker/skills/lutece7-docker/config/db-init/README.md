# Initialisation de la base

Déposez ici votre dump pour qu'il soit chargé **au premier démarrage** de MariaDB :

- `*.sql`, `*.sql.gz` ou `*.sh` sont exécutés par ordre alphabétique.
- Si ce dossier ne contient aucun dump, MariaDB crée simplement une base vide
  nommée `${DB_NAME}` (voir `.env`).

## Points importants

- Les scripts d'init ne s'exécutent **qu'une seule fois**, quand le volume de
  données est vierge. Pour rejouer un dump, réinitialisez le volume :

  ```bash
  docker compose down -v && docker compose up -d
  ```

- Si votre dump crée/sélectionne une base précise (`CREATE DATABASE xxx; USE xxx;`),
  alignez `DB_NAME` dans `.env` sur ce nom pour que la datasource JNDI pointe dessus.

- Préfixez pour ordonner : `01-schema.sql`, `02-data.sql`, ...
