#!/bin/sh
. /lib/wifi/platform_dependent.sh
if [[ "$1" != "" && "$2" != "" && "$3" != "" ]]; then
        down_time_min=$3
        down_time_sec=$((down_time_min*60))
        radio=$1
        radio_num=${radio: -1}
        sleep $2
        if [ "$OS_NAME" == "UPDK" ]; then
                ret=`ubus-cli "$radio.Enable=0"`
                sleep $down_time_sec
                ret=`ubus-cli "$radio.Enable=1"`
        else
                wifi down radio$radio_num
                sleep $down_time_sec
                wifi up radio$radio_num
        fi
else
        echo "ERROR: Bad input: wlan=$1; down after=$2 seconds; for=$3 minutes"
fi
