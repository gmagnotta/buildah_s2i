#!/usr/bin/env bash
#
# This script emulates an S2I (https://github.com/openshift/source-to-image)
# build process performed via buildah.
#
# It is able to perform incremental builds and use builder and runtime images.
#
# Version 0.0.6
#
# Copyright 2023 Giuseppe Magnotta giuseppe.magnotta@gmail.com
#
# Expected environment variables:
# BUILDER_IMAGE -> The builder image to use
# OUTPUT_IMAGE -> The image that will be build
# INCREMENTAL -> If incremental build should be used
# RUNTIME_IMAGE -> The runtime image to use
# RUNTIME_CMD -> The CMD that will override the one in RUNTIME_IMAGE
set -e

BUILDER_IMAGE=${BUILDER_IMAGE:-""}
OUTPUT_IMAGE=${OUTPUT_IMAGE:-""}
INCREMENTAL=${INCREMENTAL:-false}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-""}
RUNTIME_CMD=${RUNTIME_CMD:-""}
CONTEXT_DIR=${CONTEXT_DIR:-"."}

echo "Start build process with builder image $BUILDER_IMAGE"

SCRIPTS_URL=$(buildah inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.scripts-url"}}' $BUILDER_IMAGE)
DESTINATION_URL=$(buildah inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.destination"}}' $BUILDER_IMAGE)
ASSEMBLE_USER=$(buildah inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.assemble-user"}}' $BUILDER_IMAGE)

if [ -z "$SCRIPTS_URL" ] || [ -z "$DESTINATION_URL" ]
then
  echo "Image not compatible with S2I. Terminating"
  exit -1
else
  SCRIPTS_URL=$(echo -n "$SCRIPTS_URL" | sed 's/image:\/\///g' | tr -d '"')
  DESTINATION_URL=$(echo -n "$DESTINATION_URL" | tr -d '"')

  if [ -z "$ASSEMBLE_USER" ]
  then
    ASSEMBLE_USER=$(buildah inspect -f '{{.OCIv1.Config.User}}' $BUILDER_IMAGE)
  fi

  ASSEMBLE_USER=$(echo -n "$ASSEMBLE_USER" | tr -d '"')

fi

builder=$(buildah from --ulimit nofile=90000:90000 $BUILDER_IMAGE)

echo "Copy from ./$CONTEXT_DIR to $DESTINATION_URL/src"
buildah add --chown $ASSEMBLE_USER:0 $builder ./$CONTEXT_DIR $DESTINATION_URL/src

# If incremental build is enabled and there is an artifacts.tar file, then
# copy it to the builder image
if [ "$INCREMENTAL" = "true" ]; then

    if [ -f "./artifacts.tar" ]; then
        echo "Restoring artifacts for incremental build"
        buildah add --chown $ASSEMBLE_USER:0 $builder ./artifacts.tar $DESTINATION_URL/artifacts
    fi

fi

# Construct enviroment variables to be used during the assemble script
ENV=""
if [ -f "$CONTEXT_DIR/.s2i/environment" ]; then

    while IFS="" read -r line
    do
      [[ "$line" =~ ^#.*$ ]] && continue
      ENV+="-e $line "
    done < $CONTEXT_DIR/.s2i/environment

    if ! [ -z "$ENV" ]
    then
      echo "ENV is $ENV"
    fi
fi

# Set run script as CMD
buildah config --cmd $SCRIPTS_URL/run $builder

# Run assemble script. If there is an assemble script in .s2i/bin directory
# it takes precedence
ASSEMBLE_SCRIPT="$SCRIPTS_URL/assemble"

if [ -x "$CONTEXT_DIR/.s2i/bin/assemble" ]; then

    echo "Replacing assemble file from .s2i/bin"
    ASSEMBLE_SCRIPT="$DESTINATION_URL/src/.s2i/bin/assemble"
fi

eval buildah run $ENV $builder -- $ASSEMBLE_SCRIPT

# If incremental build is enabled, and image provide save-artifacts script,
# then call it and backup artifacts
if [ "$INCREMENTAL" = "true" ]; then

    echo "Saving artifacts"
    if [ -f "./artifacts.tar" ]; then
        rm ./artifacts.tar
    fi

    buildah run $builder -- /bin/bash -c "if [ -x \"$SCRIPTS_URL/save-artifacts\" ]; then $SCRIPTS_URL/save-artifacts ; fi" > ./artifacts.tar

fi

# RUNTIME IMAGE BUILD
if [ ! -z "$RUNTIME_IMAGE" ]; then

    if [ -z "$RUNTIME_ARTIFACT" ] || [ -z "$RUNTIME_DEST_ARTIFACT" ]; then

      echo "Can't create runtime image. Missing requirements"
      exit -1

    fi

    echo "Creating Runtime Image"

    runner=$(buildah from $RUNTIME_IMAGE)

    buildah copy --chown $ASSEMBLE_USER:0 --from $builder $runner $RUNTIME_ARTIFACT $RUNTIME_DEST_ARTIFACT

    if [ ! -z "$RUNTIME_CMD" ]; then
      buildah config --cmd $RUNTIME_CMD $runner
    fi

    buildah commit $runner $OUTPUT_IMAGE

    buildah rm $runner

else

    buildah commit $builder $OUTPUT_IMAGE

fi

buildah rm $builder
