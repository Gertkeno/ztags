#!/bin/sh
#generated by ztags
if [ -z "$1" ]; then
	echo "usage $0 FILE(s)"
else
	echo '!_TAG_FILE_SORTED	1' > tags && {s} $@ | LC_ALL=C sort >> tags
fi
