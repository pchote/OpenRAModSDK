#!/bin/bash
# OpenRA Mod SDK packaging script for macOS
#
# The application bundles will be signed if the following environment variable is defined:
#   MACOS_DEVELOPER_IDENTITY: Certificate name, of the form `Developer\ ID\ Application:\ <name with escaped spaces>`
# If the identity is not already in the default keychain, specify the following environment variables to import it:
#   MACOS_DEVELOPER_CERTIFICATE_BASE64: base64 content of the exported .p12 developer ID certificate.
#                                       Generate using `base64 certificate.p12 | pbcopy`
#   MACOS_DEVELOPER_CERTIFICATE_PASSWORD: password to unlock the MACOS_DEVELOPER_CERTIFICATE_BASE64 certificate
#
# The applicaton bundles will be notarized if the following environment variables are defined:
#   MACOS_DEVELOPER_USERNAME: Email address for the developer account
#   MACOS_DEVELOPER_PASSWORD: App-specific password for the developer account
#
set -e

if [[ "$OSTYPE" != "darwin"* ]]; then
	echo >&2 "macOS packaging requires a macOS host"
	exit 1
fi

command -v make >/dev/null 2>&1 || { echo >&2 "The OpenRA mod SDK macOS packaging requires make."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo >&2 "The OpenRA mod SDK macOS packaging requires python 3."; exit 1; }

require_variables() {
	missing=""
	for i in "$@"; do
		eval check="\$$i"
		[ -z "${check}" ] && missing="${missing}   ${i}\n"
	done
	if [ ! -z "${missing}" ]; then
		printf "Required mod.config variables are missing:\n${missing}Repair your mod.config (or user.config) and try again.\n"
		exit 1
	fi
}

if [ $# -eq "0" ]; then
	echo "Usage: `basename $0` version [outputdir]"
	exit 1
fi

PACKAGING_DIR=$(python3 -c "import os; print(os.path.dirname(os.path.realpath('$0')))")
TEMPLATE_ROOT="${PACKAGING_DIR}/../../"
ARTWORK_DIR="${PACKAGING_DIR}/../artwork/"

# shellcheck source=mod.config
. "${TEMPLATE_ROOT}/mod.config"

if [ -f "${TEMPLATE_ROOT}/user.config" ]; then
	# shellcheck source=user.config
	. "${TEMPLATE_ROOT}/user.config"
fi

require_variables "MOD_ID" "ENGINE_DIRECTORY" "PACKAGING_DISPLAY_NAME" "PACKAGING_INSTALLER_NAME" \
	"PACKAGING_OSX_MONO_TAG" "PACKAGING_OSX_MONO_SOURCE" "PACKAGING_OSX_MONO_TEMP_ARCHIVE_NAME" \
	"PACKAGING_OSX_DMG_MOD_ICON_POSITION" "PACKAGING_OSX_DMG_APPLICATION_ICON_POSITION" "PACKAGING_OSX_DMG_HIDDEN_ICON_POSITION" \
	"PACKAGING_FAQ_URL" "PACKAGING_OVERWRITE_MOD_VERSION"

if [ ! -f "${ENGINE_DIRECTORY}/Makefile" ]; then
	echo "Required engine files not found."
	echo "Run \`make\` in the mod directory to fetch and build the required files, then try again.";
	exit 1
fi

# Import code signing certificate
if [ -n "${MACOS_DEVELOPER_CERTIFICATE_BASE64}" ] && [ -n "${MACOS_DEVELOPER_CERTIFICATE_PASSWORD}" ] && [ -n "${MACOS_DEVELOPER_IDENTITY}" ]; then
	echo "Importing signing certificate"
	echo "${MACOS_DEVELOPER_CERTIFICATE_BASE64}" | base64 --decode > build.p12
	security create-keychain -p build build.keychain
	security default-keychain -s build.keychain
	security unlock-keychain -p build build.keychain
	security import build.p12 -k build.keychain -P "${MACOS_DEVELOPER_CERTIFICATE_PASSWORD}" -T /usr/bin/codesign >/dev/null 2>&1
	security set-key-partition-list -S apple-tool:,apple: -s -k build build.keychain >/dev/null 2>&1
	rm -fr build.p12
fi

TAG="$1"
if [ $# -eq "1" ]; then
	OUTPUTDIR=$(python3 -c "import os; print(os.path.realpath('.'))")
else
	OUTPUTDIR=$(python3 -c "import os; print(os.path.realpath('$2'))")
fi

if [ ! -d "${OUTPUTDIR}" ]; then
	echo "Output directory '${OUTPUTDIR}' does not exist.";
	exit 1
fi

BUILTDIR="${PACKAGING_DIR}/build"
PACKAGING_OSX_APP_NAME="OpenRA - ${PACKAGING_DISPLAY_NAME}.app"

# Set the working dir to the location of this script
cd "${PACKAGING_DIR}"

modify_plist() {
	sed "s|$1|$2|g" "$3" > "$3.tmp" && mv "$3.tmp" "$3"
}

build_platform() {
	PLATFORM="${1}"
	DMG_NAME="${2}"
	echo "Building launcher (${PLATFORM})"

	mkdir -p "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources"
	mkdir -p "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/MacOS"
	echo "APPL????" > "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/PkgInfo"
	cp "${TEMPLATE_ROOT}/${ENGINE_DIRECTORY}/packaging/macos/Eluant.dll.config" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources"
	cp "${TEMPLATE_ROOT}/${ENGINE_DIRECTORY}/packaging/macos/Info.plist.in" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"

	modify_plist "{DEV_VERSION}" "${TAG}" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"
	modify_plist "{FAQ_URL}" "${PACKAGING_FAQ_URL}" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"
	modify_plist "{MOD_ID}" "${MOD_ID}" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"
	modify_plist "{MOD_NAME}" "${PACKAGING_DISPLAY_NAME}" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"
	modify_plist "{JOIN_SERVER_URL_SCHEME}" "openra-${MOD_ID}-${TAG}" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"

	if [ -n "${DISCORD_APPID}" ]; then
		modify_plist "{DISCORD_URL_SCHEME}" "discord-${DISCORD_APPID}" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"
	else
		modify_plist "<string>{DISCORD_URL_SCHEME}</string>" "" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"
	fi

	if [ "${PLATFORM}" = "compat" ]; then
		modify_plist "{MINIMUM_SYSTEM_VERSION}" "10.9" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"
		clang -m64 "${TEMPLATE_ROOT}/${ENGINE_DIRECTORY}/packaging/macos/launcher-mono.m" -o "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/MacOS/OpenRA" -framework AppKit -mmacosx-version-min=10.9
	else
		modify_plist "{MINIMUM_SYSTEM_VERSION}" "10.13" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Info.plist"
		clang -m64 "${TEMPLATE_ROOT}/${ENGINE_DIRECTORY}/packaging/macos/launcher.m" -o "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/MacOS/OpenRA" -framework AppKit -mmacosx-version-min=10.13

		curl -s -L -o "${PACKAGING_OSX_MONO_TEMP_ARCHIVE_NAME}" -O "${PACKAGING_OSX_MONO_SOURCE}" || exit 3
		unzip -qq -d "${BUILTDIR}" "${PACKAGING_OSX_MONO_TEMP_ARCHIVE_NAME}"
		rm "${PACKAGING_OSX_MONO_TEMP_ARCHIVE_NAME}"

		mv "${BUILTDIR}/mono" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/MacOS/"
		mv "${BUILTDIR}/etc" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources"
		mv "${BUILTDIR}/lib" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources"
	fi

	pushd "${TEMPLATE_ROOT}" > /dev/null

	MOD_VERSION=$(grep 'Version:' mods/${MOD_ID}/mod.yaml | awk '{print $2}')

	if [ "${PACKAGING_OVERWRITE_MOD_VERSION}" == "True" ]; then
		make version VERSION="${TAG}"
	else
		echo "Mod version ${MOD_VERSION} will remain unchanged.";
	fi

	pushd "${ENGINE_DIRECTORY}" > /dev/null
	echo "Building core files"

	make clean
	make core TARGETPLATFORM=osx-x64
	make version VERSION="${ENGINE_VERSION}"
	make install-engine gameinstalldir="/Contents/Resources/" DESTDIR="${BUILTDIR}/${PACKAGING_OSX_APP_NAME}"
	make install-common-mod-files gameinstalldir="/Contents/Resources/" DESTDIR="${BUILTDIR}/${PACKAGING_OSX_APP_NAME}"
	make install-dependencies TARGETPLATFORM=osx-x64 gameinstalldir="/Contents/Resources/"  DESTDIR="${BUILTDIR}/${PACKAGING_OSX_APP_NAME}"

	for f in ${PACKAGING_COPY_ENGINE_FILES}; do
		mkdir -p "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources/$(dirname "${f}")"
		cp -r "${f}" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources/${f}"
	done

	popd > /dev/null

	echo "Building mod files"
	make core
	cp -LR mods/* "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources/mods"

	for f in ${PACKAGING_COPY_MOD_BINARIES}; do
		mkdir -p "${BUILTDIR}/$(dirname "${f}")"
		cp "${ENGINE_DIRECTORY}/bin/${f}" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources/${f}"
	done

	popd > /dev/null


	# Assemble multi-resolution icon
	mkdir "${BUILTDIR}/mod.iconset"
	cp "${ARTWORK_DIR}/icon_16x16.png" "${BUILTDIR}/mod.iconset/icon_16x16.png"
	cp "${ARTWORK_DIR}/icon_32x32.png" "${BUILTDIR}/mod.iconset/icon_16x16@2.png"
	cp "${ARTWORK_DIR}/icon_32x32.png" "${BUILTDIR}/mod.iconset/icon_32x32.png"
	cp "${ARTWORK_DIR}/icon_64x64.png" "${BUILTDIR}/mod.iconset/icon_32x32@2x.png"
	cp "${ARTWORK_DIR}/icon_128x128.png" "${BUILTDIR}/mod.iconset/icon_128x128.png"
	cp "${ARTWORK_DIR}/icon_256x256.png" "${BUILTDIR}/mod.iconset/icon_128x128@2x.png"
	cp "${ARTWORK_DIR}/icon_256x256.png" "${BUILTDIR}/mod.iconset/icon_256x256.png"
	cp "${ARTWORK_DIR}/icon_512x512.png" "${BUILTDIR}/mod.iconset/icon_256x256@2x.png"
	iconutil --convert icns "${BUILTDIR}/mod.iconset" -o "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources/${MOD_ID}.icns"
	rm -rf "${BUILTDIR}/mod.iconset"

	# Sign binaries with developer certificate
	if [ -n "${MACOS_DEVELOPER_IDENTITY}" ]; then
		codesign -s "${MACOS_DEVELOPER_IDENTITY}" --timestamp --options runtime -f --entitlements "${PACKAGING_DIR}/entitlements.plist" "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources/"*.dylib
		codesign -s "${MACOS_DEVELOPER_IDENTITY}" --timestamp --options runtime -f --entitlements "${PACKAGING_DIR}/entitlements.plist" --deep "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}"
	fi

	echo "Packaging disk image"
	hdiutil create "${PACKAGING_DIR}/${DMG_NAME}" -format UDRW -volname "${PACKAGING_DISPLAY_NAME}" -fs HFS+ -srcfolder "${BUILTDIR}"
	DMG_DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "${PACKAGING_DIR}/${DMG_NAME}" | egrep '^/dev/' | sed 1q | awk '{print $1}')
	sleep 2

	# Background image is created from source svg in artsrc repository
	mkdir "/Volumes/${PACKAGING_DISPLAY_NAME}/.background/"
	tiffutil -cathidpicheck "${ARTWORK_DIR}/macos-background.png" "${ARTWORK_DIR}/macos-background-2x.png" -out "/Volumes/${PACKAGING_DISPLAY_NAME}/.background/background.tiff"

	cp "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources/${MOD_ID}.icns" "/Volumes/${PACKAGING_DISPLAY_NAME}/.VolumeIcon.icns"

	echo '
	   tell application "Finder"
	     tell disk "'${PACKAGING_DISPLAY_NAME}'"
	           open
	           set current view of container window to icon view
	           set toolbar visible of container window to false
	           set statusbar visible of container window to false
	           set the bounds of container window to {400, 100, 1000, 550}
	           set theViewOptions to the icon view options of container window
	           set arrangement of theViewOptions to not arranged
	           set icon size of theViewOptions to 72
	           set background picture of theViewOptions to file ".background:background.tiff"
	           make new alias file at container window to POSIX file "/Applications" with properties {name:"Applications"}
	           set position of item "'${PACKAGING_OSX_APP_NAME}'" of container window to {'${PACKAGING_OSX_DMG_MOD_ICON_POSITION}'}
	           set position of item "Applications" of container window to {'${PACKAGING_OSX_DMG_APPLICATION_ICON_POSITION}'}
	           set position of item ".background" of container window to {'${PACKAGING_OSX_DMG_HIDDEN_ICON_POSITION}'}
	           set position of item ".fseventsd" of container window to {'${PACKAGING_OSX_DMG_HIDDEN_ICON_POSITION}'}
	           set position of item ".VolumeIcon.icns" of container window to {'${PACKAGING_OSX_DMG_HIDDEN_ICON_POSITION}'}
	           update without registering applications
	           delay 5
	           close
	     end tell
	   end tell
	' | osascript

	# HACK: Copy the volume icon again - something in the previous step seems to delete it...?
	cp "${BUILTDIR}/${PACKAGING_OSX_APP_NAME}/Contents/Resources/${MOD_ID}.icns" "/Volumes/${PACKAGING_DISPLAY_NAME}/.VolumeIcon.icns"
	SetFile -c icnC "/Volumes/${PACKAGING_DISPLAY_NAME}/.VolumeIcon.icns"
	SetFile -a C "/Volumes/${PACKAGING_DISPLAY_NAME}"

	chmod -Rf go-w "/Volumes/${PACKAGING_DISPLAY_NAME}"
	sync
	sync

	hdiutil detach "${DMG_DEVICE}"
	rm -rf "${BUILTDIR}"
}

notarize_package() {
	DMG_PATH="${1}"
	NOTARIZE_DMG_PATH="${DMG_PATH%.*}"-notarization.dmg
	echo "Submitting ${PACKAGE_NAME} for notarization"

	# Reset xcode search path to fix xcrun not finding altool
	sudo xcode-select -r

	# Create a temporary read-only dmg for submission (notarization service rejects read/write images)
	hdiutil convert "${DMG_PATH}" -format UDZO -imagekey zlib-level=9 -ov -o "${NOTARIZE_DMG_PATH}"

	NOTARIZATION_UUID=$(xcrun altool --notarize-app --primary-bundle-id "net.openra.modsdk" -u "${MACOS_DEVELOPER_USERNAME}" -p "${MACOS_DEVELOPER_PASSWORD}" --file "${NOTARIZE_DMG_PATH}" 2>&1 | awk -F' = ' '/RequestUUID/ { print $2; exit }')
	if [ -z "${NOTARIZATION_UUID}" ]; then
		echo "Submission failed"
		exit 1
	fi

 	echo "${DMG_PATH} submission UUID is ${NOTARIZATION_UUID}"
	rm "${NOTARIZE_DMG_PATH}"

	while :; do
		sleep 30
		NOTARIZATION_RESULT=$(xcrun altool --notarization-info "${NOTARIZATION_UUID}" -u "${MACOS_DEVELOPER_USERNAME}" -p "${MACOS_DEVELOPER_PASSWORD}" 2>&1 | awk -F': ' '/Status/ { print $2; exit }')
		echo "${DMG_PATH}: ${NOTARIZATION_RESULT}"

		if [ "${NOTARIZATION_RESULT}" == "invalid" ]; then
			NOTARIZATION_LOG_URL=$(xcrun altool --notarization-info "${NOTARIZATION_UUID}" -u "${MACOS_DEVELOPER_USERNAME}" -p "${MACOS_DEVELOPER_PASSWORD}" 2>&1 | awk -F': ' '/LogFileURL/ { print $2; exit }')
			echo "${NOTARIZATION_UUID} failed notarization with error:"
			curl -s "${NOTARIZATION_LOG_URL}" -w "\n"
			exit 1
		fi

		if [ "${NOTARIZATION_RESULT}" == "success" ]; then
			echo "${DMG_PATH}: Stapling tickets"
			DMG_DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "${DMG_PATH}" | egrep '^/dev/' | sed 1q | awk '{print $1}')
			sleep 2

			xcrun stapler staple "/Volumes/${PACKAGING_DISPLAY_NAME}/${PACKAGING_OSX_APP_NAME}"

			sync
			sync

			hdiutil detach "${DMG_DEVICE}"
			break
		fi
	done
}

finalize_package() {
	DMG_PATH="${1}"
	OUTPUT_PATH="${2}"

	hdiutil convert "${DMG_PATH}" -format UDZO -imagekey zlib-level=9 -ov -o "${OUTPUT_PATH}"
	rm "${DMG_PATH}"
}

build_platform "standard" "build.dmg"
build_platform "compat" "build-compat.dmg"

if [ -n "${MACOS_DEVELOPER_CERTIFICATE_BASE64}" ] && [ -n "${MACOS_DEVELOPER_CERTIFICATE_PASSWORD}" ] && [ -n "${MACOS_DEVELOPER_IDENTITY}" ]; then
	security delete-keychain build.keychain
fi

if [ -n "${MACOS_DEVELOPER_USERNAME}" ] && [ -n "${MACOS_DEVELOPER_PASSWORD}" ]; then
	# Parallelize processing
	(notarize_package "build.dmg") &
	(notarize_package "build-compat.dmg") &
	wait
fi

finalize_package "build.dmg" "${OUTPUTDIR}/${PACKAGING_INSTALLER_NAME}-${TAG}.dmg"
finalize_package "build-compat.dmg" "${OUTPUTDIR}/${PACKAGING_INSTALLER_NAME}-${TAG}-compat.dmg"
