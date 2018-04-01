#!/bin/bash
# OpenRA packaging script for Linux (Flatpak)
set -e

command -v make >/dev/null 2>&1 || { echo >&2 "The OpenRA mod template requires make."; exit 1; }
command -v python >/dev/null 2>&1 || { echo >&2 "The OpenRA mod template requires python."; exit 1; }
command -v flatpak >/dev/null 2>&1 || { echo >&2 "The OpenRA mod template requires flatpak."; exit 1; }
command -v flatpak-builder >/dev/null 2>&1 || { echo >&2 "The OpenRA mod template requires flatpak-builder."; exit 1; }

if [ $# -eq "0" ]; then
	echo "Usage: `basename $0` version [outputdir]"
	exit 1
fi

PACKAGING_DIR=$(python -c "import os; print(os.path.dirname(os.path.realpath('$0')))")
TEMPLATE_ROOT="${PACKAGING_DIR}/../../"

# shellcheck source=mod.config
. "${TEMPLATE_ROOT}/mod.config"

if [ -f "${TEMPLATE_ROOT}/user.config" ]; then
	# shellcheck source=user.config
	. "${TEMPLATE_ROOT}/user.config"
fi

if [ "${INCLUDE_DEFAULT_MODS}" = "True" ]; then
	echo "Cannot generate installers while INCLUDE_DEFAULT_MODS is enabled."
	echo "Make sure that this setting is disabled in both your mod.config and user.config."
	exit 1
fi

TAG="$1"
if [ $# -eq "1" ]; then
	OUTPUTDIR=$(python -c "import os; print(os.path.realpath('.'))")
else
	OUTPUTDIR=$(python -c "import os; print(os.path.realpath('$2'))")
fi

BUILTDIR="${PACKAGING_DIR}/build"

# Set the working dir to the location of this script
cd "${PACKAGING_DIR}"

echo "Building core files"

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

make version VERSION="${TAG}"

pushd ${ENGINE_DIRECTORY} > /dev/null
make linux-dependencies
make core SDK="-sdk:4.5"
make install-engine prefix="" DESTDIR="${BUILTDIR}"
make install-common-mod-files prefix="" DESTDIR="${BUILTDIR}"

# Force bundled lua library
sed "s|@LIBLUA51@|/app/lib|" thirdparty/Eluant.dll.config.in > "${BUILTDIR}/lib/openra/Eluant.dll.config"

popd > /dev/null
popd > /dev/null

# Add mod files
cp -r "${TEMPLATE_ROOT}/mods/"* "${BUILTDIR}/lib/openra/mods"

# Launcher and icons
install -d "${BUILTDIR}/share/applications"
sed "s/{MODID}/${MOD_ID}/g" mod.desktop.in | sed "s/{MODNAME}/${PACKAGING_DISPLAY_NAME}/g" | sed "s/{MODINSTALLERNAME}/${PACKAGING_INSTALLER_NAME}/g" > temp.desktop
install -m 0755 temp.desktop "${BUILTDIR}/share/applications/net.openra.${PACKAGING_INSTALLER_NAME}.desktop"

for i in 16x16 32x32 48x48 64x64 128x128 256x256 512x512 1024x1024 scalable; do
  if [ -f "${PACKAGING_DIR}/mod_${i}.png" ]; then
    install -Dm644 "${PACKAGING_DIR}/mod_${i}.png" "${BUILTDIR}/share/icons/hicolor/${i}/apps/net.openra.${PACKAGING_INSTALLER_NAME}.png"
  elif [ -f "${PACKAGING_DIR}/mod_${i}.svg" ]; then
      install -Dm644 "${PACKAGING_DIR}/mod_${i}.svg" "${BUILTDIR}/share/icons/hicolor/${i}/apps/net.openra.${PACKAGING_INSTALLER_NAME}.svg"
  fi
done

install -d "${BUILTDIR}/bin"

sed "s/{MODID}/${MOD_ID}/g" openra-mod.in | sed "s/{MODNAME}/${PACKAGING_DISPLAY_NAME}/g" | sed "s/{MODINSTALLERNAME}/${PACKAGING_INSTALLER_NAME}/g" | sed "s|{MODFAQURL}|${PACKAGING_FAQ_URL}|g" > openra-mod.temp
install -m 0755 openra-mod.temp "${BUILTDIR}/bin/openra-${MOD_ID}"

echo "Packaging archive to hand to flakpak"
tar cvf build.tar build

echo "Running Flatpak packager"
sed "s/{MODID}/${MOD_ID}/g" net.openra.mod.json.in | sed "s/{MODINSTALLERNAME}/${PACKAGING_INSTALLER_NAME}/g" > "net.openra.${PACKAGING_INSTALLER_NAME}.json"
flatpak-builder --repo=openra-modsdk build-flatpak "net.openra.${PACKAGING_INSTALLER_NAME}.json"
flatpak build-bundle openra-modsdk "${OUTPUTDIR}/${PACKAGING_INSTALLER_NAME}-${TAG}.flatpak" "net.openra.${PACKAGING_INSTALLER_NAME}"

# Clean up
rm -rf "${BUILTDIR}" build-flatpak openra-modsdk .flatpak-builder openra-mod.temp temp.desktop build.tar "net.openra.${PACKAGING_INSTALLER_NAME}.json"
