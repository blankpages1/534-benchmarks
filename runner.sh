#!/bin/bash
set -e pipefail

repo_directory="$(dirname "$(realpath "$0")")"

cache_folder="cache"
cache_folder="$repo_directory/$cache_folder"
mkdir -p "$cache_folder"
export PATH="$cache_folder/compiled/bin:$PATH"
export LD_LIBRARY_PATH="$cache_folder/compiled/lib:$LD_LIBRARY_PATH"

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

function download_git
{(
    repo="$1"
    branch="$2"
    filename="$3"
    
    cd "$cache_folder"
    if [ -d "$filename" ]; then
        echo "Repo $repo already exists, skipping download"
    else
        git clone "$repo" -b "$branch" "$filename"
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
    download_external "apr-1.7.6.tar.gz" "https://dlcdn.apache.org//apr/apr-1.7.6.tar.gz" "6a10e7f7430510600af25fabf466e1df61aaae910bf1dc5d10c44a4433ccc81d"
    download_external "apr-util-1.6.6.tar.gz" "https://dlcdn.apache.org//apr/apr-util-1.6.6.tar.gz" "acd5f38440eda830e40c4fe35c2a6b8119493cfdba9c9d73d985c317beb4e4f8"
    download_git "https://github.com/PCRE2Project/pcre2.git" "pcre2-10.48" "pcre2"

    if [[ ! -e "$repo_directory/cache/compiled/bin/httpd" ]]; then
    (
    cd $cache_folder
    tar -xzf "httpd-2.4.69.tar.gz"
    tar -xzf "apr-1.7.6.tar.gz"
    tar -xzf "apr-util-1.6.6.tar.gz"

    cp -r "apr-1.7.6" "httpd-2.4.69/srclib/apr"
    cp -r "apr-util-1.6.6" "httpd-2.4.69/srclib/apr-util"

    cd "pcre2"
    git submodule update --init
    ./configure --prefix="$cache_folder/compiled"
    make -j $cores
    make install
    cd -    

    cd "httpd-2.4.69"
    ./configure --prefix="$cache_folder/compiled"
    make -j $cores
    make install
    cd -
    )
    fi

    timeout="30"
    ab_cores="6"
    ab_concurrency="20"
    ab_time="10"
    max_apache_cores="$(expr "$cores" - "$ab_cores")"

    rm -f apache_results.txt
    for ((i=1;i<"$max_apache_cores";i++)); do
        echo "Testing apache with $i cores" | tee -a apache_results.txt
        taskset -c "0-$i" httpd -f "$repo_directory/apache/httpd.conf"
        # Wait for httpd to start
        deadline=$((SECONDS + 30))
        until ss -ltn | grep -q ':8080 '; do
            if (( SECONDS >= deadline )); then
                >&2 echo "httpd never started listening, giving up"
                httpd -f "$repo_directory/apache/httpd.conf" -k graceful-stop
                exit 1
            fi
            sleep 0.5
        done

        taskset -c "$max_apache_cores-$(expr "$cores" - 1)" ab -c "$ab_concurrency" -s "$timeout" -t "$ab_time" -n 1000000 http://localhost:8080/ | tee -a apache_results.txt

        # Shutdown httpd
        httpd -f "$repo_directory/apache/httpd.conf" -k graceful-stop
        while pgrep -x httpd >/dev/null; do
            sleep 0.5
        done
        while ss -ltn | grep -q ':80 '; do
            sleep 0.5
        done
    done
)}

#run_mmap_benchmark
run_apache_benchmark
