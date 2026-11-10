#!/bin/sh
# usage: cite-batch.sh DIR QUERIES  (QUERIES lines: REF|PATH|fixed string) -> PATH:LINE@REF: text
DIR=$1
while IFS='|' read -r REF P S; do
  [ -z "$REF" ] && continue
  out=$(/usr/bin/grep -nF -- "$S" "$DIR/dl/$REF/$P" | head -3)
  [ -z "$out" ] && { echo "NOTFOUND $REF $P [$S]"; continue; }
  printf '%s\n' "$out" | while IFS= read -r l; do n=${l%%:*}; t=$(printf '%s' "${l#*:}" | sed 's/^ *//'); echo "$P:$n@$REF: $t"; done
done < "$2"
