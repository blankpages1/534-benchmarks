#!/bin/bash
useperf="$1"
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
cores="$(cat /proc/cpuinfo | grep -e processor | wc -l)"
arch="$(uname -m)"
user="$(whoami)"

lscpu &> "$output_folder/lscpu_result.txt"
gcc -v &> "$output_folder/gcc_version.txt"
uname -a &> "$output_folder/kernel_version.txt"

function download_external
{(
    filename="$cache_folder/$1"
    uri=$2
    sha256=$3

    echo "Downloading $uri"
    if [ -e "$filename" ]; then
        echo "File $filename exists, skipping download"
    else
        wget -O "$filename" "$uri"
    fi
    
    if [[ "$(sha256sum $filename | awk '{print $1}')" != "$sha256" ]]; then
        >&2 echo "SHA256 sum mismatch on $filename - exiting"
        exit 1
    fi
)}

function download_git
{(
    repo="$1"
    branch="$2"
    filename="$3"
    
    cd "$cache_folder"
    if [[ ! -d "$filename" ]]; then
        git clone "$repo" -b "$branch" "$filename"
    else
        echo "Skipping repo download"
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

function install_tests
{(
    download_external "httpd-2.4.70.tar.gz" "https://archive.apache.org/dist/httpd/httpd-2.4.70.tar.gz" "e0cc26ab60a024db2b4a9b219ce6e1538fe2d3138ece2156d2834c63ae21913d"
    download_external "apr-1.7.6.tar.gz" "https://dlcdn.apache.org//apr/apr-1.7.6.tar.gz" "6a10e7f7430510600af25fabf466e1df61aaae910bf1dc5d10c44a4433ccc81d"
    download_external "apr-util-1.6.6.tar.gz" "https://dlcdn.apache.org//apr/apr-util-1.6.6.tar.gz" "acd5f38440eda830e40c4fe35c2a6b8119493cfdba9c9d73d985c317beb4e4f8"
    download_git "https://github.com/PCRE2Project/pcre2.git" "pcre2-10.48" "pcre2"
    

    download_external "go1.27.3.linux-amd64.tar.gz" "https://go.dev/dl/go1.27.3.linux-amd64.tar.gz" "65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40"
    download_external "go1.27.3.linux-arm64.tar.gz" "https://go.dev/dl/go1.27.3.linux-arm64.tar.gz" "a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49"
    download_external "go1.27.3.linux-riscv64.tar.gz" "https://go.dev/dl/go1.27.3.linux-riscv64.tar.gz" "41fe171fb7fcf5574cba7d874c2732dca9161ce2dba631d754371951df9ea310"
    download_git "https://github.com/rakyll/hey.git" "v0.1.5" "hey"

    download_git "https://git.ffmpeg.org/ffmpeg.git" "release/9.1" "ffmpeg"

    if [[ ! -e "$repo_directory/cache/compiled/bin/httpd" ]]; then
    (
    cd $cache_folder
    
    echo "Unpacking httpd"
    tar -xzf "httpd-2.4.70.tar.gz"
    echo "Unpacking apr"
    tar -xzf "apr-1.7.6.tar.gz"
    echo "Unpacking apr-util"
    tar -xzf "apr-util-1.6.6.tar.gz"

    cp -r "apr-1.7.6" "httpd-2.4.70/srclib/apr"
    cp -r "apr-util-1.6.6" "httpd-2.4.70/srclib/apr-util"

    cd "pcre2"
    git submodule update --init
    ./configure --prefix="$cache_folder/compiled"
    make -j $cores
    make install -j "$cores"
    cd -

    cd "httpd-2.4.70"
    ./configure --prefix="$cache_folder/compiled"
    make -j $cores
    make install -j "$cores"
    cd -
    
    # build hey
    echo "Unpack go for $(uname -m)"
    case "$arch" in
    "x86_64")
        tar -xzf "go1.27.3.linux-amd64.tar.gz"
        ;;
    "aarch64")
        tar -xvf "go1.27.3.linux-arm64.tar.gz"
        ;;
    "riscv64")
        tar -xvf "go1.27.3.linux-riscv64.tar.gz"
        ;;
    *)
        >&2 echo "Unknown archiecture for go"
        exit 1
        ;;    
    esac
    CGO_ENABLED=0 go/bin/go build -C ./hey -a
    )
    fi
)}

function tlb_interrupts
{(
    target_file="$1"

    case "$arch" in
    "x86_64")
        cat /proc/interrupts | grep TLB | sed -e 's/[^0-9]/ /g' -e 's/^ *//g' -e 's/ *$//g' | tr -s ' ' >> "$target_file"
        ;;
    *)
        ;;
    esac
)}

function run_mmap_benchmark
{(
    setup_dir "mmap"
    
    gcc "$repo_directory/microbenchmark-mmap.c" -lpthread -o mmap

    enable_fbp=("x" "-f")
    #enable_bys=("x" "-b")
    enable_pin=("x" "-p")

    duration="10"
    base_param="-d $duration"

    # record data for core and parameter sweep
    for p1 in ${enable_fbp[@]}; do
    #for p2 in ${enable_bys[@]}; do
    for p3 in ${enable_pin[@]}; do
    pstring="$p1 $p3"
    result="${pstring//x}"
    echo $result
    
    for cen in $(seq 1 $cores); do
        tlb_interrupts "${p1}${p3}_shootdowns.txt"
        ./mmap -t $cen -m $cen $base_param $pstring
        tlb_interrupts "${p1}${p3}_shootdowns.txt"
    done

    done
    #done
    done

    # record perf for a core sweep on the "best" configurations
    if [[ "$useperf" == "true" ]]; then
    mkdir -p perf
    cd perf
    for cen in $(seq 1 $cores); do
        sudo perf record -ag -F 2000 -o"perf_$cen.data" ../mmap -t $cen -m $cen $base_param "-f"
    done
    cd -
    fi

    rm mmap
)}

function run_apache_benchmark
{(
    setup_dir "apache"

    timeout="30"
    ab_cores="8"
    ab_concurrency="50"
    ab_time="10"
    max_apache_cores="$(expr "$cores" - "$ab_cores")"

    rm -f apache_results.txt
    for ((i=0;i<"$max_apache_cores";i++)); do
        echo "Testing apache with $(expr "$i" + 1) cores" | tee -a apache_results.txt
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

        tlb_interrupts "shootdowns.txt"
        (taskset -c "$max_apache_cores-$(expr "$cores" - 1)" "$cache_folder/hey/hey" -t "$timeout" -z "${ab_time}s" -c "$ab_concurrency" "http://localhost:8080/") | tee -a apache_results.txt
        tlb_interrupts "shootdowns.txt"

        if [[ "$useperf" == "true" ]]; then
        mkdir -p perf
        cd perf
        sudo perf record -ag -F 2000 -o"perf_$i.data" sudo -u "$user" bash -c "(taskset -c "$max_apache_cores-$(expr "$cores" - 1)" "$cache_folder/hey/hey" -t "$timeout" -z "${ab_time}s" -c "$ab_concurrency" "http://localhost:8080/") | tee -a apache_results.txt"
        cd -
        fi

        # Shutdown httpd
        httpd -f "$repo_directory/apache/httpd.conf" -k graceful-stop
        while pgrep -x httpd >/dev/null; do
            sleep 0.5
        done
        while ss -ltn | grep -q ':80 '; do
            sleep 0.5
        done
    done

    echo "cores,req_per_sec" > apache_results.csv
    cat apache_results.txt | grep "Requests/" | awk '{print i++ "," $2}' >> apache_results.csv
)}

function run_gcc_benchmark
{(
    setup_dir "gccbench"

    gcc "$repo_directory/microbenchmark-stress.c" -lpthread -o stress

    itterations=2
    threads="$(expr $cores / 8) $(expr $cores / 4) $(expr $cores / 2) $(expr $cores)"
    
    cp -r "$cache_folder/ffmpeg" .
    cd ffmpeg
    git clean -fxd
    ./configure --disable-x86asm

    for threadct in $threads; do
        # baseline
        for i in $(seq 1 $itterations); do
            make clean
            echo "Building FFMPEG $i/$itterations"
            (export TIMEFORMAT='%R'; time make -j "$threadct" &>/dev/null) 2>> "../baseline_${threadct}.csv"
        done

        # spin
        for i in $(seq 1 $itterations); do
            make clean
            echo "Building FFMPEG $i/$itterations"
            ../stress -p -t $threadct &
            (export TIMEFORMAT='%R'; time make -j "$threadct" &>/dev/null) 2>> "../spin_${threadct}.csv"
            kill $(jobs -p)
        done

        # TLB thrashing
        for i in $(seq 1 $itterations); do
            make clean
            echo "Building FFMPEG $i/$itterations"
            ../stress -t $threadct &
            tlb_interrupts "../shootdowns_${threadct}.txt"
            (export TIMEFORMAT='%R'; time make -j "$threadct" &>/dev/null) 2>> "../stress_${threadct}.csv"
            kill $(jobs -p)
            tlb_interrupts "../shootdowns_${threadct}.txt"
        done
    done

    cd ..
    rm -rf ffmpeg
)}

function run_sem_benchmark
{(
    setup_dir sem
    gcc "$repo_directory/microbenchmark-sem.c" -lpthread -o sem
    
    loop_targets="100 1000 5000"
    duration=10    

    for lt in $loop_targets; do
    echo Semaphore test with $lt idle loops
    for cen in $(seq 1 $cores); do
        ./sem -t $cen -d $duration -b $lt | tee -a results.csv
    done
    done
    rm sem
)}

install_tests

#run_mmap_benchmark
#run_apache_benchmark
#run_gcc_benchmark
run_sem_benchmark
