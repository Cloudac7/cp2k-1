#!/bin/bash -e

# TODO: Review and if possible fix shellcheck errors.
# shellcheck disable=SC1003,SC1035,SC1083,SC1090
# shellcheck disable=SC2001,SC2002,SC2005,SC2016,SC2091,SC2034,SC2046,SC2086,SC2089,SC2090
# shellcheck disable=SC2124,SC2129,SC2144,SC2153,SC2154,SC2155,SC2163,SC2164,SC2166
# shellcheck disable=SC2235,SC2237

[ "${BASH_SOURCE[0]}" ] && SCRIPT_NAME="${BASH_SOURCE[0]}" || SCRIPT_NAME=$0
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_NAME")/.." && pwd -P)"

gcc_ver="10.2.0"
gcc_sha256="27e879dccc639cd7b0cc08ed575c1669492579529b53c9ff27b0b96265fa867d"

patches=(
  "${SCRIPT_DIR}/stage0/gcc-${gcc_ver}-cpp-__has_include.patch"
)

source "${SCRIPT_DIR}"/common_vars.sh
source "${SCRIPT_DIR}"/tool_kit.sh
source "${SCRIPT_DIR}"/signal_trap.sh
source "${INSTALLDIR}"/toolchain.conf
source "${INSTALLDIR}"/toolchain.env

[ -f "${BUILDDIR}/setup_gcc" ] && rm "${BUILDDIR}/setup_gcc"

GCC_LDFLAGS=""
GCC_CFLAGS=""
TSANFLAGS=""
! [ -d "${BUILDDIR}" ] && mkdir -p "${BUILDDIR}"
cd "${BUILDDIR}"

case "$with_gcc" in
  __INSTALL__)
    echo "==================== Installing GCC ===================="
    pkg_install_dir="${INSTALLDIR}/gcc-${gcc_ver}"
    install_lock_file="$pkg_install_dir/install_successful"
    if verify_checksums "${install_lock_file}"; then
      echo "gcc-${gcc_ver} is already installed, skipping it."
    else
      if [ "${gcc_ver}" == "master" ]; then
        [ -d gcc-master ] && rm -rf gcc-master
        svn checkout svn://gcc.gnu.org/svn/gcc/trunk gcc-master > svn-gcc.log 2>&1
      else
        if [ -f gcc-${gcc_ver}.tar.gz ]; then
          echo "gcc-${gcc_ver}.tar.gz is found"
        else
          download_pkg ${DOWNLOADER_FLAGS} ${gcc_sha256} \
            "https://www.cp2k.org/static/downloads/gcc-${gcc_ver}.tar.gz"
        fi
        [ -d gcc-${gcc_ver} ] && rm -rf gcc-${gcc_ver}
        tar -xzf gcc-${gcc_ver}.tar.gz
      fi
      echo "Installing GCC from scratch into ${pkg_install_dir}"
      cd gcc-${gcc_ver}

      for patch in "${patches[@]}"; do
        patch -p1 < "${patch}"
      done

      ./contrib/download_prerequisites > prereq.log 2>&1
      GCCROOT=${PWD}
      mkdir obj
      cd obj
      ${GCCROOT}/configure --prefix="${pkg_install_dir}" \
        --libdir="${pkg_install_dir}/lib" \
        --enable-languages=c,c++,fortran \
        --disable-multilib --disable-bootstrap \
        --enable-lto \
        --enable-plugins \
        > configure.log 2>&1
      make -j $(get_nprocs) \
        CFLAGS="-fPIC $CFLAGS" \
        CXXFLAGS="-fPIC $CXXFLAGS" \
        > make.log 2>&1
      make -j $(get_nprocs) install > install.log 2>&1
      # thread sanitizer
      if [ $ENABLE_TSAN = "__TRUE__" ]; then
        # now the tricky bit... we need to recompile in particular
        # libgomp with -fsanitize=thread.. there is not configure
        # option for this (as far as I know).  we need to go in
        # the build tree and recompile / reinstall with proper
        # options...  this is likely to break for later version of
        # gcc, tested with 5.1.0 based on
        # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=55374#c10
        cd x86_64*/libgfortran
        make clean > clean.log 2>&1
        make -j $(get_nprocs) \
          CFLAGS="-std=gnu99 -g -O2 -fsanitize=thread " \
          FCFLAGS="-g -O2 -fsanitize=thread" \
          CXXFLAGS="-std=gnu99 -g -O2 -fsanitize=thread " \
          LDFLAGS="-B$(pwd)/../libsanitizer/tsan/.libs/ -Wl,-rpath,$(pwd)/../libsanitizer/tsan/.libs/ -fsanitize=thread" \
          > make.log 2>&1
        make install > install.log 2>&1
        cd ../libgomp
        make clean > clean.log 2>&1
        make -j $(get_nprocs) \
          CFLAGS="-std=gnu99 -g -O2 -fsanitize=thread " \
          FCFLAGS="-g -O2 -fsanitize=thread" \
          CXXFLAGS="-std=gnu99 -g -O2 -fsanitize=thread " \
          LDFLAGS="-B$(pwd)/../libsanitizer/tsan/.libs/ -Wl,-rpath,$(pwd)/../libsanitizer/tsan/.libs/ -fsanitize=thread" \
          > make.log 2>&1
        make install > install.log 2>&1
        cd $GCCROOT/obj/
      fi
      cd ../..
      write_checksums "${install_lock_file}" "${SCRIPT_DIR}/stage0/$(basename ${SCRIPT_NAME})"
    fi
    GCC_CFLAGS="-I'${pkg_install_dir}/include'"
    GCC_LDFLAGS="-L'${pkg_install_dir}/lib64' -L'${pkg_install_dir}/lib' -Wl,-rpath='${pkg_install_dir}/lib64' -Wl,-rpath='${pkg_install_dir}/lib64'"
    ;;
  __SYSTEM__)
    echo "==================== Finding GCC from system paths ===================="
    check_command gcc "gcc"
    check_command g++ "gcc"
    check_command gfortran "gcc"
    add_include_from_paths -p GCC_CFLAGS "c++" $INCLUDE_PATHS
    add_lib_from_paths GCC_LDFLAGS "libgfortran.*" $LIB_PATHS
    ;;
  __DONTUSE__) ;;

  *)
    echo "==================== Linking GCC to user paths ===================="
    pkg_install_dir="$with_gcc"
    check_dir "${pkg_install_dir}/bin"
    check_dir "${pkg_install_dir}/lib"
    check_dir "${pkg_install_dir}/lib64"
    check_dir "${pkg_install_dir}/include"
    GCC_CFLAGS="-I'${pkg_install_dir}/include'"
    GCC_LDFLAGS="-L'${pkg_install_dir}/lib64' -L'${pkg_install_dir}/lib' -Wl,-rpath='${pkg_install_dir}/lib64' -Wl,-rpath='${pkg_install_dir}/lib64'"
    ;;
esac
if [ "$ENABLE_TSAN" = "__TRUE__" ]; then
  TSANFLAGS="-fsanitize=thread"
else
  TSANFLAGS=""
fi
if [ "$with_gcc" != "__DONTUSE__" ]; then
  if [ "$with_gcc" != "__SYSTEM__" ]; then
    cat << EOF > "${BUILDDIR}/setup_gcc"
# needs full path for mpich/openmpi builds, triggers openblas bug
export CC="${pkg_install_dir}/bin/gcc"
export CXX="${pkg_install_dir}/bin/g++"
export FC="${pkg_install_dir}/bin/gfortran"
export F90="${pkg_install_dir}/bin/gfortran"
export F77="${pkg_install_dir}/bin/gfortran"
prepend_path PATH "${pkg_install_dir}/bin"
prepend_path LD_LIBRARY_PATH "${pkg_install_dir}/lib"
prepend_path LD_LIBRARY_PATH "${pkg_install_dir}/lib64"
prepend_path LD_RUN_PATH "${pkg_install_dir}/lib"
prepend_path LD_RUN_PATH "${pkg_install_dir}/lib64"
prepend_path LIBRARY_PATH "${pkg_install_dir}/lib"
prepend_path LIBRARY_PATH "${pkg_install_dir}/lib64"
prepend_path CPATH "${pkg_install_dir}/include"
EOF
    cat "${BUILDDIR}/setup_gcc" >> $SETUPFILE
  fi
  cat << EOF >> "${BUILDDIR}/setup_gcc"
export GCC_CFLAGS="${GCC_CFLAGS}"
export GCC_LDFLAGS="${GCC_LDFLAGS}"
export TSANFLAGS="${TSANFLAGS}"
EOF
fi
cd "${ROOTDIR}"

# ----------------------------------------------------------------------
# Suppress reporting of known leaks
# ----------------------------------------------------------------------

# this might need to be adjusted for the versions of the software
# employed
cat << EOF >> ${INSTALLDIR}/lsan.supp
# known leak either related to mpi or scalapack  (e.g. showing randomly for Fist/regtest-7-2/UO2-2x2x2-genpot_units.inp)
leak:__cp_fm_types_MOD_cp_fm_write_unformatted
# leak related to mpi or scalapack  triggers sometimes for regtest-kp-2/cc2.inp
leak:Cblacs_gridmap
leak:blacs_gridmap_
# leaks related to PEXSI
leak:PPEXSIDFTDriver
# leaks in SuperLU
leak:symbfact_distributeMatrix
# leak due to compiler bug triggered by combination of OOP and ALLOCATABLE
leak:__dbcsr_tensor_types_MOD___copy_dbcsr_tensor_types_Dbcsr_tas_dist_t
leak:__dbcsr_tensor_types_MOD___copy_dbcsr_tensor_types_Dbcsr_tas_blk_size_t
EOF
cat << EOF >> ${INSTALLDIR}/tsan.supp
# tsan bugs likely related to gcc
# PR66756
deadlock:_gfortran_st_open
mutex:_gfortran_st_open
# bugs related to removing/filtering blocks in DBCSR.. to be fixed
race:__dbcsr_block_access_MOD_dbcsr_remove_block
race:__dbcsr_operations_MOD_dbcsr_filter_anytype
race:__dbcsr_transformations_MOD_dbcsr_make_untransposed_blocks
EOF

# need to also link to the .supp file in setup file
cat << EOF >> ${SETUPFILE}
export LSAN_OPTIONS=suppressions=${INSTALLDIR}/lsan.supp
export TSAN_OPTIONS=suppressions=${INSTALLDIR}/tsan.supp
EOF

load "${BUILDDIR}/setup_gcc"
write_toolchain_env "${INSTALLDIR}"

report_timing "gcc"