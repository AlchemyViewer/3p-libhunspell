#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

HUNSPELL_SOURCE_DIR="hunspell"
# Look in configure script for line PACKAGE_VERSION='x.y.z', then capture
# everything between single quotes.
HUNSPELL_VERSION="$(expr "$(grep '^PACKAGE_VERSION=' "$HUNSPELL_SOURCE_DIR/configure")" \
                         : ".*'\(.*\)'")"

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

stage="$(pwd)/stage"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

echo "${HUNSPELL_VERSION}" > "${stage}/VERSION.txt"

pushd "$HUNSPELL_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            build_sln "msvc/Hunspell.sln" "Debug_dll" "$AUTOBUILD_WIN_VSPLATFORM"
            build_sln "msvc/Hunspell.sln" "Release_dll" "$AUTOBUILD_WIN_VSPLATFORM"

            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then 
                debbitdir=msvc/Debug_dll/libhunspell/libhunspell
                relbitdir=msvc/Release_dll/libhunspell/libhunspell
            else
                debbitdir=msvc/x64/Debug_dll/libhunspell
                relbitdir=msvc/x64/Release_dll/libhunspell
            fi

            cp "$debbitdir"{.dll,.lib,.pdb,.exp} "$stage/lib/debug"
            cp "$relbitdir"{.dll,.lib,.pdb,.exp} "$stage/lib/release"
        ;;
        darwin*)
            # Setup osx sdk platform
            SDKNAME="macosx10.15"
            export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)
            export MACOSX_DEPLOYMENT_TARGET=10.13

            # Setup build flags
            ARCH_FLAGS="-arch x86_64"
            SDK_FLAGS="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${SDKROOT}"
            DEBUG_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -Og -g -msse4.2 -fPIC -DPIC"
            RELEASE_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -Ofast -ffast-math -g -msse4.2 -fPIC -DPIC -fstack-protector-strong"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC"
            DEBUG_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names -Wl,-macos_version_min,$MACOSX_DEPLOYMENT_TARGET"
            RELEASE_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names -Wl,-macos_version_min,$MACOSX_DEPLOYMENT_TARGET"

            JOBS=`sysctl -n hw.ncpu`

            # force regenerate autoconf
            autoreconf -fvi

            mkdir -p "build_debug"
            pushd "build_debug"
                CFLAGS="$DEBUG_CFLAGS" CPPFLAGS="$DEBUG_CPPFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" LDFLAGS="$DEBUG_LDFLAGS" \
                    ../configure --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug"
                make -j$JOBS
                make install DESTDIR="$stage"

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make check
                fi
            popd

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$RELEASE_CFLAGS" CPPFLAGS="$RELEASE_CPPFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" LDFLAGS="$RELEASE_LDFLAGS" \
                    ../configure --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release"
                make -j$JOBS
                make install DESTDIR="$stage"

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make check
                fi
            popd

            pushd "$stage/lib/debug"
                fix_dylib_id libhunspell-1*.dylib
                dsymutil libhunspell-*.*.*.dylib
                strip -x -S libhunspell-*.*.*.dylib
            popd

            pushd "$stage/lib/release"
                fix_dylib_id libhunspell-1*.dylib
                dsymutil libhunspell-*.*.*.dylib
                strip -x -S libhunspell-*.*.*.dylib
            popd
        ;;
        linux*)
            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
            DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC"
            RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -fstack-protector-strong -DPIC -D_FORTIFY_SOURCE=2"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC -D_FORTIFY_SOURCE=2"

            JOBS=`cat /proc/cpuinfo | grep processor | wc -l`

            # force regenerate autoconf
            autoreconf -fvi

            mkdir -p "build_debug"
            pushd "build_debug"
                CFLAGS="$DEBUG_CFLAGS" CPPFLAGS="$DEBUG_CPPFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" \
                    ../configure --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug"
                make -j$JOBS
                make install DESTDIR="$stage"

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make check
                fi
            popd

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$RELEASE_CFLAGS" CPPFLAGS="$RELEASE_CPPFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" \
                    ../configure --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release"
                make -j$JOBS
                make install DESTDIR="$stage"

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make check
                fi
            popd
        ;;
    esac
    mkdir -p "$stage/include/hunspell"
    cp src/hunspell/{*.h,*.hxx} "$stage/include/hunspell"
    mkdir -p "$stage/LICENSES"
    cp "license.hunspell" "$stage/LICENSES/hunspell.txt"
    cp "license.myspell" "$stage/LICENSES/myspell.txt"
popd
