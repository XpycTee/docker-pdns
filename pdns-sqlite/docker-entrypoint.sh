#!/bin/sh

set -eu

##### Function definitions ####

deriveSQLite3SettingsFromExistingConfigFile() {
  if [ ! -f /etc/pdns/pdns.conf ]; then
    echo "Use of existing file /etc/pdns/pdns.conf requested but file does not exist!"
    exit 1
  fi

  PDNS_gsqlite3_database=$(sed -n 's/^gsqlite3-database=\(.*\)/\1/p' < /etc/pdns/pdns.conf)
}

deriveSQLite3SettingsFromEnvironment() {
  # Configure gsqlite env vars
  : "${PDNS_gsqlite3_database:="${SQLITE_ENV_SQLITE_DATABASE:-/var/lib/powerdns/pdns.sqlite3}"}"

  # Use first part of node name as database name suffix
  if [ "${NODE_NAME:-}" ]; then
      NODE_NAME=$(echo "${NODE_NAME}" | sed -e 's/\..*//' -e 's/-//')
      PDNS_gsqlite3_database="${PDNS_gsqlite3_database}${NODE_NAME}"
  fi

  export PDNS_gsqlite3_database
}

generateSQLite3Command() {
  SQLITE_COMMAND="sqlite3"
}

createDatabaseIfRequested() {
  # Initialize DB if needed
  if [ "${SKIP_DB_CREATE:-false}" != 'true' ]; then
      $SQLITE_COMMAND "$PDNS_gsqlite3_database" "VACUUM;"
  fi
}

initDatabase() {
  if [ "${SKIP_DB_INIT:-false}" != 'true'  ]; then
    SQLITE_CHECK_IF_HAS_TABLE="SELECT COUNT(DISTINCT name) FROM sqlite_master WHERE type='table';"
    SQLITE_NUM_TABLE=$($SQLITE_COMMAND "$PDNS_gsqlite3_database" "$SQLITE_CHECK_IF_HAS_TABLE")
    if [ "$SQLITE_NUM_TABLE" -eq 0 ]; then
      echo "Database exists and has no tables yet, doing init";
      $SQLITE_COMMAND "$PDNS_gsqlite3_database" < /usr/share/doc/pdns/schema.sqlite3.sql
    else
      echo "Database exists but already has tables, will not try to init";
    fi
  fi
}

initSuperslave() {
  if [ "${PDNS_autosecondary:-no}" = 'yes' ] || [ "${PDNS_superslave:-no}" = 'yes' ]; then
      # Configure supermasters if needed
      if [ "${SUPERMASTER_IPS:-}" ]; then
          $SQLITE_COMMAND "$PDNS_gsqlite3_database" 'DELETE FROM supermasters;'
          SQLITE_INSERT_SUPERMASTERS=''
          if [ "${SUPERMASTER_COUNT:-0}" -eq 0 ]; then
              SUPERMASTER_COUNT=10
          fi
          i=1; while [ $i -le "${SUPERMASTER_COUNT}" ]; do
              SUPERMASTER_HOST=$(echo "${SUPERMASTER_HOSTS:-}" | awk -v col="$i" '{ print $col }')
              SUPERMASTER_IP=$(echo "${SUPERMASTER_IPS}" | awk -v col="$i" '{ print $col }')
              if [ -z "${SUPERMASTER_HOST:-}" ]; then
                  SUPERMASTER_HOST=$(hostname -f)
              fi
              if [ "${SUPERMASTER_IP:-}" ]; then
                  SQLITE_INSERT_SUPERMASTERS="${SQLITE_INSERT_SUPERMASTERS} INSERT INTO supermasters VALUES('${SUPERMASTER_IP}', '${SUPERMASTER_HOST}', 'admin');"
              fi
              i=$(( i + 1 ))
          done
          $SQLITE_COMMAND "$PDNS_gsqlite3_database" "$SQLITE_INSERT_SUPERMASTERS"
      fi
  fi
}

generateAndInstallConfigFileFromEnvironment() {
  # Create config file from template
  subvars --prefix 'PDNS_' < '/pdns.conf.tpl' > '/etc/pdns/pdns.conf'
}

#### End of function definitions, let's get to work ...

if [ "${USE_EXISTING_CONFIG_FILE:-false}" = 'true' ]; then
  deriveSQLite3SettingsFromExistingConfigFile
else
  deriveSQLite3SettingsFromEnvironment
fi

generateSQLite3Command

createDatabaseIfRequested
initDatabase
initSuperslave

chown -R pdns: "$PDNS_gsqlite3_database";

if [ "${USE_EXISTING_CONFIG_FILE:-false}" = 'false' ]; then
  echo "(re-)generating config file from environment variables"
  generateAndInstallConfigFileFromEnvironment
fi

exec "$@"
