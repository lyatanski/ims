#!/bin/sh

if [ $# -eq 0 ] || [ "$1" = "-v" ] || [ "$1" = "--version" ]
then
    /opt/bin/open5gs-hssd -v
else
    /opt/bin/open5gs-$@
fi
