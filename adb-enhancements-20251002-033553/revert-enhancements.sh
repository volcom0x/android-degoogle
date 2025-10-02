#!/usr/bin/env bash
set -Eeuo pipefail
/home/matthew/.local/bin/adbx shell settings put global window_animation_scale 1.0
/home/matthew/.local/bin/adbx shell settings put global transition_animation_scale 1.0
/home/matthew/.local/bin/adbx shell settings delete global animator_duration_scale
/home/matthew/.local/bin/adbx shell settings delete global background_process_limit
/home/matthew/.local/bin/adbx shell device_config delete activity_manager max_cached_processes
/home/matthew/.local/bin/adbx cmd netpolicy set restrict-background false
false
false
false
/home/matthew/.local/bin/adbx cmd netpolicy remove restrict-background-blacklist 10383
/home/matthew/.local/bin/adbx cmd netpolicy remove restrict-background-blacklist 10306
/home/matthew/.local/bin/adbx cmd netpolicy remove restrict-background-blacklist 10345
/home/matthew/.local/bin/adbx shell settings delete global private_dns_mode
/home/matthew/.local/bin/adbx shell settings delete global private_dns_specifier
/home/matthew/.local/bin/adbx shell settings delete system peak_refresh_rate
/home/matthew/.local/bin/adbx shell settings delete system min_refresh_rate
/home/matthew/.local/bin/adbx shell settings delete global wifi_scan_throttle_enabled
/home/matthew/.local/bin/adbx shell cmd package compile --reset -a
/home/matthew/.local/bin/adbx shell cmd appops reset com.facebook.katana
/home/matthew/.local/bin/adbx shell cmd appops reset com.google.android.youtube
/home/matthew/.local/bin/adbx shell cmd appops reset com.google.android.gm
/home/matthew/.local/bin/adbx shell cmd appops reset com.linkedin.android
/home/matthew/.local/bin/adbx shell cmd appops reset com.whatsapp
/home/matthew/.local/bin/adbx shell cmd appops reset com.instagram.android
