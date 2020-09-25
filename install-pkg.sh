function fix_broken_symlinks
{
    local dir="$1"
    local _f

    for _f in $(find "$dir" -type l ! -exec test -e {} \; -print); do
        local target="$(readlink $_f)"
        if [ ! -f "$target" ]; then
            echo "Found broken symlinks $_f"

            local _new_targets=$(find "$dir" /lib /usr -name $(basename -- "$target"))
            local _new_target=(${_new_targets[@]})

            if [ ! -z "$_new_target" ]; then
                echo "Found new target $_new_target for $_f"
                rm "$_f"
                ln -s "$_new_target" "$_f"
            fi
        fi
    done
}

function join_by { local IFS="$1"; shift; echo "$*"; }

function contains_element
{
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

# array=("something to search for" "a string" "test2000")
# if contains_element "a string" "${array[@]}"; then
#     echo OK
# else
#     echo ERROR
# fi
# 
# if ! contains_element "blaha" "${array[@]}"; then
#     echo OK
# else
#     echo ERROR
# fi

function add_to_pkg_config_path
{
    local dir re

    for dir; do
        re="(^$dir:|:$dir:|:$dir$)"
        if ! [[ $PKG_CONFIG_PATH =~ $re ]]; then

            if [[ -z "$PKG_CONFIG_PATH" ]]; then
                export PKG_CONFIG_PATH=$dir
            else
                PKG_CONFIG_PATH=$PKG_CONFIG_PATH:$dir
            fi

        fi
    done
}

# $1 package name
function is_avail_package
{
    return $(apt-cache show $1 1> /dev/null 2>&1)
}

# if is_avail_package libc6; then
#     echo found libc6
# else
#     echo ERROR
# fi
# 
# if is_avail_package xx; then
#     echo ERROR
# else
#     echo not found xx
# fi

# $1 package name
function is_package_installed
{
    local pkg="$1"

    if contains_element "$pkg" "${packages[@]}"; then
        return 0    # installed
    fi

    if [ "" == "$(dpkg-query -W --showformat='${Status}\n' $pkg | grep 'install ok installed')" ]; then
        return 1    # not installed
    fi

    return 0        # installed
}

# if is_package_installed libc6; then
#     echo libc6 install
# else
#     echo ERROR
# fi
# 
# if is_package_installed libnl-3; then
#     echo ERROR
# else
#     echo libnl-3 was not installed
# fi

# $1 deb filepath
function query_package_depends
{
    local deb_path=$1
    local pkg_deps=()

    local depends=$(dpkg -I $deb_path | grep Depends:)
    depends=${depends/Depends:/}

    OIFS="$IFS"
    IFS=','
    read -ra depends <<< "${depends}"
    IFS="$OIFS"

    for dep_pkg in "${depends[@]}"; do

        OIFS="$IFS"
        IFS='|'
        read -ra dep_pkg <<< "${dep_pkg}"
        IFS="$OIFS"

        # get first package of multiple candidates
        dep_pkg=(${dep_pkg[@]})

        local pkg_name="$dep_pkg"

        if [[ $dep_pkg == *"("* ]]; then
            [[ $dep_pkg =~ ([^\(]*) ]] && pkg_name="${BASH_REMATCH[1]}"
        elif [[ $dep_pkg == *":"* ]]; then
            [[ $dep_pkg =~ ([^:]*) ]] && pkg_name="${BASH_REMATCH[1]}"
        fi

        if ! is_package_installed $pkg_name; then
            pkg_deps+=($pkg_name)
        fi

    done

    echo ${pkg_deps[@]}
}

#
# test by download deb file and get depends from it ....
#
# _pkg_deps=($(query_package_depends /mnt/e/packages/libhiredis-dev/libhiredis-dev_0.13.3-2.2_amd64.deb))
# for pkg in ${_pkg_deps[@]}; do
#     echo $pkg
# done
# 
# _pkg_deps=($(query_package_depends /mnt/e/doxygen_1.8.13-10_amd64.deb))
# for pkg in ${_pkg_deps[@]}; do
#     echo $pkg
# done
# 
# _pkg_deps=($(query_package_depends /mnt/e/fontconfig-config_2.12.6-0ubuntu2_all.deb))
# for pkg in ${_pkg_deps[@]}; do
#     echo $pkg
# done

# $1 package name
# $2 tmp folder for downloading deb file
function get_deb_filepath
{
    local pkg=$1
    local tmpdir="${2:-$(pwd)}"

    if ! ls $tmpdir/$pkg*.deb 1> /dev/null 2>&1; then
        return 0
    else
        echo $(ls $tmpdir/$pkg*.deb)
    fi
}

# deb_path=$(get_deb_filepath doxygen)
# echo $deb_path
# 
# no_path=$(get_deb_filepath xxx)
# echo $no_path

# $1 package name
# $2 tmp folder for downloading deb file
function download_package
{
    local pkg=$1
    local tmpdir="${2:-$(pwd)}"

    if ! is_avail_package $1; then
        return 0
    fi

    [ -d "${tmpdir}" ] || mkdir -p "${tmpdir}"

    cd "${tmpdir}"

    if ! ls $pkg*.deb 1> /dev/null 2>&1; then
        apt-get download $pkg
    fi

    cd -
}

# if ! download_package noavailpackage; then
#     echo not avail package
# fi
# 
# if download_package doxygen; then
#     echo download package doxygen
# fi

# $1 package name
# $2 install folder
# $3 download deb folder
function install_one_package
{
    local pkg=$1
    local install_pkg_prefix=$2/${pkg}
    local deb_tmp_dir=$3/${pkg}

    if ! is_avail_package $1; then
        return 0
    fi

    download_package $pkg "$deb_tmp_dir"

    local deb_path=$(get_deb_filepath $pkg "$deb_tmp_dir")
    local _pkg_deps=($(query_package_depends $deb_path))

    if [  ! -z "$_pkg_deps" ]; then
        echo "Find depends ${_pkg_deps[@]} for $pkg ...."

        for _pkg in ${_pkg_deps[@]}; do
            install_one_package $_pkg "$2" "$3"
        done
    else
        echo "No find any new depends need to install for $pkg"
    fi

    if is_package_installed "$pkg"; then
        return 0
    fi

    dpkg -x `ls $deb_tmp_dir/$pkg*.deb` $install_pkg_prefix

    if [ -f "$pkgs_dir/$pkg-post-deb-extract" ]; then
        $pkgs_dir/$pkg-post-deb-extract "$install_pkg_prefix"
    fi

    fix_broken_symlinks "$2"

    for _pkg_path in $(find $install_pkg_prefix -name *.pc); do
        if [ -f "$_pkg_path" ]; then
            pkg_dir=$(dirname "$_pkg_path")
            pkg_name=$(basename -- "$_pkg_path")
            pkg_name="${pkg_name%.*}"

            add_to_pkg_config_path "$pkg_dir"

            sed -i "s|^prefix=|prefix=${install_pkg_prefix}|g" "$_pkg_path"

            pkg_includes=$(pkg-config --cflags $pkg_name)

            for pkg_include in $pkg_includes
            do
                if [[ "$pkg_include" = -I* ]]; then
                    temp=${pkg_include:2}

                    if [ -d "$temp" ]; then
                        # echo "include folder exist: $temp"

                        cflags+=($pkg_include)
                    fi

                fi
            done

            # cflags+=($(pkg-config --cflags $pkg_name))
            libs+=($(pkg-config --libs $pkg_name))
        fi
    done

    if [ -d "$install_pkg_prefix/usr/bin" ]; then
        path+=("$install_pkg_prefix/usr/bin")
        PATH="$install_pkg_prefix/usr/bin":$PATH
    fi

    for _so_path in $(find $install_pkg_prefix -name *.so*); do
        if [ -f "$_so_path" ]; then
            ld_library_path+=($(dirname $_so_path))
            libs+=(-L$(dirname $_so_path))
            # TODO: also update LD_LIBRARY_PATH
        fi
    done

    packages+=($pkg)
}

# install_one_package noavailpackage
# install_one_package libhiredis-dev "$install_prefix" "$install_prefix"

function install_package
{
    local pkg

    for pkg in "$@"
    do
        echo $pkg installing ...
        install_one_package "$pkg" "$install_prefix" "$install_prefix"
    done
}
