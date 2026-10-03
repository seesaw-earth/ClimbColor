#!/bin/bash
set -euo pipefail

MODEL="${PROJECT_DIR:-$(pwd)}/ClimbColor/Models/ClimbHoldSeg.mlpackage"

if [ ! -d "$MODEL" ]; then
  echo "error: ClimbColor Core ML model is missing:"
  echo "error:   $MODEL"
  echo "error: This repository uses Git LFS."
  echo "error: Run 'git lfs pull' and build again."
  exit 1
fi

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
  echo "Model found: $MODEL"
  echo "This script is normally run by Xcode."
  exit 0
fi

DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
TMP_COMPILE="$DERIVED_FILE_DIR/ClimbColorCoreML"

mkdir -p "$DEST"
rm -rf "$TMP_COMPILE"
mkdir -p "$TMP_COMPILE"
rm -rf "$DEST/ClimbHoldSeg.mlmodelc"

/usr/bin/xcrun coremlcompiler compile "$MODEL" "$TMP_COMPILE"

COMPILED="$(find "$TMP_COMPILE" -maxdepth 1 -type d -name '*.mlmodelc' -print -quit)"

if [ -z "$COMPILED" ] || [ ! -d "$COMPILED" ]; then
  echo "error: coremlcompiler did not produce an .mlmodelc directory."
  exit 1
fi

cp -R "$COMPILED" "$DEST/ClimbHoldSeg.mlmodelc"

echo "ClimbColor: bundled Core ML model from:"
echo "  $MODEL"
echo "into:"
echo "  $DEST/ClimbHoldSeg.mlmodelc"
