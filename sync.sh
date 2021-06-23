#!/usr/bin/env sh

# If editing from Windows. Choose LF as line-ending

ROOT_DIR=${ROOT_DIR:-"$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}
MGSH_DIR=${MGSH_DIR:-"${ROOT_DIR%/}/lib/mg.sh"}

# Load dependencies from mg.sh library.
for module in locals log options controls filesystem portability text date; do
  # shellcheck disable=SC1090
  . "${MGSH_DIR%/}/${module}.sh"
done

# Set this to 1 to only show what would be done without actually copying images
# to the remote registry.
SYNC_DRYRUN=${SYNC_DRYRUN:-0}

# This is a regular expression that image names should match to be considered
# for sync. The default is an expression that matches all the names at the
# source registry!
SYNC_IMAGES=${SYNC_IMAGES:-'.*'}

# This is a regular expression that tag names should match to be considered for
# copy. The default is to match all possible tags!
SYNC_TAGS=${SYNC_TAGS:-".*"}

# A regular expression to exclude tags from the ones that would otherwise have
# been considered. The default is an empty string, meaning none of the selected
# tags will be excluded.
SYNC_EXCLUDE=${SYNC_EXCLUDE:-}

# Only images younger than this age will be considered for copy. The age is
# computed out of the creation date for the images. Human-readable strings can
# be used to express the age, e.g. 2w, 3 months, etc.
SYNC_AGE=${SYNC_AGE:-}

# Will only copy this number of latest images matching the tags. Image counting
# will happen per image, not per tag, so this might copy a whole lot less than
# what you think it would! The age needs to be an empty string for this
# parameter to be taken into account and this variable needs to be a positive
# integer.
SYNC_MAX=${SYNC_MAX:-"-1"}

# This is the path to the source registry, i.e. hub.docker.io or similar.
SYNC_SRC_REGISTRY=${SYNC_SRC_REGISTRY:-}

# This is the path to the destination registry, i.e. hub.docker.io or similar.
SYNC_DST_REGISTRY=${SYNC_DST_REGISTRY:-}

# This can contain a colon separated pair of a username and password for the
# user at the source registry. Note however that reg is able to read this
# information from your local environment. When reg is used as a docker
# container, your local environment is passed to the container so that reg can
# perform the same check.
SYNC_SRC_AUTH=${SYNC_SRC_AUTH:-}

# Same as the variable above, but for the destination registry
SYNC_DST_AUTH=${SYNC_DST_AUTH:-}

# Set these to be able to authorise at registries that rely on a separate URL
# for authentication. The Docker registry is one of those registries and
# requires auth.docker.io for authentication to work properly.
SYNC_SRC_AUTH_URL=${SYNC_SRC_AUTH_URL:-}
SYNC_DST_AUTH_URL=${SYNC_DST_AUTH_URL:-}

# Specific path to the reg utility. When empty, the binary called reg will be
# looked in the path and used if found, otherwise this script will default to
# using a Docker container when interfacing with the remote registry.
SYNC_REG_BIN=${SYNC_REG_BIN:-}

# Specific path to the jq utility. When empty, the binary called jq will be
# looked in the path and used if found, otherwise this script will default to
# using a Docker container for JSON operations (slow!).
SYNC_JQ=${SYNC_JQ:-}

# Specific opts to blindly pass to all calls to the reg utility. This can be
# used to specify some of the global flags supported by reg.
SYNC_REG_OPTS=${SYNC_REG_OPTS:-}

# Docker image to use when reg is not available at the path. Note: dev. in flux,
# pick your version carefully
SYNC_DOCKER_REG=${SYNC_DOCKER_REG:-jess/reg:v0.16.0}

# Docker image to use when jq is not available at the path.
SYNC_DOCKER_JQ=${SYNC_DOCKER_JQ:-efrecon/jq:1.6}

# When this is not empty, image will be renamed using this template at the
# destination. In the template, every token such as \1 or \2 will be replaced by
# components of the "path", i.e. in between the slashes of the source name.
SYNC_RENAME=${SYNC_RENAME:-}

# Size of the Docker image removal queue. All Docker images that should be
# remove transit through the queue to give a chance to the Docker daemon to
# cache layers and download less.
SYNC_QUEUE=${SYNC_QUEUE:-20}

parseopts \
  --main \
  --synopsis "Selectively copy Docker images from source to destination registry" \
  --usage "$MG_CMDNAME [options] (--) source destination" \
  --prefix SYNC \
  --shift _begin \
  --options \
    "n,dry-run,dryrun" FLAG DRYRUN "-" "Do not copy, just exercise" \
    "i,images" OPTION IMAGES "-" "Regular expression to point at images to copy" \
    "t,tags" OPTION TAGS "-" "Regular expression to match against source images" \
    "x,exclude" OPTION EXCLUDE "-" "Regular expression to exclude tags from the selected ones" \
    "a,age" OPTION AGE "-" "Maximal age of images to be considered for copy" \
    "m,max,maximum" OPTION MAX "-" "Maximum number of images to synchronise" \
    "queue" OPTION QUEUE "-" "Size of the Docker image removal queue" \
    "src-auth,source-auth" OPTION SRC_AUTH "-" "Colon separated username and password for access to source. Usually not needed and read from the environment instead" \
    "dst-auth,dest-auth,destination-auth" OPTION DST_AUTH "-" "Colon separated username and password for access to destination. Usually not needed and read from the environment instead" \
    "reg" OPTION REG_BIN "-" "How and where from to run reg" \
    "jq" OPTION JQ_BIN "-" "How and where from to run jq" \
    "reg-opts" OPTION REG_OPTS "-" "Options to blindly pass to reg" \
    "docker-reg" OPTION DOCKER_REG "-" "Docker image to use for reg when not present" \
    "docker-jq" OPTION DOCKER_JQ "-" "Docker image to use for jq when not present" \
    "r,rename" OPTION RENAME "-" "Rename images at destination, \1 \2 will be replaced by image path name components" \
    "h,help" FLAG @HELP "-" "Print this help and exit" \
  -- "$@"

# shellcheck disable=SC2154  # Var is set by parseopts
shift "$_begin"

if [ -d "/dev/shm" ]; then
  RM_QUEUE=$(mktemp -p "/dev/shm")
else
  RM_QUEUE=$(mktemp)
fi
dst_inventory=

trap 'cleanup; trap - EXIT; exit' EXIT INT HUP

cleanup() {
  if [ -f "$RM_QUEUE" ]; then
    # flush the Docker image removal queue and clean up the file representing the
    # queue.
    rm_queue 0
    rm -f "$RM_QUEUE"
  fi

  if [ -n "$dst_inventory" ] && [ -f "$dst_inventory" ]; then
    # Remove inventory of remote registry
    rm -f "$dst_inventory"
    dst_inventory=""
  fi
}

locate_keyword() {
  # shellcheck disable=SC2003
  expr "$(printf %s\\n "$1"|awk "END{print index(\$0,\"$2\")}"|head -n 1)" - "${#2}"
}

rm_queue() {
  log_debug "Bringing Docker image queue size from $(wc -l < "$RM_QUEUE") down to ${1:-$SYNC_QUEUE}"
  while [ "$(wc -l < "$RM_QUEUE")" -gt "${1:-$SYNC_QUEUE}" ]; do
    img=$(head -n 1 "$RM_QUEUE")
    [ -z "$img" ] && break
    docker image rm "$img" || true

    # Create a new temporary file in the same directory as $RM_QUEUE, remove the
    # first line from $RM_QUEUE into the temp, and swap files.
    tmpfname=$(mktemp -p "$(dirname "$RM_QUEUE")")
    sed '1d' "$RM_QUEUE" > "$tmpfname"
    mv "$tmpfname" "$RM_QUEUE"
  done
}

# Call reg with a command, insert various authorisation details whenever
# necessary.
reg_src() {
	cmd=$1; shift 1;

	runreg="$SYNC_REG_BIN $cmd"
	[ -n "$SYNC_SRC_AUTH_URL" ] && runreg="$runreg --auth-url $SYNC_SRC_AUTH_URL"
	if [ -n "$SRC_USERNAME" ]; then
		runreg="$runreg --username $SRC_USERNAME"
		[ -n "$SRC_PASSWORD" ] && runreg="$runreg --password $SRC_PASSWORD"
	fi
	[ -n "$SYNC_REG_OPTS" ] && runreg="$runreg $SYNC_REG_OPTS"
	$runreg "$@"
}
reg_dst() {
	cmd=$1; shift 1;

	runreg="$SYNC_REG_BIN $cmd"
	[ -n "$SYNC_DST_AUTH_URL" ] && runreg="$runreg --auth-url $SYNC_DST_AUTH_URL"
	if [ -n "$DST_USERNAME" ]; then
		runreg="$runreg --username $DST_USERNAME"
		[ -n "$DST_PASSWORD" ] && runreg="$runreg --password $DST_PASSWORD"
	fi
	[ -n "$SYNC_REG_OPTS" ] && runreg="$runreg $SYNC_REG_OPTS"
	$runreg "$@"
}

# Copy image from source registry to destination registry. The destination image
# might be renamed at the registry. Arguments are:
# $1 the name of the image (at source)
# $2 the tag of the image
# $3 how old the image is (in seconds since the epoch)
cp_image() {
  stack_let dst_name="$1"
  stack_let component

  # Arrange for dst_name to contain the new name of the image at the destination
  # registry, if relevant. This replaces all occurence of \n (where n is a
  # number) by the element in the slash separated original name.  The
  # implementation stops at 5 because of how Docker images actually are named
  # across various public registries, i.e. only gitlab has support for 3
  # elements.
  if [ -n "$SYNC_RENAME" ]; then
    dst_name=$SYNC_RENAME
    for i in $(seq 1 5); do
      component=$(printf %s\\n "$1" | cut -d "/" -f "$i")
      if [ -n "$component" ]; then
        dst_name=$(printf %s\\n "$dst_name" | sed "s/\\\\${i}/${component}/g")
      fi
    done
  fi

  if grep -q "${dst_name}:${2}" "$dst_inventory"; then
    log_notice "${dst_name}:${2} already exists at destination"
  else
    if [ "$SYNC_DRYRUN" = "1" ]; then
      if [ -z "$3" ]; then
        log_info "Would copy image $1:${2} as $(yellow "${dst_name}:${2}")"
      else
        log_info "Would copy image $1:${2} as $(yellow "${dst_name}:${2}"), $(human_period "$3") old"
      fi
    else
      if [ -z "$3" ]; then
        log_notice "Copying image $1:${2} as $(green "${dst_name}:${2}")"
      else
        log_notice "Copying image $1:${2} as $(green "${dst_name}:${2}"), $(human_period "$3") old"
      fi

      # Detect if image was present, so we can automatically remove the ones that
      # we have to pull temporarily
      present=0
      if docker image inspect "${1}:${2}" >/dev/null 2>&1; then
        present=1
      fi

      # Pull the image from the source registry, tag it with the name at the
      # destination registry. Once done, push to the destination registry and then
      # mark images for removal.
      docker image pull "${SYNC_SRC_REGISTRY%/}/${1}:${2}"
      docker image tag "${SYNC_SRC_REGISTRY%/}/${1}:${2}" "${SYNC_DST_REGISTRY%/}/${dst_name}:${2}"
      docker image push "${SYNC_DST_REGISTRY%/}/${dst_name}:${2}"

      # Enqueue images for removal
      if [ "$present" = "0" ]; then
        printf %s\\n "${SYNC_SRC_REGISTRY%/}/${1}:${2}" >> "$RM_QUEUE"
      fi
      printf %s\\n "${SYNC_DST_REGISTRY%/}/${dst_name}:${2}" >> "$RM_QUEUE"

      # Remove older entries from Docker image queue
      rm_queue
    fi
  fi

  stack_unlet dst_name component
}

# Converts the result of reg ls to lines of the form <name>:<tag> where <name>
# is the name of an image and <tag> is its tag. This function is designed to
# receive the output of reg ls as its input.
reg_ls() {
  stack_let tags_col
  stack_let name
  stack_let tag

  while IFS= read -r line; do
    if [ -z "$tags_col" ] && printf %s\\n "$line" | grep -qE "REPO\s+TAGS"; then
      tags_col=$(locate_keyword "$line" "TAGS")
    elif [ -n "$tags_col" ]; then
      name=$(printf %s\\n "$line" | cut -c 1-"$tags_col" | sed -E 's/\s+$//')
      for tag in $( printf %s\\n "$line" |
                    cut -c $((tags_col+1))- |
                    sed -E 's/^\s+//' |
                    tr ' ' '
'); do
        printf %s:%s\\n "$name" "${tag%,}"
      done
    fi
  done <<EOF
$(grep -v '^Repositories for')
EOF
  stack_unlet tags_col name tags
}

creation_date() {
  log_debug "Checking age of $1"
  # Get the sha256 of the config layer, which is a JSON file
  config=$(   reg_src manifest "$1" |
              "$SYNC_JQ" -crM .config.digest)
  if [ -z "$config" ]; then
    log_warn "Cannot find config layer for $1!"
  else
    # Extract the layer, parse its JSON and look for the image creation date, in ISO8601 format
    reg_src layer "${1}@${config}" | "$SYNC_JQ" -crM .created
  fi
}

# This is the path to the source and destination registries, i.e. hub.docker.io
# or similar.
SYNC_SRC_REGISTRY=${SYNC_SRC_REGISTRY:-${1:-}}
SYNC_DST_REGISTRY=${SYNC_DST_REGISTRY:-${2:-}}
[ -z "$SYNC_SRC_REGISTRY" ] && die "You must provide a source registry as the first argument!"
[ -z "$SYNC_DST_REGISTRY" ] && die "You must provide a registry registry as the second argument!"

# Convert period
if echo "$SYNC_AGE"|grep -Eq '[0-9]+[[:space:]]*[A-Za-z]+'; then
  NEWAGE=$(howlong "$SYNC_AGE")
  log_info "Converted human-readable age $SYNC_AGE to $NEWAGE seconds"
  SYNC_AGE=$NEWAGE
fi

# Failover to a transient Docker container whenever the reg binary is not found
# in the PATH. Note that this automatically mounts your .docker directory into
# the container so as to give a chance to the reg binary in the container to
# find your credentials. This will not work in all settings and might not be
# something that you want from a security standpoint.
if [ -z "$SYNC_REG_BIN" ]; then
	if [ -x "$(command -v reg)" ]; then
		SYNC_REG_BIN=$(command -v reg)
    log_debug "Using reg accessible as $SYNC_REG_BIN for registry operations"
	elif [ -x "$(which reg 2>/dev/null)" ]; then
		SYNC_REG_BIN=$(which reg)
    log_debug "Using reg accessible as $SYNC_REG_BIN for registry operations"
	else
		log_debug "Will run reg as a Docker container using $SYNC_DOCKER_REG"
		SYNC_REG_BIN="docker run -i --rm -v $HOME/.docker:/root/.docker:ro $SYNC_DOCKER_REG"
	fi
fi

# Failover to a transient Docker container whenever the jq binary is not found
# in the PATH.
if [ -z "$SYNC_JQ" ]; then
	if [ -x "$(command -v jq)" ]; then
		SYNC_JQ=$(command -v jq)
    log_debug "Using jq accessible as $SYNC_JQ for JSON operations"
	elif [ -x "$(which jq 2>/dev/null)" ]; then
		SYNC_JQ=$(which jq)
    log_debug "Using jq accessible as $SYNC_JQ for JSON operations"
  else
    log_debug "Will run jq as a Docker container using $SYNC_DOCKER_JQ"
    SYNC_JQ="docker run -i --rm $SYNC_DOCKER_JQ"
  fi
fi

# Initialise globals used below or in called functions
now=$(date -u +'%s');    # Will do with once and not everytime!
SRC_USERNAME=$(echo "$SYNC_SRC_AUTH" | cut -d':' -f1)
SRC_PASSWORD=$(echo "$SYNC_SRC_AUTH" | cut -d':' -f2)
DST_USERNAME=$(echo "$SYNC_DST_AUTH" | cut -d':' -f1)
DST_PASSWORD=$(echo "$SYNC_DST_AUTH" | cut -d':' -f2)

# Generate an inventory of the destination to avoid pushing existing images
# whenever possible.
log_debug "Listing all images and tags at $SYNC_DST_REGISTRY"
dst_inventory=$(mktemp)
reg_dst ls "$SYNC_DST_REGISTRY" | reg_ls > "$dst_inventory"

# Get the inventory of the source and cut so we only have image names. Then, for
# each image, request the tags (again) and reason about copying conditions. When
# copy should happen, copy after having renamed for the destination.
log_debug "Listing all images and tags at $SYNC_SRC_REGISTRY"
while IFS= read -r name; do
  if [ -n "$SYNC_IMAGES" ] && printf %s\\n "$name" | grep -Eqo "$SYNC_IMAGES"; then
    log_debug "Selecting among tags of image $name"
    # Create a temporary file to host the list of relevant images, together
    # with the creation date.
    by_dates=
    if [ -z "$SYNC_AGE" ] && [ -n "$SYNC_MAX" ] && [ "$SYNC_MAX" -gt "0" ]; then
      by_dates=$(mktemp)
    fi
    for tag in $(reg_src tags "${SYNC_SRC_REGISTRY%/}/${name}"); do
      if [ -n "$SYNC_TAGS" ] && printf %s\\n "$tag" | grep -Eqo "$SYNC_TAGS"; then
        if [ -n "$SYNC_EXCLUDE" ] && printf %s\\n "$tag" | grep -Eqo "$SYNC_EXCLUDE"; then
          log_info "Skipping $(red "${name}:${tag}"), tag excluded by $SYNC_EXCLUDE"
        else
          # When copying should happen by age, compute the age of the image and
          # copy it if relevant.
          if [ -n "$SYNC_AGE" ]; then
            creation=$(creation_date "${SYNC_SRC_REGISTRY%/}/${name}:${tag}")
            if [ -z "$creation" ]; then
              log_warn "Cannot find creation date for ${SYNC_SRC_REGISTRY%/}/${name}:${tag}!"
            else
              howold=$((now-$(iso8601 "$creation")))
              if [ "$howold" -lt "$SYNC_AGE" ]; then
                cp_image "${name}" "${tag}" "$howold"
              else
                log_info "Discarding $(red "${name}:${tag}"), $(human_period "$howold") old"
              fi
            fi
          elif [ -n "$SYNC_MAX" ] && [ "$SYNC_MAX" -gt "0" ]; then
            # When deletion should instead happen by count, push
            # the name of the image and tag, together with the
            # creation date to the temporary file created for that
            # purpose.
            creation=$(creation_date "${SYNC_SRC_REGISTRY%/}/${name}:${tag}")
            if [ -z "$creation" ]; then
              log_warn "Cannot find creation date for ${SYNC_SRC_REGISTRY%/}/${name}:${tag}!"
            else
              printf "%d\t%s\t%s\n" "$((now-$(iso8601 "$creation")))" "${name}" "${tag}" >> "$by_dates"
            fi
          else
            # When no age, nor count selection should happen, just
            # delete the image at once (scary, uh?!).
            cp_image "${name}" "${tag}"
          fi
        fi
      else
        log_info "Skipping $(red "${name}:${tag}"), tag does not match $SYNC_TAGS"
      fi
    done
    # If we have a temporary file with possible images and their creation
    # dates, sort by creation date, oldest first (this is because the date
    # is ISO8601 format), then remove all but the SYNC_MAX at the
    # tail of the file.
    if [ -n "$by_dates" ] && [ -f "$by_dates" ]; then
        sort -n -r -k 1 "$by_dates" | head -n -"$SYNC_MAX" | while IFS=$(printf \\t\\n) read -r howold nm tag; do
          cp_image "$nm" "$tag" "$howold"
        done
        rm -f "$by_dates";  # Remove the file, we are done for this image.
    fi
  else
    log_info "Skipping $(red "$name"), name does not match $SYNC_IMAGES"
  fi
done <<EOF
$(reg_src ls "$SYNC_SRC_REGISTRY" | reg_ls | cut -d':' -f1 | sort -u)
EOF

cleanup