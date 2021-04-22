#!/usr/bin/env bash
set -euo pipefail

slugify () {
    echo "$@" | iconv -c -t ascii//TRANSLIT | sed -E 's/[~^]+//g' | sed -E 's/[^a-zA-Z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | tr A-Z a-z
}

save_logs () {
        Slug=$(slugify $@);
        CurrDate=$(date +"%Y-%m-%d");
        DirName="${CurrDate}_${Slug}"
        mkdir $DirName
        echo "created $DirName copying logs"
        cp -a /var/data/log/. $DirName
        echo "Logs copied to $DirName"
}

save_logs $@;
