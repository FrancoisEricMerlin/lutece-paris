# lutece-paris — Marketplace de plugins Claude Code

Marketplace de plugins Claude Code pour le développement Lutece à la Mairie de Paris.

## Plugins

| Plugin | Description |
|---|---|
| **lutece7-docker** | Environnement Docker de dev Lutece 7 (Tomcat 9/JDK17 + MariaDB), datasource JNDI `jdbc/CORE`, CA Mairie de Paris dans le cacerts JVM. Fournit le skill `/lutece7-docker:lutece7-docker`. |

## Installation

```bash
# Ajouter ce marketplace (chemin local, dépôt GitLab, ou URL git)
/plugin marketplace add ~/src/claude-plugins/lutece-paris

# Installer le plugin
/plugin install lutece7-docker@lutece-paris
```

Le skill devient alors disponible sous `/lutece7-docker:lutece7-docker` et Claude peut
l'invoquer automatiquement quand vous demandez un environnement de dev Lutece 7.

## Mise à jour

```bash
/plugin marketplace update lutece-paris
```

Bumpez `version` dans `plugins/lutece7-docker/.claude-plugin/plugin.json` pour publier
une nouvelle version aux utilisateurs.

## Structure

```
lutece-paris/
├── .claude-plugin/
│   └── marketplace.json           # déclare les plugins
└── plugins/
    └── lutece7-docker/
        ├── .claude-plugin/
        │   └── plugin.json         # manifest du plugin
        └── skills/
            └── lutece7-docker/
                ├── SKILL.md
                └── config/         # bundle Docker (compose, Dockerfile, certs, ...)
```
