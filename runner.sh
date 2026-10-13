#!/bin/bash

enable_fbp=("x" "-f")
enable_bys=("x" "-b")
enable_pin=("x" "-p")

base_param="-t 32 -d 4"

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
