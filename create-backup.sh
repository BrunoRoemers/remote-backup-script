#!/usr/bin/env bash

set -eo pipefail

#########
# UTILS #
#########

die() {
  echo "$1"
  exit 1
}


############
# SETTINGS #
############

BOLD=$(tput bold)
RESET=$(tput sgr0)

# current timestamp, used to name the files of the backup
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"

# path to config folder (user will be requested to select one of the env files in this folder)
CONFIGS_FOLDER_PATH="./configs"


#################
# SELECT CONFIG #
#################

# prompt user to select one of the env files
SELECTED_CONFIG_FILE_PATH="$(find "$CONFIGS_FOLDER_PATH"/*.env -exec basename {} \; | grep -v __template__.env | fzf)"

# load the selected env file
# shellcheck disable=SC1090
source "./$CONFIGS_FOLDER_PATH/$SELECTED_CONFIG_FILE_PATH"


################################
# ASSERT REQUIRED ENV VARS SET #
################################

REQUIRED_ENV_VARS=('BASE_LABEL' 'REMOTE_USER' 'REMOTE_SERVER' 'REMOTE_ARCHIVE_PATH' 'LOCAL_ARCHIVE_PATH' 'SHOULD_BACKUP_FOLDER' 'REMOTE_TARGET_PATH' 'SHOULD_BACKUP_DATABASE' 'SHOULD_DETECT_DATABASE_CREDENTIALS')
if [[ "$SHOULD_DETECT_DATABASE_CREDENTIALS" -ne 1 ]]; then
  REQUIRED_ENV_VARS+=('DB_HOST' 'DB_USER' 'DB_PASSWORD' 'DB_NAME')
fi

for ENV_VAR_NAME in "${REQUIRED_ENV_VARS[@]}"; do
  [[ -n "${!ENV_VAR_NAME}" ]] || die "error: $ENV_VAR_NAME is not set"
  echo "info: $ENV_VAR_NAME=${!ENV_VAR_NAME}"
done

######################
# ASSERT NOT A NO-OP #
######################

[[ "$SHOULD_BACKUP_FOLDER" -eq 1 || "$SHOULD_BACKUP_DATABASE" -eq 1 ]] || die "error: this config is a no-op"


#############################
# PROMPT FOR EXTENDED LABEL #
#############################

echo ""
echo "enter extended label:"
read -r EXTENDED_LABEL

# replace anything that's not a letter or a number with a dash, and capitalize all letters
EXTENDED_LABEL="$(echo "$EXTENDED_LABEL" | sed -E 's/[^[:alnum:]]/-/g' | tr '[:lower:]' '[:upper:]')"


########################
# CONSTRUCT FILE NAMES #
########################

# NOTE: omit file extensions
CODE_BACKUP_FILE_NAME="backup-$BASE_LABEL-$EXTENDED_LABEL-$TIMESTAMP" #.tgz
DB_BACKUP_FILE_NAME="backup-$BASE_LABEL-$EXTENDED_LABEL-$TIMESTAMP" #.sql


################
# PRINT CONFIG #
################

echo ""
echo "the following actions will be taken:"
echo -e "- establish an ssh connection to ${BOLD}$REMOTE_USER${RESET} @ ${BOLD}$REMOTE_SERVER${RESET}"
if [[ "$SHOULD_BACKUP_FOLDER" -eq 1 ]]; then
  echo -e "  - backup the folder: ${BOLD}$REMOTE_TARGET_PATH${RESET}"
fi
if [[ "$SHOULD_BACKUP_DATABASE" -eq 1 ]]; then
  if [[ "$SHOULD_DETECT_DATABASE_CREDENTIALS" -eq 1 ]]; then
    echo -e "  - backup the database: ${BOLD}<detect credentials on server>${RESET}"
  else
    echo -e "  - backup the database: ${BOLD}$DB_USER${RESET} @ ${BOLD}$DB_HOST${RESET} / ${BOLD}$DB_NAME${RESET}"
  fi
fi
echo -e "  - temporary file(s) will be created here: ${BOLD}$REMOTE_ARCHIVE_PATH${RESET}"
echo -e "- download the backups to: ${BOLD}$LOCAL_ARCHIVE_PATH${RESET}"
if [[ "$SHOULD_BACKUP_FOLDER" -eq 1 ]]; then
  echo -e "  - name of the code backup: ${BOLD}$CODE_BACKUP_FILE_NAME.tgz${RESET}"
fi
if [[ "$SHOULD_BACKUP_DATABASE" -eq 1 ]]; then
  echo -e "  - name of the database backup: ${BOLD}$DB_BACKUP_FILE_NAME.sql${RESET}"
fi


##################
# CONFIRM CONFIG #
##################

echo "Type 'y' to continue. Type 'n' to abort."
while true; do
  # wait on user reply...
  read -r _CONTINUE

  # y - escape while loop
  if [[ $_CONTINUE = 'y' ]]; then
    break
  fi

  # n - stop the script
  if [[ $_CONTINUE = 'n' ]]; then
    echo "aborting..."
    exit 1
  fi

  # wait on user again...
  echo "'$_CONTINUE' is not a valid response. Please enter 'y' or 'n'..."
done


###############################
# CREATE LOCAL ARCHIVE FOLDER #
###############################

mkdir -p "$LOCAL_ARCHIVE_PATH"


if [[ "$SHOULD_BACKUP_FOLDER" -eq 1 ]]; then

  ##############################
  # CREATE ARCHIVE FROM FOLDER #
  ##############################

  # NOTE: this requires a valid ssh key or will prompt for password
  # shellcheck disable=SC2029
  ssh "$REMOTE_USER@$REMOTE_SERVER" "mkdir -p '$REMOTE_ARCHIVE_PATH/__rsync' && cd '$REMOTE_ARCHIVE_PATH' && rsync -av --delete '$REMOTE_TARGET_PATH/' '$REMOTE_ARCHIVE_PATH/__rsync/' && tar -czf $CODE_BACKUP_FILE_NAME.tgz --exclude='*.zip' --dereference --directory '$REMOTE_ARCHIVE_PATH/__rsync' ."

  ####################
  # DOWNLOAD ARCHIVE #
  ####################

  scp "$REMOTE_USER@$REMOTE_SERVER":"$REMOTE_ARCHIVE_PATH/$CODE_BACKUP_FILE_NAME.tgz" "$LOCAL_ARCHIVE_PATH"
  
fi

if [[ "$SHOULD_BACKUP_DATABASE" -eq 1 ]]; then

  _DB_BACKUP_CMD="mkdir -p '$REMOTE_ARCHIVE_PATH' && cd '$REMOTE_ARCHIVE_PATH' && mysqldump --host=\"\$DB_HOST\" --user=\"\$DB_USER\" --password=\"\$DB_PASSWORD\" \"\$DB_NAME\" > $DB_BACKUP_FILE_NAME.sql"

  if [[ "$SHOULD_DETECT_DATABASE_CREDENTIALS" -eq 1 ]]; then
  
    ####################################################
    # CREATE ARCHIVE FROM DATABASE (INFER CREDENTIALS) #
    ####################################################

# shellcheck disable=SC2087
ssh "$REMOTE_USER@$REMOTE_SERVER" <<EOF
DB_HOST=
DB_USER=
DB_PASSWORD=
DB_NAME=

if [[ -f "$REMOTE_TARGET_PATH/configuration.php" ]]; then
  echo "Found file '$REMOTE_TARGET_PATH/configuration.php'. Assuming Joomla install..."

  DB_HOST="\$(cat '$REMOTE_TARGET_PATH/configuration.php' | grep 'public \$host =' | cut -s -d "'" -f 2)"
  DB_USER="\$(cat '$REMOTE_TARGET_PATH/configuration.php' | grep 'public \$user =' | cut -s -d "'" -f 2)"
  DB_PASSWORD="\$(cat '$REMOTE_TARGET_PATH/configuration.php' | grep 'public \$password =' | cut -s -d "'" -f 2)"
  DB_NAME="\$(cat '$REMOTE_TARGET_PATH/configuration.php' | grep 'public \$db =' | cut -s -d "'" -f 2)"
elif [[ -f "$REMOTE_TARGET_PATH/.env" ]]; then
  echo "Found file '$REMOTE_TARGET_PATH/.env'. Assuming Wordpress install..."

  DB_HOST="\$(cat '$REMOTE_TARGET_PATH/.env' | grep 'WORDPRESS_DB_HOST=' | cut -s -d "=" -f 2)"
  DB_USER="\$(cat '$REMOTE_TARGET_PATH/.env' | grep 'WORDPRESS_DB_USER=' | cut -s -d "=" -f 2)"
  DB_PASSWORD="\$(cat '$REMOTE_TARGET_PATH/.env' | grep 'WORDPRESS_DB_PASSWORD=' | cut -s -d "=" -f 2)"
  DB_NAME="\$(cat '$REMOTE_TARGET_PATH/.env' | grep 'WORDPRESS_DB_NAME=' | cut -s -d "=" -f 2)"
elif [[ -f "$REMOTE_TARGET_PATH/wp-config.php" ]]; then
  echo "Found file '$REMOTE_TARGET_PATH/wp-config.php'. Assuming Wordpress install..."
  
  DB_HOST="\$(cat '$REMOTE_TARGET_PATH/wp-config.php' | grep "define('DB_HOST'," | cut -s -d "'" -f 4)"
  DB_USER="\$(cat '$REMOTE_TARGET_PATH/wp-config.php' | grep "define('DB_USER'," | cut -s -d "'" -f 4)"
  DB_PASSWORD="\$(cat '$REMOTE_TARGET_PATH/wp-config.php' | grep "define('DB_PASSWORD'," | cut -s -d "'" -f 4)"
  DB_NAME="\$(cat '$REMOTE_TARGET_PATH/wp-config.php' | grep "define('DB_NAME'," | cut -s -d "'" -f 4)"
fi

if [[ -z "\$DB_HOST" || -z "\$DB_USER" || -z "\$DB_PASSWORD" || -z "\$DB_NAME" ]]; then
  echo "Error: could not detect database credentials. Aborting without database backup..."
  exit 1
fi

$_DB_BACKUP_CMD
EOF

  else

    #######################################################
    # CREATE ARCHIVE FROM DATABASE (EXPLICIT CREDENTIALS) #
    #######################################################

# shellcheck disable=SC2087
ssh "$REMOTE_USER@$REMOTE_SERVER" <<EOF
DB_HOST="$DB_HOST"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"
DB_NAME="$DB_NAME"

$_DB_BACKUP_CMD
EOF

  fi

  
  ####################
  # DOWNLOAD ARCHIVE #
  ####################

  scp "$REMOTE_USER@$REMOTE_SERVER":"$REMOTE_ARCHIVE_PATH/$DB_BACKUP_FILE_NAME.sql" "$LOCAL_ARCHIVE_PATH"

fi