#!/bin/bash

# usage: ./benchmark.sh [--smokewagon on|off] [--duration 10s] [--min-cores 1] [--max-cores 56] [--hey-cores 7] [--concurrency 50]
# smokewagon on (default): the smokewagon httpd runs, and the unmodified one is labelled "inactive"
# smokewagon off: only the unmodified httpd runs, labelled "baseline"
# apache runs on cores 1..N for each N from min-cores to max-cores
# hey runs on the last hey-cores cores of the machine (e.g. 57-63 on 64 cores)
# concurrency is the number of concurrent workers hey uses (hey's -c)
SMOKEWAGON=on
DURATION=10s
MIN_CORES=1
MAX_CORES=56
HEY_CORES=7
CONCURRENCY=50

while [[ $# -gt 0 ]]; do
    if [[ $# -lt 2 ]]; then
        echo "missing value for $1" >&2
        exit 1
    fi
    case $1 in
        --smokewagon)  SMOKEWAGON=$2;  shift 2 ;;
        --duration)    DURATION=$2;    shift 2 ;;
        --min-cores)   MIN_CORES=$2;   shift 2 ;;
        --max-cores)   MAX_CORES=$2;   shift 2 ;;
        --hey-cores)   HEY_CORES=$2;   shift 2 ;;
        --concurrency) CONCURRENCY=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ $SMOKEWAGON != on && $SMOKEWAGON != off ]]; then
    echo "--smokewagon must be on or off" >&2
    exit 1
fi

if (( MIN_CORES < 1 || MIN_CORES > MAX_CORES )); then
    echo "--min-cores must be between 1 and --max-cores ($MAX_CORES)" >&2
    exit 1
fi

# make sure apache's and hey's cores don't overlap (core 0 is left unused)
TOTAL_CORES=$(nproc)
if (( MAX_CORES + HEY_CORES >= TOTAL_CORES )); then
    echo "need $((MAX_CORES + HEY_CORES + 1)) cores but this machine has $TOTAL_CORES" >&2
    exit 1
fi

# the cores hey is pinned to: the last HEY_CORES cores, e.g. 57-63
HEY_RANGE=$((TOTAL_CORES - HEY_CORES))-$((TOTAL_CORES - 1))

# what the unmodified httpd is called in logs and filenames
if [[ $SMOKEWAGON == on ]]; then
    BASELINE_NAME=inactive
else
    BASELINE_NAME=baseline
fi

HEY=/home/milkv/go/bin/hey
RESULTS=/home/milkv/sophgo/smokewagon-benchmarks/apache/results
URL=http://localhost/index.html

# error log lines that are normal and should be ignored (separated by |)
IGNORE='resuming normal operations|Command line:|shutting down'

BASELINE_HTTPD=/opt/smokewagon/httpd/bin/httpd
BASELINE_CONF=/home/milkv/sophgo/smokewagon-benchmarks/apache/httpd.conf
BASELINE_ERRLOG=/opt/smokewagon/httpd/logs/error_log

SMOKEWAGON_HTTPD=/opt/smokewagon/httpd-smokewagon/bin/httpd
SMOKEWAGON_CONF=/home/milkv/sophgo/smokewagon-benchmarks/apache/httpd-smokewagon.conf
SMOKEWAGON_ERRLOG=/opt/smokewagon/httpd-smokewagon/logs/error_log

# usage: run_benchmark <name> <httpd binary> <config file> <error log> <cores>
run_benchmark() {
    name=$1
    httpd=$2
    conf=$3
    errlog=$4
    cores=$5

    # the cores apache is pinned to, e.g. 1-5
    apache_range=1-$cores

    # start each run with an empty error log
    sudo truncate -s 0 $errlog

    echo "[$name] starting apache with $cores core(s) (cores $apache_range)"
    sudo taskset -c $apache_range $httpd -k start -f $conf

    echo "[$name] waiting for apache to listen"
    deadline=$((SECONDS + 30))
    until ss -ltn | grep -q ':80 '; do
        if (( SECONDS >= deadline )); then
            echo "[$name] apache never started listening, giving up" >&2
            exit 1
        fi
        sleep 0.5
    done

    echo "[$name] hey with $HEY_CORES core(s) (cores $HEY_RANGE), concurrency $CONCURRENCY"
    out=$RESULTS/hey-output-$name-$(printf '%02d' "$cores")-$(printf '%02d' "$HEY_CORES")-$(printf '%03d' "$CONCURRENCY").txt
    taskset -c $HEY_RANGE $HEY -c $CONCURRENCY -disable-keepalive -z $DURATION $URL > $out
    echo "[$name] $(grep 'Requests/sec' $out)"

    echo "[$name] shutting down apache"
    sudo $httpd -k graceful-stop -f $conf

    echo "[$name] waiting for process and port to be freed"
    while pgrep -x httpd >/dev/null; do
        sleep 0.5
    done

    while ss -ltn | grep -q ':80 '; do
        sleep 0.5
    done

    # show anything in the error log that isn't a routine startup/shutdown line
    unexpected=$(sudo grep -v -E "$IGNORE" $errlog)
    if [[ -n "$unexpected" ]]; then
        echo "[$name] unexpected lines in apache error log:" >&2
        echo "$unexpected" >&2
        exit 1
    fi
}

for i in $(seq $MIN_CORES $MAX_CORES)
do
    run_benchmark $BASELINE_NAME $BASELINE_HTTPD $BASELINE_CONF $BASELINE_ERRLOG $i
    if [[ $SMOKEWAGON == on ]]; then
        run_benchmark smokewagon $SMOKEWAGON_HTTPD $SMOKEWAGON_CONF $SMOKEWAGON_ERRLOG $i
    fi
done
