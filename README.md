# lutece-paris — Marketplace de plugins Claude Code

Marketplace de plugins Claude Code pour le développement Lutece à la Mairie de Paris.

## Plugins

| Plugin | Description |
|---|---|
| **lutece7-docker** | Environnement Docker de dev Lutece 7 (Tomcat 9/JDK17 + MariaDB), datasource JNDI `jdbc/CORE`, CA Mairie de Paris dans le cacerts JVM. Fournit les skills `/lutece7-docker:lutece7-docker` et `/lutece7-docker:test-plugin-pr`. |
| **lutece-dump-tools** | Outils de dumps SQL Lutece. Fournit le skill `/lutece-dump-tools:anonymize-dump-emails` : anonymisation déterministe et en flux des e-mails d'un dump `mysqldump` (`.sql` / `.sql.gz`), sans casser l'échappement SQL ni les jointures. |

## Installation

```bash
# Ajouter ce marketplace (chemin local, dépôt GitLab, ou URL git)
/plugin marketplace add ~/src/claude-plugins/lutece-paris

# Installer les plugins
/plugin install lutece7-docker@lutece-paris
/plugin install lutece-dump-tools@lutece-paris
```

Les skills deviennent alors disponibles sous `/lutece7-docker:lutece7-docker` et
`/lutece-dump-tools:anonymize-dump-emails`. Claude les invoque automatiquement quand
vous demandez un environnement de dev Lutece 7 ou l'anonymisation d'un dump.

## Mise à jour

```bash
/plugin marketplace update lutece-paris
```

Bumpez `version` dans `plugins/<plugin>/.claude-plugin/plugin.json` pour publier
une nouvelle version aux utilisateurs.

## Structure

```
lutece-paris/
├── .claude-plugin/
│   └── marketplace.json           # déclare les plugins
└── plugins/
    ├── lutece7-docker/
    │   ├── .claude-plugin/
    │   │   └── plugin.json         # manifest du plugin
    │   └── skills/
    │       ├── lutece7-docker/
    │       │   ├── SKILL.md
    │       │   └── config/         # bundle Docker (compose, Dockerfile, certs, ...)
    │       └── test-plugin-pr/
    │           ├── SKILL.md
    │           └── bin/            # fetch/build PR, swap de jar, prepare-admin
    └── lutece-dump-tools/
        ├── .claude-plugin/
        │   └── plugin.json
        └── skills/
            └── anonymize-dump-emails/
                ├── SKILL.md
                └── bin/anonymize-dump-emails.py
```
