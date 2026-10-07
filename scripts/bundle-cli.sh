#!/bin/sh
set -eu
configuration=debug
if [ "${CONFIGURATION:-Debug}" = Release ]; then configuration=release; fi
cd "$PROJECT_DIR"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin"
/bin/sh scripts/build-cli.sh "$destination" "$configuration"
/bin/sh scripts/bundle-simulator-notices.sh "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ThirdPartyNotices"
