#/bin/bash

PI_HOME=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

pkgs_dir=$PI_HOME
package_cfg_path=""
build_home=$(pwd)

install_global=no
install_prod=yes

# TODO: all global variable using PI_ as prefix, and to Capital

function print_help
{
    usage_text="Usage: $(basename "$0") [option] <package-cfg-path> -- Package Installer script
options:
    -h, --help                            Show this help text
    -c, --clean                           Clean all genererated files"

    echo "$usage_text"
}

function clean_all
{
    [ -d "$build_home/packages" ] && rm "$build_home/packages"
}

function main
{
    local _arg
    while [[ $# -ne 0 ]]
    do
        arg="$1"
        case "$arg" in
            -h|--help)
                print_help
                exit 0
                ;;
            -c|--clean)
                clean_all
                exit 0
                ;;
            -g|--only-global)
                install_global=yes
                install_prod=no
                ;;
            -p=*|--plugins-dir=*)
                _arg="$(echo $arg | sed 's/[-a-zA-Z0-9]*=//')"
                if [ ! -d "$_arg" ]; then
                    echo "\"$_arg\" not a directory"
                fi
                pkgs_dir="$(realpath $_arg)"
                ;;
            -d=*|--destination-dir=*)
                _arg="$(echo $arg | sed 's/[-a-zA-Z0-9]*=//')"
                if [ ! -d "$_arg" ]; then
                    echo "\"$_arg\" not a directory"
                fi
                build_home="$(realpath $_arg)"
                ;;
            *)
                if [ ! -f "$(realpath $arg)" ]; then
                    echo "\"$arg\" not found"
                    print_help
                    exit 1
                fi

                package_cfg_path="$(realpath $arg)"
                break
        esac
        shift
    done
}

main "$@"

if [ -z "$package_cfg_path" ]; then
    echo "package-cfg-path is required"
    print_help
    exit 1
fi

install_prefix="$build_home/packages" # this is default path for prefix. Let user can pass prefix from command line
packages=()
cflags=()
libs=()
ld_library_path=()
path=()

if [ ! -d "$install_prefix" ]; then
    mkdir $install_prefix
fi

. "$PI_HOME/install-pkg.sh"
. "$package_cfg_path"

echo $PKG_GLOBAL_DEPENDENCIES
echo $PKG_DEPENDENCIES

if [[ "$install_global" == "yes" ]]; then
    echo "Install global packages ..."

    if [ ! -z ${PKG_GLOBAL_DEPENDENCIES+x} ]; then

        if [ "$(id -u)" != "0" ]; then
            echo "Required root permission to install global packages" 1>&2
            exit 1
        fi

        apt-get install -y $PKG_GLOBAL_DEPENDENCIES
    fi

    [[ "$install_prod" == "no" ]] && exit 0
fi

if [ ! -z ${PKG_DEPENDENCIES+x} ]; then
    PKG_DEPENDENCIES=($PKG_DEPENDENCIES)
    install_package "${PKG_DEPENDENCIES[@]}"
fi

type post_install &>/dev/null && post_install

cat >"$install_prefix/.env" <<EOL
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH
export PACKAGES="${packages[@]}"
export LIBS="${libs[@]}"
export CFLAGS="${cflags[@]}"
export CXXFLAGS="${cflags[@]}"
export _OLD_VIRTUAL_PATH="\$PATH"
export PATH="$(join_by : ${path[@]}):\$PATH"
export _OLD_LD_LIBRARY_PATH="\$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$(join_by : ${ld_library_path[@]}):\$LD_LIBRARY_PATH"
EOL

cat >"$install_prefix/.deenv" <<EOL
if ! [ -z "\${_OLD_VIRTUAL_PATH+_}" ] ; then
    PATH="\$_OLD_VIRTUAL_PATH"
    export PATH
    unset _OLD_VIRTUAL_PATH
fi
EOL
