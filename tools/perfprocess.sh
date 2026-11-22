#!/bin/bash
# run in a folder with perf traces to automatically process them into readable svg graphics

mkdir -p processed
mkdir -p tmp

toprocess="$(ls *.data)"
for file in $toprocess; do
    echo Processing $file
    sudo perf script -f -i"$file" > "tmp/${file}.script"
    cat "tmp/${file}.script" | stackcollapse-perf.pl > "tmp/${file}.folded"
    flamegraph.pl "tmp/${file}.folded" > "processed/${file}.svg"
done

rm -rf tmp
