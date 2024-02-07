#!/usr/bin/env bash
#
# This script emulates an S2I (https://github.com/openshift/source-to-image)
# build process performed only via buildah.
#
# It builds a runtime image copying artifacts from a builder image.
#
# Version 0.0.3
#
# Copyright 2023, 2024 Giuseppe Magnotta giuseppe.magnotta@gmail.com
#
# Expected environment variables:
# RUNTIME_IMAGE -> The runtime image to use
# OUTPUT_IMAGE -> The image that will be built
# SRC_ARTIFACT -> The source directory that will be copied in runtime image
set -eu -o pipefail

RUNTIME_IMAGE=${RUNTIME_IMAGE:-""}
OUTPUT_IMAGE=${OUTPUT_IMAGE:-""}
TLSVERIFY=${TLSVERITY:-"true"}
BUILDAH_PARAMS=${BUILDAH_PARAMS:-""}
SRC_ARTIFACT=${SRC_ARTIFACT:-""}
RUNTIME_CMD=${RUNTIME_CMD:-""}

echo "Creting runtime image from $RUNTIME_IMAGE"

buildah $BUILDAH_PARAMS pull --tls-verify=$TLSVERIFY $RUNTIME_IMAGE

SCRIPTS_URL=$(buildah inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.scripts-url"}}' $RUNTIME_IMAGE)
IMAGE_DESTINATION_URL=$(buildah inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.destination"}}' $RUNTIME_IMAGE)
ASSEMBLE_USER=$(buildah inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.assemble-user"}}' $RUNTIME_IMAGE)

if [ -z "$SCRIPTS_URL" ] || [ -z "$IMAGE_DESTINATION_URL" ]
then
  S2I="false"
  echo "Image not compatible with S2I. Copy raw data"

  CMD="$RUNTIME_CMD"
  
else
  S2I="true"

  SCRIPTS_URL=$(echo -n "$SCRIPTS_URL" | sed 's/image:\/\///g' | tr -d '"')
  DESTINATION_URL=$(echo -n "$IMAGE_DESTINATION_URL" | tr -d '"')
  DESTINATION_URL="$DESTINATION_URL/src"
  CMD="$SCRIPTS_URL/run"

fi

if [ -z "$ASSEMBLE_USER" ]
then
  ASSEMBLE_USER=$(buildah $BUILDAH_PARAMS inspect -f '{{.OCIv1.Config.User}}' $RUNTIME_IMAGE)

  if [ -z "$ASSEMBLE_USER" ]
  then
    echo "Unable to determine the USER to build container. Terminating"
    exit -1
  fi

fi

ASSEMBLE_USER=$(echo -n "$ASSEMBLE_USER" | tr -d '"')

runner=$(buildah $BUILDAH_PARAMS from --ulimit nofile=90000:90000 --tls-verify=$TLSVERIFY $BUILDER_IMAGE)

echo "Copy from $SRC_ARTIFACT to $DESTINATION_URL"
buildah $BUILDAH_PARAMS copy --chown $ASSEMBLE_USER:0 --from $OUTPUT_IMAGE $runner $SRC_ARTIFACT $DESTINATION_URL

# Set run script as CMD
if [ ! -z "$CMD" ]
then
  echo "Setting CMD $CMD"
  buildah $BUILDAH_PARAMS config --cmd $CMD $runner
fi

if [ "$S2I" = "true" ]
then
  # Run assemble script.
  ASSEMBLE_SCRIPT="$SCRIPTS_URL/assemble"

  eval buildah $BUILDAH_PARAMS run $runner -- $ASSEMBLE_SCRIPT
fi

echo "Committing image"
buildah $BUILDAH_PARAMS commit $runner $OUTPUT_IMAGE

echo "Deleting temporary images"
buildah $BUILDAH_PARAMS rm $runner
