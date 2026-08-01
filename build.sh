#!/bin/bash
#
# PullOver X 打包脚本。
#
# Xcode compiles the binaries (PullOverX.dylib + PullOverXPreferences.bundle);
# this script assembles and builds the .deb for the requested jailbreak scheme.
#
# Usage:
#   ./build.sh [roothide|rootless|rootful] [debug|release]
#
# Schemes:
#   roothide  -> RootHide devkit + libroothide (dynamic jbroot)
#   rootless  -> Theos libroot (standard rootless path resolution)
#   rootful   -> canonical rootful paths
#
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="${1:-roothide}"
CONFIG_ARG="${2:-release}"

case "$CONFIG_ARG" in
	debug|Debug)     CONFIGURATION="Debug" ;;
	release|Release) CONFIGURATION="Release" ;;
	*) echo "error: unknown configuration '$CONFIG_ARG' (use debug|release)"; exit 1 ;;
esac

# ---- Per-scheme settings -----------------------------------------------------
POP_ROOTHIDE_LDFLAGS="-lroothide"
POP_ROOTLESS_LDFLAGS=""
POP_SCHEME_DEFS="THEOS_PACKAGE_SCHEME_ROOTHIDE=1"
POP_RPATHS=""
ARCHS="arm64e"

# Jailbreak environment <-> deb architecture / install prefix mapping:
#   rootful  -> deb iphoneos-arm    prefix /        (absolute install names)
#   rootless -> deb iphoneos-arm64  prefix /var/jb  (@rpath install names)
#   roothide -> deb iphoneos-arm64e prefix /        (randomized jbroot, @loader_path/.jbroot)
# NB: "arm/arm64/arm64e" here are the dpkg Architecture labels, not CPU archs.
#     Binaries are built fat (arm64+arm64e) where possible so the preference
#     bundle loads regardless of whether the host process runs as arm64 or arm64e.
case "$SCHEME" in
	roothide)
		PREFIX=""
		DEB_ARCH="iphoneos-arm64e"
		ARCHS="arm64 arm64e"
		;;
	rootless)
		PREFIX="/var/jb"
		DEB_ARCH="iphoneos-arm64"
		ARCHS="arm64 arm64e"
		POP_ROOTHIDE_LDFLAGS=""
		POP_ROOTLESS_LDFLAGS="-lroot"
		POP_SCHEME_DEFS="ROOTHIDE_USE_STUB=1 POP_PACKAGE_SCHEME_ROOTLESS=1"
		# Rootless v2 supports both the conventional and relocated jbroot rpaths.
		POP_RPATHS="/var/jb/usr/lib /var/jb/Library/Frameworks @loader_path/.jbroot/usr/lib @loader_path/.jbroot/Library/Frameworks"
		;;
	rootful)
		PREFIX=""
		DEB_ARCH="iphoneos-arm"
		ARCHS="arm64"
		POP_ROOTHIDE_LDFLAGS=""
		POP_SCHEME_DEFS="ROOTHIDE_USE_STUB=1 POP_PACKAGE_SCHEME_ROOTFUL=1"
		POP_RPATHS="/usr/lib /Library/Frameworks"
		;;
	*)
		echo "error: unknown scheme '$SCHEME' (use roothide|rootless|rootful)"
		exit 1
		;;
esac

echo "==> Building PullOver X  [scheme=$SCHEME  config=$CONFIGURATION  arch=$ARCHS  deb=$DEB_ARCH]"

# ---- Compile with Xcode ------------------------------------------------------
BUILD_ROOT="$PWD/build"
BUILD_DIR="$BUILD_ROOT/$SCHEME"
PRODUCTS_DIR="$BUILD_DIR/products"
# Build products, derived data, and staging files are temporary. Keep only the
# finished package in packages/ after this script exits, including on failure.
trap 'rm -rf "$BUILD_ROOT"' EXIT
rm -rf "$BUILD_DIR"
mkdir -p "$PRODUCTS_DIR"
DERIVED_DATA_DIR="$BUILD_DIR/derived-data"

XCB_COMMON=(
	-project PullOverX.xcodeproj
	-derivedDataPath "$DERIVED_DATA_DIR"
	-configuration "$CONFIGURATION"
	-sdk iphoneos
	ARCHS="$ARCHS"
	VALID_ARCHS="$ARCHS"
	ONLY_ACTIVE_ARCH=NO
	POP_SCHEME="$SCHEME"
	POP_ROOTHIDE_LDFLAGS="$POP_ROOTHIDE_LDFLAGS"
	POP_ROOTLESS_LDFLAGS="$POP_ROOTLESS_LDFLAGS"
	POP_SCHEME_DEFS="$POP_SCHEME_DEFS"
	LD_RUNPATH_SEARCH_PATHS="$POP_RPATHS"
	CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR"
	CODE_SIGNING_ALLOWED=NO
	CODE_SIGNING_REQUIRED=NO
)

for TARGET in PullOverXPreferences PullOverX; do
	echo "==> xcodebuild scheme $TARGET"
	xcodebuild -scheme "$TARGET" "${XCB_COMMON[@]}" build
done

DYLIB="$PRODUCTS_DIR/PullOverX.dylib"
BUNDLE="$PRODUCTS_DIR/PullOverXPreferences.bundle"

[ -f "$DYLIB" ]   || { echo "error: $DYLIB not built"; exit 1; }
[ -d "$BUNDLE" ]  || { echo "error: $BUNDLE not built"; exit 1; }

# ---- Fake-sign the binaries (jailbreak load requirement) ---------------------
if command -v ldid >/dev/null 2>&1; then
	echo "==> ldid -S (ad-hoc signing)"
	ldid -S "$DYLIB"
	ldid -S "$BUNDLE/PullOverXPreferences"
fi

# ---- Assemble the package staging tree ---------------------------------------
STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"
ROOT="$STAGE$PREFIX"

# Tweak dylib + MobileSubstrate filter
mkdir -p "$ROOT/Library/MobileSubstrate/DynamicLibraries"
cp "$DYLIB" "$ROOT/Library/MobileSubstrate/DynamicLibraries/PullOverX.dylib"
cp "PullOverX/Package/Library/MobileSubstrate/DynamicLibraries/PullOverX.plist" \
   "$ROOT/Library/MobileSubstrate/DynamicLibraries/PullOverX.plist"

# Tweak resources
mkdir -p "$ROOT/Library/Application Support/PullOverX"
cp changelog.plist "PullOverX/Package/Library/Application Support/PullOverX/changelog.plist"
cp "PullOverX/Package/Library/Application Support/PullOverX/"* \
   "$ROOT/Library/Application Support/PullOverX/"

# Preference bundle (built) + bundled resources
mkdir -p "$ROOT/Library/PreferenceBundles"
cp -R "$BUNDLE" "$ROOT/Library/PreferenceBundles/PullOverXPreferences.bundle"
SRC_BUNDLE="PullOverXPreferences/Package/Library/PreferenceBundles/PullOverXPreferences.bundle"
# copy runtime resources (images + settings spec), skip stale binary/signature/frameworks
find "$SRC_BUNDLE" -maxdepth 1 -type f \
	! -name 'PullOverXPreferences' ! -name 'Info.plist' \
	-exec cp {} "$ROOT/Library/PreferenceBundles/PullOverXPreferences.bundle/" \;
# Keep localized .lproj directories with the preference bundle. The tweak and
# Preferences controller both resolve their strings from this installed bundle.
find "$SRC_BUNDLE" -maxdepth 1 -type d -name '*.lproj' \
	-exec cp -R {} "$ROOT/Library/PreferenceBundles/PullOverXPreferences.bundle/" \;
rm -rf "$ROOT/Library/PreferenceBundles/PullOverXPreferences.bundle/_CodeSignature"

# Strip Xcode-injected keys that break preference-bundle loading by the Settings app.
BUNDLE_PLIST="$ROOT/Library/PreferenceBundles/PullOverXPreferences.bundle/Info.plist"
if [ -f "$BUNDLE_PLIST" ]; then
	plutil -remove UIRequiredDeviceCapabilities "$BUNDLE_PLIST" 2>/dev/null || true
fi

# PreferenceLoader entry
mkdir -p "$ROOT/Library/PreferenceLoader/Preferences"
cp "PullOverXPreferences/Package/Library/PreferenceLoader/Preferences/PullOverXPreferences.plist" \
   "$ROOT/Library/PreferenceLoader/Preferences/PullOverXPreferences.plist"

# ---- DEBIAN control ----------------------------------------------------------
mkdir -p "$STAGE/DEBIAN"
sed -E "s/^Architecture:.*/Architecture: $DEB_ARCH/" \
	"PullOverX/Package/DEBIAN/control" > "$STAGE/DEBIAN/control"

# ---- Build the .deb ----------------------------------------------------------
mkdir -p packages
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "$STAGE/DEBIAN/control" | tr -d '\r')"
PKGID="$(sed -n 's/^Package:[[:space:]]*//p' "$STAGE/DEBIAN/control" | tr -d '\r')"
DEB="packages/${PKGID}_${VERSION}_${DEB_ARCH}.deb"

find "$STAGE" -name '.DS_Store' -delete
chmod -R 0755 "$STAGE/DEBIAN"
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$DEB"

echo "==> Done: $DEB"
