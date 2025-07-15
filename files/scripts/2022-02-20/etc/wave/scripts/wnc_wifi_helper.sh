#!/bin/sh
source /opt/intel/wave/scripts/wnc_wifi_util.sh

# MxL helper script to run dut_cli commands

# Globals
rx_measure_running=0
rx_per_endless_loop=0

# Run dut_cli and put the radios in DUT_MODE
# args: none
init_dut_mode()
{
	# Check if dut_cli already running, if not run it and initialize all the bands to DUT mode
	if ! pgrep -x "dut_cli" > /dev/null
		then
			iw dev wlan4 iwlwav gEEPROM | grep "EEPROM type   : GPIO"
			if [ $? -eq 0 ]; then
				mem_type=1
				mem_size=2048
			else
				iw dev wlan4 iwlwav gEEPROM | grep "EEPROM type   : FILE"
				if [ $? -eq 0 ]; then
					mem_type=2
					mem_size=2048
				else
					echo "EEPROM or FLASH doesn't contain calibration data"
					exit 1
				fi
			fi

			echo "Stopping dut server mode"
			/opt/intel/wave/scripts/load_dut.sh stop
			echo "Starting dut server mode"
			/opt/intel/wave/scripts/load_dut.sh start

			# wait until dutserver started
			while true
			do
				if  pgrep -x "dutserver" > /dev/null
				then
					break;
				else
					sleep 0.01
				fi
			done

			echo "Run DUT"
			echo "" > /tmp/dut_log
			echo "" > /tmp/dut_commands.txt

			# Get Current br-lan IP address and run dut_cli
			local ip_addr=$(ifconfig br-lan | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')
			tail -f -s0 /tmp/dut_commands.txt | dut_cli -l 4 -a $ip_addr >> /tmp/dut_log &

			# Wait for prompt
			util_wait_for_prompt "/tmp/dut_log"
			for band in 0 2 4; do
				echo "Initialize DUT band $band"
				dut_send_command "exec $band driverInit --memory-type $mem_type --memory-size $mem_size"
			done
	fi
}

dut_print_version()
{
	local wlan_version=$(grep 'wave_release_minor' /etc/wave_components.ver | cut -d '"' -f 2 | xargs)
	local progmodel_version=$(grep 'wave700B_progmodel_ver' /etc/wave_components.ver | cut -d '"' -f 2 | xargs)
	local psd_version=$(grep 'wave700B_progmodel_ver' /etc/wave_components.ver | cut -d '"' -f 2 | xargs)
	local regulatory_version=$(grep 'wave_regulatory_ver' /etc/wave_components.ver | cut -d '"' -f 2 | xargs)
	local eeprom_version=$(grep 'EEPROM version' /proc/net/mtlk/wlan0/eeprom_parsed | cut -d ':' -f 2 | xargs)
	local hw_id=$(grep 'HW ID' /proc/net/mtlk/wlan0/eeprom_parsed | cut -d ':' -f 2 | xargs)
	local hw_type=$(grep 'HW type' /proc/net/mtlk/wlan0/eeprom_parsed | cut -d ':' -f 2 | xargs)
	local hw_revision=$(grep 'HW revision' /proc/net/mtlk/wlan0/eeprom_parsed | cut -d ':' -f 2 | xargs)

	printInfo "================================="
	printInfo "MXL Helper script version $version"
	printInfo "================================="
	printInfo "WLAN version: $wlan_version"
	printInfo "================================="
	printInfo "PROGMODEL version: $progmodel_version"
	printInfo "================================="
	printInfo "PSD version: $psd_version"
	printInfo "================================="
	printInfo "REGULATORY version: $regulatory_version"
	printInfo "================================="
	printInfo "EEPROM version: $eeprom_version"
	printInfo "================================="
	printInfo "HW ID: $hw_id"
	printInfo "================================="
	printInfo "HW type: $hw_type"
	printInfo "================================="
	printInfo "HW revision: $hw_revision"
	printInfo "================================="
}

#Helper function to Wi-Fi radio up
dut_wifi_radio_up()
{
	util_manage_wifi_radio "true" $@
}

#Helper function to Wi-Fi radio down
dut_wifi_radio_down()
{
	util_manage_wifi_radio "false" $@
}

#Helper function to terminate Wi-Fi driver
dut_wifi_terminate()
{
	killall -9 dut_cli
	local wifi_drv_status=$(util_check_wifi_driver_status)
	if [ "$wifi_drv_status" == "false" ]; then
		printInfo "Wifi Driver is already de-installed"
		exit 1
	else
		rmmod mtlk
		wifi_drv_status=$(util_check_wifi_driver_status)
	fi

	if [ "$wifi_drv_status" == "false" ]; then
		printInfo "Wifi Driver is de-installed"
	fi
}

#Helper function to init Wi-Fi
dut_wifi_init()
{
	local dut_mode
	local wifi_drv_status=$(util_check_wifi_driver_status)
	if [ "$wifi_drv_status" == "false" ]; then
		util_init_wifi_driver
		wifi_drv_status=$(util_check_wifi_driver_status)
	fi

	if pgrep -x "dut_cli"
        then
                dut_mode="true"
        else
                dut_mode="false"
        fi

	if [ "$wifi_drv_status" == "true" ]; then
		printInfo "Wifi Driver is up and Ready"
		if [ "$dut_mode" == "false" ]; then
			util_check_radio_status "true"
		else
			ifaces="wlan0 wlan2 wlan4"
			for iface in $ifaces; do
				util_check_iface_present $iface
			done
		fi
	else
		printInfo "ERROR: Wifi Driver is not running"
	fi

	dut_print_version

	printInfo "================================="

	if [ "$dut_mode" == "true" ]; then
		printInfo "Operation Mode : Test Mode"
	else
		printInfo "Operation Mode : AP Mode"
	fi

	printInfo "================================="
}

# Helper func to start Tx
# args: <radio band> <channel> <bandwidth> <power> <antenna selection> <number of spatial streams (NSS)>
#					<Interframe Space ( IFS )> <PSDU Size>  <Protocol> <MCS Index> <Number of Frames to Send> [<RU size> <RU location>]
dut_start_tx()
{
	# Check number of parameters are enough
	if [ "$#" -lt 11 ]; then
		echo "Illegal number of parameters"
	fi

	# Initialize dut mode
	init_dut_mode

	local band
	local lowestchannel
	local bw
	local power
	local ant_mask
	local nss=$6
	local ifs=$7
	local psdulen=$8
	local phymode=$9
	local mcs=${10}
	local repetition=${11}
	local rusize=${12}
	local rulocation=${13}
	local isfreq # Flag to indicate if channel is a frequency
	local centerchannel
	local num_antenna
	local gi=0
	local ltf=1
	local ruParams
	local userOneRu
	local userTwoRu

	band=$(util_extract_band $1) || { echo "$band"; exit 1; }
	phymode=$(util_extract_phymode $9 $band) || { echo "$phymode"; exit 1; }
	isfreq=$(util_check_if_frequency $2)

	if [ "$isfreq" -eq 1 ]; then
		util_validate_frequency $band $2
		# Convert center frequency to center channel
		centerchannel=$(util_convert_centerfreq_to_centerchannel $band $2) || { echo "$centerchannel"; exit 1; }
	else
		# If it is channel number, no conversion needed
		centerchannel=$2
	fi

	#extract bandwidth
	bw=$(util_extract_bw $3 $centerchannel $band) || { echo "$bw"; exit 1; }
	if [ "$3" != "-" ]; then
		#validate center channel and bandwidth if bw option is not hypen(-)
		util_validate_center_channel_and_bandwidth $centerchannel $bw $band $phymode
	fi

	if [[ $9 == "n" || $9 == "ac" ]]; then
		gi=0 # 0.8us
		ltf=0 # short
	elif [[ $9 == "ax" || $9 == "be" ]]; then
		gi=3 # 3.2us
		ltf=2 # long
	fi

	lowestchannel=$(util_calculate_lowest_channel $band $bw $centerchannel) || { echo "$lowestchannel"; exit 1; }
	power=$(util_extract_powerval $4) || { echo "$power"; exit 1; }
	ant_mask=$(util_check_ant_mask $5) || { echo "$ant_mask"; exit 1; }
	mcs=$(util_get_mcs_value $mcs $phymode) || { echo "$mcs"; exit 1; }
	ruParams=$(util_calculate_ru_params $phymode $bw $rusize $rulocation) || { echo "$ruParams"; exit 1; }

	userOneRu=$(echo $ruParams | awk '{print $1}')
	userTwoRu=$(echo $ruParams | awk '{print $2}')

	# If the numer of antenna is more than the number of SS then set nss to 1.
	num_antenna=$(util_count_bits_set $ant_mask)
	if [ $(awk -v antval=$num_antenna -v nssval=$nss 'BEGIN { print (antval > nssval)}') -eq 1 ]; then
		printInfo "Num Antenna is more then num nss"
		nss=1
	fi

	if [ $(awk -v antval=$num_antenna -v nssval=$nss 'BEGIN { print (antval < nssval)}') -eq 1 ]; then
		printInfo "WARNING: Number of antenna is less than number of spatial streams configured"
	fi

	if [ $repetition -eq 0 ]; then
		repetition=65535	# Continuous transmission
	fi

	printInfo "channel is $1GHz[$2/$3]"
	printInfo "Confirmed band: $1G"
	printInfo "Confirmed protocol:$9"
	printInfo "Confirmed bandwidth:$3"
	printInfo "Confirmed antsel: $ant_mask"
	printInfo "The ant_sel[$ant_mask] supports up to $num_antenna[NSS]"
	printInfo "Confirmed nss:$nss"
	printInfo "Confirmed power:$(($power / $2))"
	printInfo "Confirmed mcs:$mcs"
	printInfo "Confirmed ifs:$ifs"
	printInfo "Confirmed psdu size:$psdulen"
	printInfo "Confirmed userOneRu:$userOneRu"
	printInfo "Confirmed userTwoRu:$userTwoRu"

	dut_send_command "exec $band setChannel --bandwidth $bw --channel $lowestchannel --phy-mode $phymode"
	dut_send_command "exec $band setRate --bandwidth $bw --mcs $mcs --nss $nss --gi $gi --ltf $ltf"
	dut_send_command "exec $band setTransmitPowerLevel --power-level $power"
	dut_send_command "exec $band setEnabledTxAntennaMask --antenna-mask $ant_mask"
	dut_send_command "exec $band setIfs --ifs $ifs"
	dut_send_command "exec $band setRuParams --user-one $userOneRu --user-two $userTwoRu"
	dut_send_command "exec $band startTx --repetitions $repetition --packet-length $psdulen"
}

# Stop Tx Mode
# args: <radio band>
dut_stop_tx()
{
	local band

	# Initialize dut mode
	init_dut_mode

	if [ "$#" -lt 1 ]; then
		for band in 0 2 4; do
			dut_send_command "exec $band stopTx"
			printInfo "TX Mode stopped for $band"
		done
		exit 0
	fi

	band=$(util_extract_band $1) || { echo "$band"; exit 1; }

	dut_send_command "exec $band stopTx"
}


# DUT start CW transmission
# args: <radio band> <channel> <antennas> <power> <offset>
dut_start_cw()
{
	if [ "$#" -lt 4 ]; then
		echo "Illegal number of parameters"
	fi

	# Initialize dut mode
	init_dut_mode

	local band
	local lowestchannel
	local ant_mask=$3
	local power=$4
	local offset=$5		#Note: not used for now
	local isfreq # Flag to indicate if channel is a frequency
	local centerchannel
	local bw="-" #Bandwidth (BW) is not specified. The appropriate bandwidth will be determined based on the center channel by passing a hyphen for the bandwidth.

	band=$(util_extract_band $1) || { echo "$band"; exit 1; }
	isfreq=$(util_check_if_frequency $2)

	if [ "$isfreq" -eq 1 ]; then
		util_validate_frequency $band $2
		# Convert center frequency to center channel
		centerchannel=$(util_convert_centerfreq_to_centerchannel $band $2) || { echo "$centerchannel"; exit 1; }
	else
		# If it is channel number, no conversion needed
		centerchannel=$2
	fi

	bw=$(util_extract_bw $bw $centerchannel $band) || { echo "$bw"; exit 1; }
	lowestchannel=$(util_calculate_lowest_channel $band $bw $centerchannel) || { echo "$lowestchannel"; exit 1; }
	power=$(util_extract_powerval $4) || { echo "$power"; exit 1; }
	ant_mask=$(util_check_ant_mask $3) || { echo "$ant_mask"; exit 1; }

	printInfo "channel is $1GHz[$2/$3]"
	printInfo "Confirmed band: $1G"
	printInfo "Confirmed power:$(($power / $2))"
	printInfo "Confirmed antsel: $ant_mask"
	dut_send_command "exec $band setChannel --bandwidth $bw --channel $lowestchannel"
	dut_send_command "exec $band setEnabledTxAntennaMask --antenna-mask $ant_mask"
	dut_send_command "exec $band setTransmitPowerLevel --power-level $power"
	printInfo "The minimum offset supported value is 312.5 kHz. The offset is determined by multiplying 312.5 kHz
	by the given offset value $offset.The final offset frequency is $(awk 'BEGIN {print 312.5 * '$offset'}') kHz."
	dut_send_command "exec $band startCw --tone $offset"
}

# Stop CW wave transmission
# args: <radio band>
dut_stop_cw()
{
	local band

	# Initialize dut mode
	init_dut_mode

	if [ "$#" -lt 1 ]; then
		for band in 0 2 4; do
			dut_send_command "exec $band stopCw"
			printInfo "CW stopped for band $band"
		done
		exit 0
	fi

	band=$(util_extract_band $1) || { echo "$band"; exit 1; }

	dut_send_command "exec $band stopCw"
}

dut_read_rx_counters()
{
	local per
	local good_frame
	local bad_frame
	local drop_frame

	rx_per_endless_loop=0
	# stopping reception
	dut_send_command "exec $band stopRxPer --calc-per"
	calc_per=$(grep "packetErrorRate" /tmp/dut_out$band)
	dut_send_command "exec $band getRxRateInfo"

	if [ -n "$calc_per" ]; then
		# Extract values using awk and save them to variables
		per=$(echo "$calc_per" | awk -F'[;]' '{print $1}' | awk -F'[:]' '{print $2}')
		good_frame=$(echo "$calc_per" | awk -F'[;]' '{print $2}' | awk -F'[:]' '{print $2}')
		bad_frame=$(echo "$calc_per" | awk -F'[;]' '{print $3}' | awk -F'[:]' '{print $2}')
		drop_frame=$(echo "$calc_per" | awk -F'[;]' '{print $4}' | awk -F'[:]' '{print $2}')
		total_frame=$((good_frame + bad_frame))

		printInfo "[$(util_convert_band_to_radio $band)G][AP mode] RX PER test stopped."
		printInfo "PER:	$(printf "%.1f" "$per")%"
		printInfo "Total frames:	$total_frame"
		printInfo "Good frames:	$good_frame"
		printInfo "Bad frames:	$bad_frame"
		printInfo "Dropped frames:	$drop_frame"
	fi
}

# Start Rx mode and calculate Rx PER.
# args: <radio band> <channel> <bandwidth> <Antenna Selection> <Protocol>
# <Number of Frames to Receive> <Idle Duration> <Destination MAC Address>
dut_calculate_per()
{
	if [ "$#" -lt 7 ]; then
		echo "Illegal number of parameters"
	fi

	# Initialize dut mode
	init_dut_mode

	local band
	local lowestchannel
	local bw
	local ant_mask
	local phymode
	local packet_count=$6	# Number of packets to receive
	local duration=$7			# Idle duration (millisec) to stay in reception
	local isfreq # Flag to indicate if channel is a frequency
	local centerchannel
	local num_antenna

	band=$(util_extract_band $1) || { echo "$band"; exit 1; }
	phymode=$(util_extract_phymode $5 $band) || { echo "$phymode"; exit 1; }
	isfreq=$(util_check_if_frequency $2)

	if [ "$isfreq" -eq 1 ]; then
		util_validate_frequency $band $2
		# Convert center frequency to center channel
		centerchannel=$(util_convert_centerfreq_to_centerchannel $band $2) || { echo "$centerchannel"; exit 1; }
	else
		# If it is channel number, no conversion needed
		centerchannel=$2
	fi

	#extract bandwidth
	bw=$(util_extract_bw $3 $centerchannel $band) || { echo "$bw"; exit 1; }
	if [ "$3" != "-" ]; then
		#validate center channel and bandwidth if bw option is not hypen(-)
		util_validate_center_channel_and_bandwidth $centerchannel $bw $band $phymode
	fi

	lowestchannel=$(util_calculate_lowest_channel $band $bw $centerchannel) || { echo "$lowestchannel"; exit 1; }
	ant_mask=$(util_check_ant_mask $4) || { echo "$ant_mask"; exit 1; }

	if [ -z $7 ] || [ "$7" == "-" ]; then
		duration=0
	fi

	# If the numer of antenna is more than the number of SS then set nss to 1.
	num_antenna=$(util_count_bits_set $ant_mask)
	printInfo "channel is $1GHz[$2/$3]"
	printInfo "Confirmed band: $1G"
	printInfo "Confirmed protocol:$5"
	printInfo "Confirmed bandwidth:$3"
	printInfo "Confirmed antsel: $ant_mask"
	printInfo "Confirmed number of receive frame:$packet_count"
	printInfo "Confirmed idle duration :$duration"

	dut_send_command "exec $band setChannel --bandwidth $bw --channel $lowestchannel --phy-mode $phymode"
	dut_send_command "exec $band setEnabledTxAntennaMask --antenna-mask $ant_mask"
	dut_send_command "exec $band setEnabledRxAntennaMask --antenna-mask $ant_mask"

	# Set Rx packet limits
	dut_send_command "exec $band startRxPer --packet-limit $packet_count --duration-limit $duration"

	# If the duration is 0ms then we need to receive endlessly
	if [ $duration -eq 0 ]; then
		rx_per_endless_loop=1
		sleep infinity
	else
		# Sleep for given duration in ms
		sleep $(awk -v var="$duration" 'BEGIN{print var * 0.001}')
		dut_read_rx_counters
	fi
}

# Run Rx Measure
# args: <radio band> <channel> <bandwidth> <Antenna Selection> <Protocol>
# <Destination MAC Address> <Number of captures> <capture interval>
dut_rx_measure()
{
	if [ "$#" -lt 8 ]; then
		echo "Illegal number of parameters"
	fi

	# Initialize dut mode
	init_dut_mode

	local band
	local centerchannel
	local lowestchannel
	local bw
	local ant_mask
	local phymode
	local isfreq # Flag to indicate if channel is a frequency
	local num_captures
	local interval
	local num_antenna

	band=$(util_extract_band $1) || { echo "$band"; exit 1; }
	phymode=$(util_extract_phymode $5 $band) || { echo "$phymode"; exit 1; }
	isfreq=$(util_check_if_frequency $2)

	if [ "$isfreq" -eq 1 ]; then
		util_validate_frequency $band $2
		# Convert center frequency to center channel
		centerchannel=$(util_convert_centerfreq_to_centerchannel $band $2) || { echo "$centerchannel"; exit 1; }
	else
		# If it is channel number, no conversion needed
		centerchannel=$2
	fi

	#extract bandwidth
	bw=$(util_extract_bw $3 $centerchannel $band) || { echo "$bw"; exit 1; }
	if [ "$3" != "-" ]; then
		#validate center channel and bandwidth if bw option is not hypen(-)
		util_validate_center_channel_and_bandwidth $centerchannel $bw $band $phymode
	fi

	lowestchannel=$(util_calculate_lowest_channel $band $bw $centerchannel) || { echo "$lowestchannel"; exit 1; }
	ant_mask=$(util_check_ant_mask $4) || { echo "$ant_mask"; exit 1; }
	num_captures=$7
	interval=$8

	# If the numer of antenna is more than the number of SS then set nss to 1.
	num_antenna=$(util_count_bits_set $ant_mask)
	printInfo "channel is $1GHz[$2/$3]"
	printInfo "Confirmed band: $1G"
	printInfo "Confirmed protocol:$5"
	printInfo "Confirmed bandwidth:$3"
	printInfo "Confirmed antsel: $ant_mask"
	printInfo "Confirmed number of captures:$num_captures"
	printInfo "Confirmed interval:$interval"

	# Start Rx measure handler process to listen for events
	rx_measure_filename="/tmp/rx_measure$band.csv"
	rm $rx_measure_filename
	rx_measure_handler $band &
	handler_pid=$!
	rx_measure_running=1
	printInfo "Started listening for Rx Measure events. Output file name: $rx_measure_filename"

	dut_send_command "exec $band setChannel --bandwidth $bw --channel $lowestchannel --phy-mode $phymode"
	dut_send_command "exec $band setEnabledTxAntennaMask --antenna-mask $ant_mask"
	dut_send_command "exec $band setEnabledRxAntennaMask --antenna-mask $ant_mask"

	# Send Rx Measure command
	dut_send_command "exec $band rxMeasure --num-captures $num_captures --interval $interval"

	# wait for completion of event handler
	wait $handler_pid

	dut_stop_rx_measure
}

dut_stop_rx_measure()
{
	if [ $rx_measure_running -eq 1 ]; then
		rx_measure_running=0
		ps -p $handler_pid > /dev/null
		if [ $? -eq 0 ]; then
			kill -SIGINT $handler_pid > /dev/null
			handler_pid=
		fi

		# Disable Rx Measure
		dut_send_command "exec $band getRxRateInfo"
		dut_send_command "exec $band rxMeasure --disable"
	fi
}

dut_print_history()
{
	# Changelog
	printInfo "11-Mar-2025 - v1.1"
	printInfo "- Fix Rx Measure whole duration (num capture x interval) minimum value limitation"
	printInfo "- Added support for CW offset parameter"
	printInfo "- Fix Rx PER MCS values displayed for 11n to show as MCS 0 to 7 for respective NSS"
	printInfo "- Added support for RU parameters in Tx mode command"
	printInfo "- Added changes to throw error for invalid channel, phymode, BW combinations"
	printInfo "- Added support for APscan and AP Status commands"
	printInfo "- Added WARNING print when number of Antenna is less than NSS"
	printInfo

	printInfo "01-Mar-2025 - v1.0"
	printInfo "- Added support for init"
	printInfo "- Added suppport for version"
	printInfo "- Added support for txMode and stoptx"
	printInfo "- Added support for startcw and stopcw commands"
	printInfo "- Added support for Rx PER"
	printInfo "- Added support for Rx Measure"
	printInfo
}

# Run scan for all channels in band
# args: [radio band]
dut_start_ap_scan()
{
	local band
	local scanfile
	local start_time
	local end_time
	local duration
	local band_ids

	if [ "$#" -lt 1 ]; then
		band_ids="0 2 4"
	else
		band=$(util_extract_band $1) || { echo "$band"; exit 1; }
		band_ids="$band"
	fi

	for band in $band_ids; do
		# File to store scan results
		scanfile="/tmp/scanres$band.txt"
		printInfo "Scanning band $band"

		# Record start time
		start_time=$(date +%s)

		# Start scan
		iw dev wlan$band scan ap-force | grep -E 'on wlan|freq:|signal:|primary channel:|Primary Channel|SSID:|channel offset:|current operating class:|channel width:|Channel Width:|RSN:|Group cipher:|Pairwise ciphers:|Authentication suites:' > "$scanfile"

		# Record scan complete time and calculate duration
		end_time=$(date +%s)
		duration=$((end_time - start_time))

		# Parse scan results and print
		util_parse_scanres "$scanfile" $band
		printInfo "Scan Duration: $duration seconds"
	done
}

# Dump radio status with peer stats connected to first vap in the radio
# args: [band_id]
dut_print_radio_status()
{
	local band
	local stalist
	local sta_mac
	local state
	local bssinfo
	local channel

	if [ "$#" -lt 1 ]; then
		band_ids="0 2 4"
	else
		band=$(util_extract_band $1) || { echo "$band"; exit 1; }
		band_ids="$band"
	fi

	for band in $band_ids; do
		printInfo "Radio$band Status:"
		state=$(cat /sys/class/net/wlan$band.1/operstate)
		if [ "$state" != "up" ]; then
			printInfo "Interface wlan$band.1 is not UP"
			continue
		fi

		bssinfo=$(iw dev wlan$band.1 info)
		ap_ssid=$(echo $bssinfo | awk -F "ssid" '{print $2}' | awk '{print $1}')
		channel=$(echo $bssinfo | awk -F "channel" '{print $2}' | awk '{print $1}')

		stalist=$(dwpal_cli wlan$band.1 peerlist)
		stalist=$(echo $stalist | awk -F'connected: ' '{print $2}')

		for sta_mac in $stalist; do
			local bw
			local ratesinfo
			local flowstatus
			local phyrxstatus
			local sta_bandwidth
			local sta_rssi
			local sta_rssi_ant1
			local sta_rssi_ant2
			local sta_rssi_ant3
			local sta_rssi_ant4
			local sta_rcpi
			local sta_rcpi_ant1
			local sta_rcpi_ant2
			local sta_rcpi_ant3
			local sta_rcpi_ant4

			ratesinfo=$(dwpal_cli wlan$band.1 peerratesinfo $sta_mac)
			flowstatus=$(dwpal_cli wlan$band.1 peerflowstatus $sta_mac)
			phyrxstatus=$(dwpal_cli wlan$band.1 peerphyrxstatus $sta_mac)
			sta_bandwidth=$(echo $ratesinfo | awk -F "Data uplink rate info" '{print $2}' | awk -F "BW index" '{print $2}' | awk '{print $1}')
			sta_rssi=$(echo $flowstatus | awk -F "Average RSSI of all antennas" '{print $2}' | awk '{print $2}')

			sta_rssi_ant1=$(echo $flowstatus | awk -F "Short-term RSSI average per antenna" '{print $2}' | awk '{print $2}')
			sta_rssi_ant2=$(echo $flowstatus | awk -F "Short-term RSSI average per antenna" '{print $2}' | awk '{print $5}')
			sta_rssi_ant3=$(echo $flowstatus | awk -F "Short-term RSSI average per antenna" '{print $2}' | awk '{print $8}')
			sta_rssi_ant4=$(echo $flowstatus | awk -F "Short-term RSSI average per antenna" '{print $2}' | awk '{print $11}')

			sta_rcpi=$(echo $phyrxstatus | awk -F " : rcpi_avg" '{print $1}' | awk '{print $NF}')
			sta_rcpi_ant1=$(echo $phyrxstatus | awk -F "rcpi " '{print $2}' | awk '{print $1}')
			sta_rcpi_ant2=$(echo $phyrxstatus | awk -F "rcpi " '{print $2}' | awk '{print $4}')
			sta_rcpi_ant3=$(echo $phyrxstatus | awk -F "rcpi " '{print $2}' | awk '{print $7}')
			sta_rcpi_ant4=$(echo $phyrxstatus | awk -F "rcpi " '{print $2}' | awk '{print $10}')

			printInfo "STA MAC:     $sta_mac"
			printInfo "AP SSID:     $ap_ssid"
			printInfo "Channel:     $channel"
			printInfo "Bandwidth:   $sta_bandwidth MHz"
			printInfo "RSSI global: $sta_rssi dBm"
			printInfo "RCPI global: $sta_rcpi dBm"
			printInfo "RSSI[ant 1]: $sta_rssi_ant1 dBm"
			printInfo "RCPI[ant 1]: $sta_rcpi_ant1 dBm"
			printInfo "RSSI[ant 2]: $sta_rssi_ant2 dBm"
			printInfo "RCPI[ant 2]: $sta_rcpi_ant2 dBm"
			printInfo "RSSI[ant 3]: $sta_rssi_ant3 dBm"
			printInfo "RCPI[ant 3]: $sta_rcpi_ant3 dBm"
			printInfo "RSSI[ant 4]: $sta_rssi_ant4 dBm"
			printInfo "RCPI[ant 4]: $sta_rcpi_ant4 dBm"
			echo
		done
	done
}
