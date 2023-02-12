#!/bin/bash
for i in {1..50} ; do
    go test -race
    cd ../kvraft
    go test -race
    cd ../raft
done
