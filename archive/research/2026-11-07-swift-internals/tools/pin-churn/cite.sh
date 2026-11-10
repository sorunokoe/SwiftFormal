#!/bin/sh
# usage: cite.sh DIR REF PATH 'fixed string'  -> prints PATH:LINE@REF: text  (all matches)
DIR=$1; REF=$2; P=$3; S=$4
/usr/bin/grep -nF -- "$S" "$DIR/dl/$REF/$P" | while IFS= read -r l; do printf '%s:%s@%s\n' "$P" "$(printf '%s' "$l" | sed 's/^\([0-9]*\):\(.*\)$/\1: \2/' | sed 's/  */ /g')" "$REF"; done
