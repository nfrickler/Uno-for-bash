#!/bin/bash

while true; do
	echo "Start new server..."
	./uno_server.pl $@
	sleep 2
done
