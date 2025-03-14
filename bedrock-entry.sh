#!/bin/bash

set -eo pipefail

if [[ ${DEBUG^^} = TRUE ]]; then
  set -x
  curlArgs=(-v)
  echo "DEBUG: running as $(id -a) with $(ls -ld /data)"
fi

downloadPage=https://www.minecraft.net/en-us/download/server/bedrock/

if [[ ${EULA^^} != TRUE ]]; then
  echo
  echo "EULA must be set to TRUE to indicate agreement with the Minecraft End User License"
  echo "See https://minecraft.net/terms"
  echo
  echo "Current value is '${EULA}'"
  echo
  exit 1
fi

case ${VERSION^^} in
  1.11)
    VERSION=1.11.4.2
    ;;
  1.12)
    VERSION=1.12.0.28
    ;;
  1.13)
    VERSION=1.13.0.34
    ;;
  1.14|PREVIOUS)
    VERSION=1.14.60.5
    ;;
  1.16.1)
    VERSION=1.16.1.02
    ;;
  1.16)
    VERSION=1.16.20.03
    ;;
  LATEST)
    for a in data-bi-prtid data-platform; do
      for i in {1..3}; do
        DOWNLOAD_URL=$(restify --attribute=${a}=serverBedrockLinux ${downloadPage} 2> restify.err | jq -r '.[0].href' || echo '')
        if [[ ${DOWNLOAD_URL} ]]; then
          break 2
        fi
      done
    done
    if [[ ${DOWNLOAD_URL} =~ http.*/.*-(.*)\.zip ]]; then
      VERSION=${BASH_REMATCH[1]}
    elif [[ $(ls -rv bedrock_server-* 2> /dev/null|head -1) =~ bedrock_server-(.*) ]]; then
      VERSION=${BASH_REMATCH[1]}
      echo "WARN Minecraft download page failed, so using existing download of $VERSION"
      cat restify.err
    else
      echo "Failed to extract download URL '${DOWNLOAD_URL}' from ${downloadPage}"
      cat restify.err
      rm restify.err
      exit 2
    fi
    rm restify.err
    ;;
  *)
    # use the given version exactly
    ;;
esac

if [ ! -f "bedrock_server-${VERSION}" ]; then

  if [[ ! ${DOWNLOAD_URL} ]]; then
    DOWNLOAD_URL=https://minecraft.azureedge.net/bin-linux/bedrock-server-${VERSION}.zip
  fi

  TMP_ZIP=/tmp/$(basename "${DOWNLOAD_URL}")

  echo "Downloading Bedrock server version ${VERSION} ..."
  if ! curl "${curlArgs[@]}" -o ${TMP_ZIP} -fsSL ${DOWNLOAD_URL}; then
    echo "ERROR failed to download from ${DOWNLOAD_URL}"
    echo "      Double check that the given VERSION is valid"
    exit 2
  fi

  # remove only binaries and some docs, to allow for an upgrade of those
  rm -rf bedrock_server bedrock_server-* *.so release-notes.txt bedrock_server_how_to.html valid_known_packs.json premium_cache 2> /dev/null

  bkupDir=backup-pre-${VERSION}
  # fixup any previous interrupted upgrades
  rm -rf "${bkupDir}"
  for d in behavior_packs definitions minecraftpe resource_packs structures treatments world_templates
  do
    if [ -d $d ]; then
      mkdir -p $bkupDir
      echo "Backing up $d into $bkupDir"
      mv $d $bkupDir
    fi
  done

  # remove old package backups, but keep PACKAGE_BACKUP_KEEP
  if (( ${PACKAGE_BACKUP_KEEP:=2} >= 0 )); then
    shopt -s nullglob
    for d in $( ls -td1 backup-pre-* | tail +$(( PACKAGE_BACKUP_KEEP + 1 )) ); do
      echo "Pruning $d"
      rm -rf $d
    done
  fi

  # Do not overwrite existing files, which means the cleanup above needs to account for things
  # that MUST be replaced on upgrade
  unzip -q -n ${TMP_ZIP}
  rm ${TMP_ZIP}

  chmod +x bedrock_server
  mv bedrock_server bedrock_server-${VERSION}
fi

# Copies WORLD into world level directory
: ${LEVEL_NAME:="Bedrock level"}

worldDest=/data/worlds/$LEVEL_NAME

if [[ "$WORLD" ]] && [ ! -d "$worldDest" ]; then
  if [[ ${WORLD:0:8} == "https://" || ${WORLD:0:7} == "http://" || ${WORLD:0:6} == "ftp://" ]] ; then
    curl -fsSL "$WORLD" -o /tmp/world.zip
    zipSrc=/tmp/world.zip
  elif [[ "$WORLD" =~ .*\.zip ]]; then
    zipSrc="$WORLD"
  fi

  if [[ "$zipSrc" ]]; then
    echo "Unzipping world"

    # Stage contents so that the correct subdirectory can be picked off
    mkdir -p /tmp/world-data
    (cd /tmp/world-data && unzip -o -q "$zipSrc")

    baseDirs=$(find /tmp/world-data -name "level.dat" -exec dirname "{}" \;)

    count=$(echo "$baseDirs" | wc -l)
    if [[ $count -gt 1 ]]; then
      baseDir="$(echo "$baseDirs" | sed -n ${WORLD_INDEX:-1}p)"
      baseName=$(basename "$baseDir")
      echo "WARN multiple levels found, picking: $baseName"
    elif [[ $count -gt 0 ]]; then
      baseDir="$baseDirs"
    else
      echo "ERROR invalid world content"
      exit 1
    fi

    # Copy into selected world directory 
    mkdir -p "$worldDest"
    rsync --remove-source-files --recursive --delete "$baseDir/" "$worldDest"
  else
    echo "Cloning world directory from $WORLD ..."

    # Copy into selected world directory 
    mkdir -p "$worldDest"
    rsync --recursive --delete "${WORLD%/}"/ "$worldDest"
  fi
fi

if [ -n "$OPS" ] || [ -n "$MEMBERS" ] || [ -n "$VISITORS" ]; then
  echo "Updating permissions"
  jq -n --arg ops "$OPS" --arg members "$MEMBERS" --arg visitors "$VISITORS" '[
  [$ops      | split(",") | map({permission: "operator", xuid:.})],
  [$members  | split(",") | map({permission: "member", xuid:.})],
  [$visitors | split(",") | map({permission: "visitor", xuid:.})]
  ]| flatten' > permissions.json
fi

allowListUsers=${ALLOW_LIST_USERS:-${WHITE_LIST_USERS}}

if [ -n "$allowListUsers" ]; then
  echo "Setting allow list"
  for f in whitelist.json allowlist.json; do
    if [ -f $f ]; then
      rm -rf $f
      jq -n --arg users "$allowListUsers" '$users | split(",") | map({"name": .})' > $f
    fi
  done
  # activate server property to enable list usage
  export WHITE_LIST=true
  export ALLOW_LIST=true
fi

set-property --file server.properties --bulk /etc/bds-property-definitions.json

export LD_LIBRARY_PATH=.

: ${RCON_ENABLED:=TRUE}
: ${RCON_PASSWORD:=minecraft}
: ${RCON_PORT:=25575}

echo "Starting Bedrock server..."

if [[ ${RCON_ENABLED^^} == TRUE ]]; then
  exec mc-bedrock-runner --port=${RCON_PORT} --password=${RCON_PASSWORD} ./bedrock_server-${VERSION}
else
  exec ./bedrock_server-${VERSION}
fi
