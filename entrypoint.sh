#!/bin/ash
# Entrypoint standar Pterodactyl: baca variabel STARTUP lalu jalankan.
cd /home/container || exit 1

TZ="${TZ:-UTC}"
export TZ

INTERNAL_IP="$(ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}')"
export INTERNAL_IP

MODIFIED_STARTUP="$(echo -e ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')"
echo ":/home/container$ ${MODIFIED_STARTUP}"

eval ${MODIFIED_STARTUP}
