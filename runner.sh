#!/bin/bash
set -e pipefail

repo_directory="$(dirname "$(realpath "$0")")"

cache_folder="cache"
cache_folder="$repo_directory/$cache_folder"
mkdir -p "$cache_folder"

output_folder="results"
mkdir -p "$output_folder"
output_folder="$(realpath "$output_folder")/"

# gather system information
cores="$(grep /proc/cpuinfo -e "vendor_id" | wc -l)"
lscpu &> "$output_folder/lscpu_result.txt"
gcc -v &> "$output_folder/gcc_version.txt"

function download_external
{(
    filename="$cache_folder/$1"
    uri=$2
    sha256=$3

    if [ -e "$filename" ]; then
        echo "File $filename exists, skipping download"
    else
        wget -O "$filename" "$uri"
    fi

    if [[ "$(sha256sum $filename | awk '{print $1}')" != "$sha256" ]]; then
        >&2 echo "SHA256 sum mismatch on $filename - exiting"
    fi    
)}

function setup_dir
{
    # Setup and output directory
    # Call this from a subshell
    directory="$1"
    rm -rf "${output_folder}/${directory}"
    mkdir -p "$output_folder/${directory}"
    cd "$output_folder/${directory}"
}

function run_mmap_benchmark
{(
    setup_dir "mmap"
    
    gcc "$repo_directory/microbenchmark-mmap.c" -lpthread -o mmap

    enable_fbp=("x" "-f")
    enable_bys=("x" "-b")
    enable_pin=("x" "-p")

    base_param="-t $cores -d 4"

    for p1 in ${enable_fbp[@]}; do
    for p2 in ${enable_bys[@]}; do
    for p3 in ${enable_pin[@]}; do
    pstring="$p1 $p2 $p3"
    result="${pstring//x}"
    echo $result
    ./mmap $base_param $pstring
    done
    done
    done

    rm mmap
)}

function run_apache_benchmark
{(
    setup_dir "apache"

    download_external "httpd-2.4.69.tar.gz" "https://dlcdn.apache.org/httpd/httpd-2.4.69.tar.gz" "c551b9861e26f146f57e1b1765e69c89a60b3db0ec252ccab0d36283487016bb"
    (
    cd $cache_folder
    tar -xzf "httpd-2.4.69.tar.gz"
    cd "httpd-2.4.69"
    ./configure --prefix="$cache_folder/compiled"
    make -j $cores
    make install
    )

)}

#run_mmap_benchmark
run_apache_benchmark
