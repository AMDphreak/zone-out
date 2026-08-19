# Download the Public Suffix List into data/. Source of truth: https://publicsuffix.org/list/
$ErrorActionPreference = "Stop"
$dest = Join-Path $PSScriptRoot "..\data\public-suffix-list.dat"
$url = "https://publicsuffix.org/list/public_suffix_list.dat"
Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
Write-Host "Wrote $dest"
