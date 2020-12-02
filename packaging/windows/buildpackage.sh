#!/bin/bash
set -e
command -v makensis >/dev/null 2>&1 || { echo >&2 "The OpenRA mod SDK Windows packaging requires makensis."; exit 1; }
command -v convert >/dev/null 2>&1 || { echo >&2 "The OpenRA mod SDK Windows packaging requires ImageMagick."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo >&2 "The OpenRA mod SDK Windows packaging requires python 3."; exit 1; }

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
	"PACKAGING_WINDOWS_LAUNCHER_NAME" "PACKAGING_WINDOWS_REGISTRY_KEY" "PACKAGING_WINDOWS_INSTALL_DIR_NAME" \
	"PACKAGING_WINDOWS_LICENSE_FILE" "PACKAGING_FAQ_URL" "PACKAGING_WEBSITE_URL" "PACKAGING_AUTHORS" "PACKAGING_OVERWRITE_MOD_VERSION"

TAG="$1"
if [ $# -eq "1" ]; then
	OUTPUTDIR=$(python3 -c "import os; print(os.path.realpath('.'))")
else
	OUTPUTDIR=$(python3 -c "import os; print(os.path.realpath('$2'))")
fi

BUILTDIR="${PACKAGING_DIR}/build"

# Set the working dir to the location of this script
cd "${PACKAGING_DIR}"

pushd ${TEMPLATE_ROOT} > /dev/null

if [ ! -f "${ENGINE_DIRECTORY}/Makefile" ]; then
	echo "Required engine files not found."
	echo "Run \`make\` in the mod directory to fetch and build the required files, then try again.";
	exit 1
fi

if [ ! -d "${OUTPUTDIR}" ]; then
	echo "Output directory '${OUTPUTDIR}' does not exist.";
	exit 1
fi

MOD_VERSION=$(grep 'Version:' mods/${MOD_ID}/mod.yaml | awk '{print $2}')

if [ "${PACKAGING_OVERWRITE_MOD_VERSION}" == "True" ]; then
	make version VERSION="${TAG}"
else
	echo "Mod version ${MOD_VERSION} will remain unchanged.";
fi

popd > /dev/null

function build_platform()
{
	PLATFORM="${1}"
	if [ "${PLATFORM}" = "x86" ]; then
		USE_PROGRAMFILES32="-DUSE_PROGRAMFILES32=true"
	else
		USE_PROGRAMFILES32=""
	fi

	if [ -n "${PACKAGING_DISCORD_APPID}" ]; then
		USE_DISCORDID="-DUSE_DISCORDID=${PACKAGING_DISCORD_APPID}"
	else
		USE_DISCORDID=""
	fi

	pushd ${TEMPLATE_ROOT} > /dev/null

	echo "Building core files (${PLATFORM})"
	pushd ${ENGINE_DIRECTORY} > /dev/null

	make clean
	make core TARGETPLATFORM="win-${PLATFORM}"
	make version VERSION="${ENGINE_VERSION}"
	make install-engine TARGETPLATFORM="win-${PLATFORM}" gameinstalldir="" DESTDIR="${BUILTDIR}"
	make install-common-mod-files gameinstalldir="" DESTDIR="${BUILTDIR}"
	make install-dependencies TARGETPLATFORM="win-${PLATFORM}" gameinstalldir="" DESTDIR="${BUILTDIR}"

	for f in ${PACKAGING_COPY_ENGINE_FILES}; do
		mkdir -p "${BUILTDIR}/$(dirname "${f}")"
		cp -r "${f}" "${BUILTDIR}/${f}"
	done

	popd > /dev/null

	echo "Building mod files (${PLATFORM})"
	make core

	cp -Lr mods/* "${BUILTDIR}/mods"

	for f in ${PACKAGING_COPY_MOD_BINARIES}; do
		mkdir -p "${BUILTDIR}/$(dirname "${f}")"
		cp "${ENGINE_DIRECTORY}/bin/${f}" "${BUILTDIR}/${f}"
	done

	popd > /dev/null

	# Create multi-resolution icon
	convert "${ARTWORK_DIR}/icon_16x16.png" "${ARTWORK_DIR}/icon_24x24.png" "${ARTWORK_DIR}/icon_32x32.png" "${ARTWORK_DIR}/icon_48x48.png" "${ARTWORK_DIR}/icon_256x256.png" "${BUILTDIR}/${MOD_ID}.ico"

	echo "Compiling Windows launcher (${PLATFORM})"
	msbuild -t:Build "${TEMPLATE_ROOT}/${ENGINE_DIRECTORY}/OpenRA.WindowsLauncher/OpenRA.WindowsLauncher.csproj" -restore -p:Configuration=Release -p:TargetPlatform="win-${PLATFORM}" -p:LauncherName="${PACKAGING_WINDOWS_LAUNCHER_NAME}" -p:LauncherIcon="${BUILTDIR}/${MOD_ID}.ico" -p:ModID="${MOD_ID}" -p:DisplayName="${PACKAGING_DISPLAY_NAME}" -p:FaqUrl="${PACKAGING_FAQ_URL}"
	cp "${TEMPLATE_ROOT}/${ENGINE_DIRECTORY}/bin/${PACKAGING_WINDOWS_LAUNCHER_NAME}.exe" "${BUILTDIR}"
	cp "${TEMPLATE_ROOT}/${ENGINE_DIRECTORY}/bin/${PACKAGING_WINDOWS_LAUNCHER_NAME}.exe.config" "${BUILTDIR}"

	# Enable the full 4GB address space for the 32 bit game executable
	# The server and utility do not use enough memory to need this
	if [ "${PLATFORM}" = "x86" ]; then
		python3 "${TEMPLATE_ROOT}/${ENGINE_DIRECTORY}/packaging/windows/MakeLAA.py" "${BUILTDIR}/${PACKAGING_WINDOWS_LAUNCHER_NAME}.exe"
	fi

	# Remove redundant generic launcher
	rm "${BUILTDIR}/OpenRA.exe"

	echo "Building Windows setup.exe (${PLATFORM})"
	pushd "${PACKAGING_DIR}" > /dev/null
	makensis -V2 -DSRCDIR="${BUILTDIR}" -DTAG="${TAG}" -DMOD_ID="${MOD_ID}" -DPACKAGING_WINDOWS_INSTALL_DIR_NAME="${PACKAGING_WINDOWS_INSTALL_DIR_NAME}" -DPACKAGING_WINDOWS_LAUNCHER_NAME="${PACKAGING_WINDOWS_LAUNCHER_NAME}" -DPACKAGING_DISPLAY_NAME="${PACKAGING_DISPLAY_NAME}" -DPACKAGING_WEBSITE_URL="${PACKAGING_WEBSITE_URL}" -DPACKAGING_AUTHORS="${PACKAGING_AUTHORS}" -DPACKAGING_WINDOWS_REGISTRY_KEY="${PACKAGING_WINDOWS_REGISTRY_KEY}" -DPACKAGING_WINDOWS_LICENSE_FILE="${TEMPLATE_ROOT}/${PACKAGING_WINDOWS_LICENSE_FILE}" ${USE_PROGRAMFILES32} ${USE_DISCORDID} buildpackage.nsi
	if [ $? -eq 0 ]; then
		mv OpenRA.Setup.exe "${OUTPUTDIR}/${PACKAGING_INSTALLER_NAME}-${TAG}-${PLATFORM}.exe"
	fi
	popd > /dev/null

	echo "Packaging zip archive (${PLATFORM})"
	pushd "${BUILTDIR}" > /dev/null
	zip "${PACKAGING_INSTALLER_NAME}-${TAG}-${PLATFORM}-winportable.zip" -r -9 * --quiet
	mv "${PACKAGING_INSTALLER_NAME}-${TAG}-${PLATFORM}-winportable.zip" "${OUTPUTDIR}"
	popd > /dev/null

	# Cleanup
	rm -rf "${BUILTDIR}"
}

build_platform "x86"
build_platform "x64"
