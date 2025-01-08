#!/bin/sh

debug_flag=1 #Only for debugging 
# Test script for Wi-Fi Sigma Control API for APs
# Commands based on version 10.2.0
#
# On target board run:
# $ cd /tmp
# $ mknod sigma-pipe p
# $ nc -l -p 9000 < sigma-pipe | ./sigma-ap.sh > sigma-pipe &
# or as persistent
# while true; do nc -l -p 9000 < sigma-pipe | "./sigma-ap.sh" > ./sigma-pipe; done &
# On PC run:
# $ nc <board-ip> 8989
# or
# connect with telnet client in raw mode to <board-ip>:8989
# Then enter commands and send them with <ENTER>

# First digit - Major: Changes incompatible with previous version
# Second digit - Minor: Extension features
# Third digit - Fix: Fixes
# TODO: Store md5 checksum inside the script

source_flag=`cat "/proc/$PPID/cmdline" | grep -oE '[^/]+$' | sed 1d`

. /lib/wifi/platform_dependent.sh

# Read user input eg user_given_num_users_ofdma.. etc, prefix user_given, do not use _ap_ as variable having _ap_ will be unset after each capi call
USER_INPUT_FILE=/tmp/userinput
if [ -f $USER_INPUT_FILE ]; then
	. $USER_INPUT_FILE
fi

ORIG_IFS=$IFS
WAVE_VERSION_FILE="$WAVE_COMPONENTS_FILE"
nof_interfaces=`iw phy | grep -c Wiphy`

if [ "$OS_NAME" = "RDKB" ]; then
	WIFI_RELOAD_CMD="systemctl restart systemd-netifd.service"
	MODEL=$OS_NAME
elif [ "$OS_NAME" = "UGW" ]; then
	WIFI_RELOAD_CMD="wifi down ; sleep 3; wifi up"
    atom_cpu=`version.sh | grep "CPU:" | grep -i atom`
	
	if [ "$nof_interfaces" = "3" ]; then
		hw_revision_wlan4=`cat /proc/net/mtlk/wlan4/eeprom_parsed | grep "HW revision" | awk '{print $4}'`
		hw_revision_wlan0=`cat /proc/net/mtlk/wlan0/eeprom_parsed | grep "HW revision" | awk '{print $4}'`
		hw_type=`cat /proc/net/mtlk/wlan4/eeprom_parsed | grep "HW type" | awk '{print $4}'`
	elif [ "$nof_interfaces" = "2" ]; then
		hw_type=`cat /proc/net/mtlk/wlan4/eeprom_parsed | grep "HW type" | awk '{print $4}'`
		hw_revision_wlan0=`cat /proc/net/mtlk/wlan0/eeprom_parsed | grep "HW revision" | awk '{print $4}'`
		hw_revision_wlan2=`cat /proc/net/mtlk/wlan2/eeprom_parsed | grep "HW revision" | awk '{print $4}'`
	fi

	if [ -n "$atom_cpu" ]; then
		#Differentiation needed between LGM and OCTOPUS as PCI_SLOT values are different for Wave600-D2
		#Wireless controller: Device value is 1e43:3171 for Octopus and 0d5a for LGM
		#Until we find the proper MACRO to differentiat, we can use this hack temperorily
		#hw_type for B0 GPB for Octopus is 0x72.
		#In UGW, the radio_map_file is no longer needed.
		PLAT_MODEL=`lspci | cut -c 37-45 | sort -ur | grep 1e43:3171`
		if [ "$PLAT_MODEL" = "1e43:3171" ]; then
			if [ "$hw_type" = "0x70" ] || [ "$hw_type" = "0x71" ] || [ "$hw_type" = "0x72" ]; then
				MODEL="WAV700_AP"
			else
				[ "$nof_interfaces" = "3" ] && [ "$hw_revision_wlan4" = "0x4E" ] && MODEL="AX11000"
				[ "$nof_interfaces" = "3" ] && [ "$hw_revision_wlan4" = "0x55" ] && MODEL="AX11000"
				[ "$nof_interfaces" = "2" ] && MODEL="AX11000"
				[ "$nof_interfaces" = "4" ] && [ -n `echo "$hw_revision_wlan4" | grep "0x55"` ] && MODEL="AX11000"
			fi
		else
			[ "$nof_interfaces" = "3" ] && [ "$hw_revision_wlan4" = "0x4E" ] && MODEL="AX11000"
			[ "$nof_interfaces" = "3" ] && [ "$hw_revision_wlan4" = "0x55" ] && MODEL="AX11000"
			[ "$nof_interfaces" = "2" ] && MODEL="AX11000"
			[ "$nof_interfaces" = "4" ] && [ -n `echo "$hw_revision_wlan4" | grep "0x55"` ] && MODEL="AX11000"
		fi
	else
		[ "$nof_interfaces" = "3" ] && [ "$hw_revision_wlan4" = "0x4E"  -o "$hw_revision_wlan4" = "0x42" ] && MODEL="AX7800"
		[ "$nof_interfaces" = "2" ] && [ "$hw_revision_wlan0" = "0x41" ] && [ "$hw_revision_wlan2" = "0x42" ] && MODEL="AX6000"
		[ "$nof_interfaces" = "2" ] && [ "$hw_revision_wlan0" = "0x45" ] && [ "$hw_revision_wlan2" = "0x45" ] && MODEL="AX3000"
	fi
	#This is just a workaround for Wi_Fi 7 as version.sh is not very stable 
	[ ! -n "$atom_cpu" ] && MODEL="WAV700_AP"
fi

error_print()
{
	echo "sigma ERROR: $*" > /dev/console
}

info_print()
{
	echo "sigma INFO: $*" > /dev/console
}

if [ "$MODEL" = "" ]; then
	MODEL="MXL-AP"
    error_print "check eeprom card values"
fi

SEND_IW_WLAN0="iw dev wlan0 iwlwav"
SEND_IW_WLAN2="iw dev wlan2 iwlwav"
SEND_IW_WLAN4="iw dev wlan4 iwlwav"

WAVE_VERSION=`grep wave_release_minor $WAVE_VERSION_FILE`
WAVE_VERSION=${WAVE_VERSION##*=}
WAVE_VERSION=${WAVE_VERSION//\"}

CA_VERSION="Sigma-CAPI-10.12.0-${WAVE_VERSION}"

VENDOR='MxL'
DEBUGGING=1 # 1=enabled 0=disabled
# TIMESTAMP="cat /proc/uptime"
TIMESTAMP=
LOG_CMD=$SCRIPTS_PATH/wave_collect_debug.sh
FACTORY_CMD=$SCRIPTS_PATH/wave_factory_reset.sh
UCI_CMD=/lib/config/uci.sh
HOSTAPD_CLI_CMD=hostapd_cli
if [ "$MODEL" != "AX11000" ] && [ "$MODEL" != "WAV700_AP" ] && [ "$OS_NAME" = "UGW" ]; then
	HOSTAPD_CLI_CMD="sudo -u nwk -- $HOSTAPD_CLI_CMD"
fi

#UPDATE_RNR_CLI uses hostapd_cli and UPDATE_RNR_UCI uses uci
#Use user configuration accordingly
UPDATE_RNR_UCI=/lib/netifd/update_rnr_uci.sh
UPDATE_RNR_CLI=/lib/netifd/update_rnr.sh
if [ "$MODEL" != "AX11000" ] && [ "$MODEL" != "WAV700_AP" ] && [ "$OS_NAME" = "UGW" ]; then
	UPDATE_RNR_CLI="sudo -u nwk -- $UPDATE_RNR_CLI"
fi

#SID values for W700
SID_24G_MIN="128"
SID_24G_MAX="255"
SID_5G_MIN="0"
SID_5G_MAX="127"
SID_6G_MIN="256"
SID_6G_MAX="509"

FORCE_EHT_FIXED_RATE_CFG_FILE_PATH="/tmp/force_eht_fixed_rate_cfg"
FORCE_AKM_SUITE_TYPE_TO_SAE_AND_SAEEXTKEY_FILE_PATH="/tmp/force_akm_suite_type_to_sae_and_sae_ext_key"

dirname()
{
	full=$1
	file=`basename $full`
	path=${full%%$file}
	[ -z "$path" ] && path=./
	echo $path
}
thispath=`dirname $0`

timestamp()
{
	echo "[$(date '+%Y-%m-%d %T')][$(cat /proc/uptime | cut -d ' ' -f1)]"
}

debug_print()
{
	if [ "$DEBUGGING" = "1" ]; then
		echo "$(timestamp) sigma DEBUG: $*" > /dev/console
	fi
}

# array like helper functions (ash)
values_get_count()
{
	local values=$1
	local delimiter=$2

	echo "$values" | awk -F"$delimiter" '{print NF}'
}

values_get_at()
{
	local values=$1
	local delimiter=$2
	local idx=$3

	let idx=idx+1
	echo "$values" | awk -F"$delimiter" '{print $'$idx'}'
}

values_replace_at()
{
	local values=$1
	local delimiter=$2
	local idx=$3
	local replace_with=$4

	local _out_values=""
	local _idx=0

	local _old_IFS=$IFS
	IFS=$delimiter
	for _val in $values; do
		if [ "$idx" -eq "$_idx" ] && [ -n "$replace_with" ]
		then
			_out_values="$_out_values$delimiter$replace_with"
		else
			_out_values="$_out_values$delimiter$_val"
		fi
		let _idx=_idx+1
	done
	IFS=$_old_IFS

	echo "$_out_values" | cut -c 2- # remove first '$delimiter'
}

is_6g_supported()
{
	local phys=$(ls /sys/class/ieee80211/)

	if [ "$ucc_program" != "he" ] && [ "$ucc_program" != "eht" ]; then
		echo "0"
		return
	fi

	for phy in $phys
	do
		iw $phy info | grep -Eq "\* 60..(\.[0-9])? MHz"
		is_phy_6g=$?

		if [ $is_phy_6g = '0' ]; then
			echo "1"
			return
		fi
	done
	echo "0"
	return
}

kill_sigma_mbo_daemon()
{
	local old_ifs
	local killwatchdog=0
	local daemon_pid=`ps -w | grep sigma_mbo_daemon.sh | grep -v grep | awk '{ print $1 }' | tr  '\n' ' '`
	old_ifs=$IFS
	IFS=' '
	while [ "$daemon_pid" != "" ]; do
		for p in $daemon_pid
		do
			#pidtoKill=$(echo $p | tr -d '\n')
			pidtoKill=$p
			kill "$pidtoKill"
		done
		daemon_pid=`ps -w | grep sigma_mbo_daemon.sh | grep -v grep | awk '{ print $1 }' | tr  '\n' ' '`
		let killwatchdog=killwatchdog+1
	done
	IFS=$old_ifs

	info_print Sigma Kill Watchdog: $killwatchdog
}

kill_sigmaManagerDaemon_static()
{
	local old_ifs
	local killwatchdog=0
	local daemon_pid=`ps -w | grep sigmaManagerDaemon_static | grep -v grep | awk '{ print $1 }' | tr  '\n' ' '`
	old_ifs=$IFS
	IFS=' '
	while [ "$daemon_pid" != "" ]; do
		for p in $daemon_pid
		do
			#pidtoKill=$(echo $p | tr -d '\n')
			pidtoKill=$p
			kill "$pidtoKill"
		done
		daemon_pid=`ps -w | grep sigmaManagerDaemon_static | grep -v grep | awk '{ print $1 }' | tr  '\n' ' '`
		let killwatchdog=killwatchdog+1
	done
	IFS=$old_ifs

	info_print Sigma Kill Watchdog: $killwatchdog
}

kill_sigmaManagerDaemon()
{
	local old_ifs
	local killwatchdog=0
	local daemon_pid=`ps -w | grep sigmaManagerDaemon | grep -v grep | awk '{ print $1 }' | tr  '\n' ' '`
	old_ifs=$IFS
	IFS=' '
	while [ "$daemon_pid" != "" ]; do
		for p in $daemon_pid
		do
			#pidtoKill=$(echo $p | tr -d '\n')
			pidtoKill=$p
			kill "$pidtoKill"
		done
		daemon_pid=`ps -w | grep sigmaManagerDaemon | grep -v grep | awk '{ print $1 }' | tr  '\n' ' '`
		let killwatchdog=killwatchdog+1
	done
	IFS=$old_ifs

	info_print Sigma Kill Watchdog: $killwatchdog
}

sortPlan()
{
	local static_plan_config subband_pos1 num_sta ru_pos1 subband_ru_list splanconfigRUsorted offset \
	subband_pos ru_pos i subband p ru subband_ru1 subband_ru2 subband_ru3 subband_ru4 sortedList \
	sorted_subband_ru1 sorted_subband_ru2 sorted_subband_ru3 sorted_subband_ru4 \
	old_ifs next_pos index skip_ru pos cur_subband_ru cur_subband cur_ru

	static_plan_config=$1
	subband_pos1=$2
	num_sta=$3
	subband_ru_list=""
	splanconfigRUsorted=""
	offset=19
	ru_pos1=$((subband_pos1+1))

	subband_pos=$subband_pos1
	ru_pos=$ru_pos1
	i=1
	while [ $i -le $num_sta ]
	do
		subband=`echo $static_plan_config | awk -v p="$subband_pos" '{print $p}'`
		ru=`echo $static_plan_config | awk -v p="$ru_pos" '{print $p}'`
		eval subband_ru${i}="${subband}${ru}"
		subband_pos=$((subband_pos+offset))
		ru_pos=$((ru_pos+offset))
		i=$((i+1))
	done

	subband_ru_list="$subband_ru1 $subband_ru2 $subband_ru3 $subband_ru4"
	sortedList=$(echo $subband_ru_list | tr " " "\n" | sort -n)
	sortedList=$(echo $sortedList | tr "\n" " ")

	eval sortedList_${subband_pos1}="$sortedList"

	i=1
	while [ $i -le $num_sta ]
	do
		eval sorted_subband_ru${i}=`echo $sortedList | awk -v p="$i" '{ print $p }'`
		i=$((i+1))
	done
	i=0
	old_ifs=$IFS
	IFS=' '
	next_pos=$subband_pos1
	index=1
	skip_ru=no
	val=1
	for pos in $static_plan_config
	do
		i=$((i+1))
		if [ "$skip_ru" = "yes" ]
		then
			skip_ru=no
		elif [ $i -eq $next_pos ]
		then
			#this block handles 2-params encoding of dl_subBandPerUsp and dl_startRuPerUsp information.
			eval cur_subband_ru=\${sorted_subband_ru${index}}
			#2-digit encoding dl_subBandPerUsp is 1 digit and dl_startRuPerUsp is 1 digit
			if [ "$cur_subband_ru" -lt 100 ]; then
				cur_subband=${cur_subband_ru:0:1}
				cur_ru=${cur_subband_ru:1:1}
			else #3-digit encoding dl_subBandPerUsp is 2 digit and dl_startRuPerUsp is 1 digit
				cur_subband=${cur_subband_ru:0:2}
				cur_ru=${cur_subband_ru:2:1}
			fi
			splanconfigRUsorted="$splanconfigRUsorted $cur_subband $cur_ru"
			skip_ru=yes
			[ "$val" -lt "4" ] && next_pos=$((next_pos+offset))
			index=$((index+1))
			val=$((val+1))
		else		
			splanconfigRUsorted="$splanconfigRUsorted $pos"
		fi
	done
	splanconfigRUsorted=`echo $splanconfigRUsorted`
	IFS=$old_ifs
	echo $splanconfigRUsorted
}

##SP_DEBUG_INFRA
## function to send debug static plan from a known set of SP cmds.
## Before taking a cmd from the file - will check that the file is ready for reading,
## and not occupied by other proceess.
static_plan_send_debug_infra()
{
		local users=$1
		local forced_static_plan
		local blocking_loop_idx=5

		## checking the file is not occupied by another process, if yes wait..
		while [ ! -r "/tmp/${glob_ssid}_tmp" ] && [ "$blocking_loop_idx" != "0" ]
		do
			blocking_loop_idx=$((blocking_loop_idx--))
			sleep 1
		done
		[ "$blocking_loop_idx" = "0" ] && info_print "SP_DEBUG_INFRA:ERROR cannot read file for static plan cmd" && exit -1

		## take the top first line from the file.
		forced_static_plan=`sed -n '1p' "/tmp/${glob_ssid}_tmp"`
		## file is blocked by removing read permission untill cmd send
		chmod -r /tmp/${glob_ssid}_tmp
		##delete it after read for next cmd.
		sed -i '1d' "/tmp/${glob_ssid}_tmp"
		## remove any un-needed spaces
		forced_static_plan=${forced_static_plan//'  '/' '}
		## send the cmd
		if [ -n "$forced_static_plan" ]; then
			eval $forced_static_plan
			info_print "SP_DEBUG_INFRA:FORCED plan for $users users: $forced_static_plan"
		else
			info_print "SP_DEBUG_INFRA:!!!ERROR!!! cannot send empty static plan cmd"
			exit -1
		fi
		## allow reading for next cmd
		chmod +r /tmp/${glob_ssid}_tmp
}
static_plan_init_debug_infra()
{
	## debug infrastructure (SP_DEBUG_INFRA)
	## 1. Create a file in tmp dir with the same ssid that test is using e.g. HE-4.36.1_24G
	## Note: check the UCC log for getting the exact name.
	## 2. Copy all iw dev wlan iwlwav sMuStatPlanCfg ... cmds line after line ( SP off commands are not needed).
	if [ -e "/tmp/$glob_ssid" ]; then
		dos2unix "/tmp/$glob_ssid"
		##remove all empty lines
		sed -ir '/^\s*$/d' "/tmp/$glob_ssid"
		[ -e "/tmp/${glob_ssid}_tmp" ] && rm -f "/tmp/${glob_ssid}_tmp"
		## create a tmp working file
		cp "/tmp/$glob_ssid" "/tmp/${glob_ssid}_tmp"
		## remove wirte permission we need only read
		chmod -w /tmp/${glob_ssid}_tmp
		info_print "SP_DEBUG_INFRA:FORCED plans is activate"
	fi
}

# check if tr command is available
# lower/upper case conversion is faster with external tr
TR=`command -v tr`
if [ "$TR" = "" ]; then
	debug_print "tr not available"
	alias lower=lc_int
	alias upper=uc_int
else
	debug_print "tr available at $TR"
	alias lower=lc_ext
	alias upper=uc_ext
fi

##### Helper Functions #####

# default values for dut mode
nss_def_val_dl="2"	# Range: 1-4
mcs_def_val_dl="11"	# Range: 0-11
nss_def_val_ul="2"	# Range: 1-4
mcs_def_val_ul="11"	# Range: 0-11

# default values for testbed mode
nss_def_val_dl_testbed="2"	# Range: 1-4
mcs_def_val_dl_testbed="7"	# Range: 0-11
nss_def_val_ul_testbed="2"	# Range: 1-4
mcs_def_val_ul_testbed="7"	# Range: 0-11

convert_fixed_ltf_gi()
{
	is_auto=$1
	ltf_and_gi_value=$2

	case "$is_auto" in
		"Auto") is_auto_converted="1" ;;
		"Fixed") is_auto_converted="0" ;;
	esac

	case "$ltf_and_gi_value" in
		"HtVht0p4usCP") ltf_and_gi_value_converted="0" ;;
		"HtVht0p8usCP") ltf_and_gi_value_converted="1" ;;
		"He0p8usCP2xLTF") ltf_and_gi_value_converted="2" ;;
		"He1p6usCP2xLTF") ltf_and_gi_value_converted="3" ;;
		"He0p8usCP4xLTF") ltf_and_gi_value_converted="4" ;;
		"He3p2usCP4xLTF") ltf_and_gi_value_converted="5" ;;
	esac
}

convert_fixed_rate()
{
	band_width=$1
	phy_mode=$2

	case "$band_width" in
		"20MHz") bw_converted="0" ;;
		"40MHz") bw_converted="1" ;;
		"80MHz") bw_converted="2" ;;
		"160MHz") bw_converted="3" ;;
		#Host/FW interface is configured with only one bandwidth value(4) for both 320MHz-1 and 320MHz-2 channel
		"320_1MHz"|"3201MHz") bw_converted="4" ;;
		"320_2MHz"|"3202MHz") bw_converted="4" ;;
		"*") bw_converted="";;
	esac
	
	case "$phy_mode" in
		"a")  phym_converted="0" ;;
		"b")  phym_converted="1" ;;
		"n")  phym_converted="2" ;;
		"ac") phym_converted="3" ;;
		"ax") phym_converted="4" ;;
		"ax_su_ext") phym_converted="5" ;;
		"be") phym_converted="8" ;;
		"*") ;; # not found
	esac
}

convert_Operation_ChWidth()
{
	band_width=$1

	case "$band_width" in
		"20MHz") vht_oper_chwidth_converted="0" ;;
		"40MHz") vht_oper_chwidth_converted="0" ;;
		"80MHz") vht_oper_chwidth_converted="1" ;;
		"160MHz") vht_oper_chwidth_converted="2" ;;
	esac	
}

get_disabled_subchannel_bitmap()
{
	debug_print get_disabled_subchannel_bitmap $*

	local mode=""
	local chnl_list=""
	local index
	local x=0
	CURRENT_RADIO_UCI_PATH=$1
	puncturing_bw=$2
	punct_chnl=$3
	dsb_res_val=$4

	[ "$global_primary_channel" = "$punct_chnl" ] && error_print "! ! ! Primary channel cannot be punctured ! ! !"
	mode=`$UCI_CMD get $CURRENT_6G_RADIO_UCI_PATH.htmode`
	if [ "$mode" = "EHT320_1" ] && [ "$puncturing_bw" = "4" ]; then
		chnl_list="1 5 9 13 17 21 25 29 33 37 41 45 49 53 57 61"
		base_chnl=1
		i=$base_chnl
		if [ "$punct_chnl" -gt "29" ]; then
			error_print "! ! ! Puncturing of a subchannel in the Primary band is NOT supported ! ! !"
		fi
	else
		chnl_list="33 37 41 45 49 53 57 61 65 69 73 77 81 85 89 93"
		base_chnl=33
		i=$base_chnl
	if [ "$puncturing_bw" = "4" ]; then
			[ "$punct_chnl" -le "61" ] && error_print "! ! ! Puncturing of a subchannel in the Primary band is NOT supported ! ! !"
		elif [ "$puncturing_bw" = "3" ]; then
			[ "$global_primary_channel" = "37" ] && [ "$punct_chnl" -le "45" ] && error_print "! ! ! Puncturing of a subchannel in the Primary band is NOT supported ! ! !"
			[ "$global_primary_channel" = "53" ] && [ "$punct_chnl" -ge "49" ] && error_print "! ! ! Puncturing of a subchannel in the Primary band is NOT supported ! ! !"
		elif [ "$puncturing_bw" = "2" ]; then
			[ "$punct_chnl" -le "37" ] && error_print "! ! ! Puncturing of a subchannel in the Primary band is NOT supported ! ! !"
		else
			debug_print "Puncturing BW is not valid"
		fi
	fi
	for i in $chnl_list
	do
		if [ "$i" != "$punct_chnl" ]; then
			punct_chnl_present=0
		else
			punct_chnl_present=1
			break
		fi
	done
	if [ "$punct_chnl_present" != "1" ]; then
		error_print "! ! ! Subchannel $punct_chnl is not in the currently supported channels list ! ! !"
	fi

	let index=$punct_chnl-$base_chnl
	let index=$index/4
	dsb_val=$((2**$index))
	let dsb_val=$dsb_res_val+$dsb_val

	echo $dsb_val
}

get_disabled_subchannel_bitmap_val()
{
	local i=1
	local dis_subchnl_bitmap_val=0
	nof_channels=$2
	CURRENT_RADIO_UCI_PATH=$1
	mode=$3

	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	punct_bw=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx`

	while [ "$i" -le "$nof_channels" ]; do
		if [ "$mode" -eq 0 ]; then
			eval punct_chnl=`sed -n ''${i}'p' $STATIC_PUNC_CHNL_FILE`
		elif
			[ "$mode" -eq 1 ]; then
			eval punct_chnl=`sed -n ''${i}'p' $DYN_PUNC_CHNL_FILE`
		else
			error_print "Wrong Puncturing Mode"
			send_invalid ",errorCode,1000"
			return
		fi
		info_print "Punctured Chnl${i} : $punct_chnl"
		dis_subchnl_bitmap_val=`get_disabled_subchannel_bitmap $CURRENT_RADIO_UCI_PATH $punct_bw $punct_chnl $dis_subchnl_bitmap_val`
		i=$((i+1))
	done
	echo "$dis_subchnl_bitmap_val"
}

get_index_from_db()
{
        param="$1"
        values=`$UCI_CMD get $param`
		values=`echo $values | sed 's/=/ /g'`
        x=${2/x}
        let x=x+1
        echo `values_get_at "$values" " " "$x"`
}

convert_bf_mode()
{
	# Define local parameters
	local bf_mode sBfMode
	upper "$1" bf_mode 
	
	case "$bf_mode" in
		"AUTO") sBfMode="0xff" ;;
		"EXPLICIT") sBfMode="0" ;;
		"IMPLICIT") sBfMode="1" ;;
		"STBC1X2") sBfMode="2" ;;
		"STBC2X4") sBfMode="3" ;;
		"DISABLED") sBfMode="4" ;;
	esac
	echo $sBfMode
}
check_all_interfaces()
{
	local total_vaps total_up_vaps
	ap_tmp=`iw dev wlan8 del` #Workaround for CGR zwdfs
	if [ -z "$1" ]; then
		total_vaps=`eval uci show wireless | grep ifname | cut -d"=" -f2 | grep -v wlan6 | wc -w`
		total_up_vaps=`eval ifconfig | grep -v wlan6 | grep -c wlan`
	else
		total_vaps=`eval uci show wireless | grep ifname | grep $1 | cut -d"=" -f2 | grep -v wlan6 | wc -w`
		total_up_vaps=`eval ifconfig | grep -v wlan6 | grep $1 | grep -c wlan`
	fi
	if [ $total_vaps -eq $total_up_vaps ]
	then
		echo 0
	else
		echo 1
	fi
}

ap_config_transition_owe()
{
	local bss_owe bss_open
	# All OWE tests are reset to WPA3 program defaults and hence all the BSSes will have WPA3 encryption enabled by default
	# Safe to use the grep approach to derive the UCI path for OWE and OPEN network configurations as there will be
	# no other BSS configured with OWE or OPEN security configuration
	bss_owe=`eval uci show wireless | grep encryption | grep owe | awk -F"." '{print $1 "." $2}'`
	if [ -z "$bss_owe" ]; then
		return
	fi
	bss_open=`eval uci show wireless | grep encryption | grep none | awk -F"." '{print $1 "." $2}'`
	if [ -z "$bss_open" ]; then
		return
	fi
	ap_open_macaddr=`$UCI_CMD get $bss_open.macaddr`
	ap_open_ssid=`$UCI_CMD get $bss_open.ssid`
	#Set the SSID of OWE to dummy string "Owe"; eventually will be configured to hidden
	$UCI_CMD set $bss_owe.ssid=Owe
	$UCI_CMD set $bss_owe.owe_transition_ssid=$ap_open_ssid
	$UCI_CMD set $bss_owe.owe_transition_bssid=$ap_open_macaddr
	$UCI_CMD set $bss_owe.hidden=1
	ap_owe_macaddr=`$UCI_CMD get $bss_owe.macaddr`
	ap_owe_ssid=`$UCI_CMD get $bss_owe.ssid`
	$UCI_CMD set $bss_open.owe_transition_ssid=$ap_owe_ssid
	$UCI_CMD set $bss_open.owe_transition_bssid=$ap_owe_macaddr
	return
}

#The below sub routine is to enable the generation of internal AID/SID similar to the legacy
#where AID=SID+1 and SID starts at 0 (across bands). This is needed mainly for the plan sorting purposes.
#The actual SID for each user is extracted from the sta_list file just before the final plan is sent out.
#Input: AIDs 64,65,... or 192,193,... from the sta_list
#Output: Internal AIDs 1,2,3,... => Internal SIDs 0,1,2,...
convert_aid_for_wav700()
{
	local aid_in=$1
	local aid_out=$1
	if [ "$MODEL" = "WAV700_AP" ]; then
		if [ "$ucc_program" = "eht" ]; then
			aid_out=$((aid_in-63))
		else
			aid_out=$((aid_in-191))
		fi
	fi
	echo "$aid_out"
}

#It may take around 15-20 seconds of delay for the AP cleanup
force_ap_cleanup()
{
	debug_print "Cleaning up the AP ..."
	rm -f ${DUMP_LOC}/fw_dump*
	rm -f ${DUMP_LOC}/whm_*
	glob_ap_driver_reload=0
	iw dev wlan0 iwlwav sFWRecovery 1 0 25 1 300
	local res1=$?

	#Reload the Driver just in case the FW recoveries are close to the max limit set.
	#Do not expect this to ever happen as the FW recovery limit is set to 25 with a 5 min recovery interval!
	#Purely a defensive code just to avoid freezing of the AP in some unexpected worse case scenario...
	rcvry_stat=`iw dev wlan0 iwlwav gFWRecoveryStat`
	local res2=$?
	full_rcvry_count=${rcvry_stat##*:}
	rcvry_count=`echo $full_rcvry_count | awk -F" " '{print $2}'`
	#Reloading of driver will only happen if any or both of the above IW commands failed to get the 0 as status result code.
	#Or the recovery count reaches to 20 out of the max limit set ,i.e 25.
	if [ $res1 != "0" ] || [ $res2 != "0" ] || [ $rcvry_count -gt 19 ]; then
		debug_print "Reloading the driver modules ..."
		reload_driver_with_acceleration 1
		glob_ap_driver_reload=1
		local dh_pid=`ps -w | grep dump_handler | grep -v grep | awk '{ print $1 }' | tr  '\n' ' '`
		while [ "$dh_pid" != "" ]; do
			debug_print "Kill dump_handler"
			kill -9 $dh_pid
			sleep 10
			dh_pid=`ps -w | grep dump_handler | grep -v grep | awk '{ print $1 }' | tr  '\n' ' '`
		done
		debug_print "Kill whm_handler"
		killall whm_handler
		sleep 2
	else
		wifi down
		sleep 5
	fi
}

check_dfs_channel()
{
	radios=`uci show wireless | grep "band='5GHz'" | cut -d"." -f1-2`
	for radio in $radios
	do
		channel=`uci show $radio.channel | cut -d"=" -f2 | tr -d "'"`
		bw=`uci show $radio.htmode | cut -d"=" -f2 | tr -d "'"`
		if [ "$channel" != "first_non_dfs" ]; then
			break;
		fi
	done

	if [ "$bw" = "VHT160" ] || [ "$bw" = "HT160" ] || { [ $channel -gt 48 ] && [ $channel -lt 149 ]; }; then
		debug_print "$channel is a dfs channel"
		echo 1
	else
		debug_print "$channel is not a dfs channel"
		echo 0
	fi
}

verify_interfaces_up()
{
	local timeout=0
	local max_timeout=110
	local is_dfs_channel=`check_dfs_channel`

	if [ "$is_dfs_channel" = "0" ]; then
		max_timeout=50
	fi

	while [ `check_all_interfaces $1` -eq 1 ] && [ $timeout -lt $max_timeout ]
	do
		sleep 1
		timeout=$((timeout+1))
	done

	if [ $timeout -lt $max_timeout ]
	then
		echo 0
	else
		echo 1
	fi
}

# Static planner - Defined indexes names and location 
#common SP
operation_mode_idx=0
txop_com_max_tx_op_duration_idx=1
sequence_type_idx=2
txop_com_start_bw_limit_idx=3 
dl_com_phases_format_idx=4
dl_com_num_of_participating_stations_idx=5
dl_com_mu_type_idx=6 
dl_com_number_of_phase_repetitions_idx=7
dl_com_maximum_ppdu_transmission_time_limit_idx=8
dl_com_rf_power_idx=9 
dl_com_he_cp_idx=10
dl_com_he_ltf_idx=11 
ul_com_he_cp_idx=12
ul_com_he_ltf_idx=13
rcr_com_tf_hegi_and_ltf_idx=14
rcr_com_tf_length_idx=15 
tf_com_psdu_rate_idx=16 
rcr_com_he_sig_a_spatial_reuse_idx=17 
rcr_com_stbc_idx=18 
nfrp_start_aid_idx=19 
nfrp_multiplexingFlag_idx=20
nfrp_feedbackType_idx=21

#Per_User SP - Defined indexes names and location 
dl_usr_usp_station_indexes_idx=0 
dl_usr_psdu_rate_per_usp_idx=1 
dl_usr_tid_alloc_bitmap_idx=2
dl_usr_ul_psdu_rate_per_usp_idx=3 
dl_usr_bf_type_idx=4 
dl_usr_sub_band_per_usp_idx=5 
dl_usr_start_ru_per_usp_idx=6 
dl_usr_ru_size_per_usp_idx=7
tf_usr_tf_starting_ss_idx=8 
tf_usr_tf_mpdu_mu_spacing_factor_idx=9 
tf_usr_tf_padding_idx=10 
rcr_tf_usr_target_rssi_idx=11 
rcr_tf_usr_ldpc_idx=12 
rcr_tf_usr_psdu_rate_idx=13 
rcr_tf_usr_sub_band_idx=14
rcr_tf_usr_start_ru_idx=15 
rcr_tf_usr_ru_size_idx=16 
rcr_tf_usr_ss_allocation_idx=17 
rcr_tf_usr_coding_type_bcc_or_lpdc_idx=18

#Per_User MRU SP - Defined indexes names and location
dl_mru_perusp_idx=0
ul_mru_idx=1

send_status()
{
	IFS=,
	echo "status,$*" `eval $TIMESTAMP`
	echo "$(timestamp) status,$@" >/dev/console
	IFS=$ORIG_IFS
}

send_running()
{
	send_status "RUNNING "
}

# First char for these function needs to be a "," to be able to also send replies
# without parameters
send_complete()
{
	send_status "COMPLETE$*"
}

send_error()
{
	send_status "ERROR$*"
}

send_invalid()
{
	send_status "INVALID$*"
}

#
# TODO: Check whether sed works faster when all the variables are changed at once
#		Maybe the file read only once in this case.
#

UPPERCHARS=ABCDEFGHIJKLMNOPQRSTUVWXYZ
LOWERCHARS=abcdefghijklmnopqrstuvwxyz

lc_int()
{
	# usage: lc "SOME STRING" "destination variable name"
	i=0
	OUTPUT=""
	while ([ $i -lt ${#1} ]) do
		CUR=${1:$i:1}
		case $UPPERCHARS in
			*$CUR*)
			CUR=${UPPERCHARS%$CUR*}
			OUTPUT="${OUTPUT}${LOWERCHARS:${#CUR}:1}"
		;;
		*)
			OUTPUT="${OUTPUT}$CUR"
		;;
		esac
		i=$((i+1))
	done
	debug_print "lower-${OUTPUT}"
	export ${2}="${OUTPUT}"
}

lc_ext()
{
	export ${2}=`echo $1 | tr '[A-Z]' '[a-z]'`
}

uc_int()
{
	# usage: uc "some string" -> "SOME STRING"
	i=0
	OUTPUT=""
	while ([ $i -lt ${#1} ]) do
		CUR=${1:$i:1}
		case $LOWERCHARS in
			*$CUR*)
				CUR=${LOWERCHARS%$CUR*}
				OUTPUT="${OUTPUT}${UPPERCHARS:${#CUR}:1}"
			;;
			*)
				OUTPUT="${OUTPUT}$CUR"
			;;
		esac
		i=$((i+1))
	done
	debug_print "upper-${OUTPUT}"
	export ${2}="${OUTPUT}"
}

uc_ext()
{
	export ${2}=`echo $1 | tr '[a-z]' '[A-Z]'`
}

Dynamic_set_get_helper_none_debug() 
{
		info_print "parameters=$@"
        interface_name="$1"
        param="$2"
        shift
        shift
        field="$1"
        shift
        values=`$UCI_CMD get $param`
		values=`echo $values | sed 's/=/ /g'`
		info_print "none values=$values"
        local num_values=`values_get_count "$values" " "`
        for x in $@; do
                local tmp_val=`values_get_at "$x" "=" "0"`
                local idx=${tmp_val/x}
                local value=`values_get_at "$x" "=" "1"`
                if [ "$idx" -lt "$num_values" ]; then
                        values=`values_replace_at "$values" " " "$idx" "$value"`
                fi
        done
		info_print "iw dev $interface_name iwlwav ${field} $values"
        eval iw dev $interface_name iwlwav ${field} $values
		info_print "none $UCI_CMD set ${param}=\"$values\""
		$UCI_CMD set ${param}="$values"
		eval iw $interface_name iwlwav $field ${values/${field}}
}

Dynamic_set_get_helper()
{
		info_print "parameters=$@"
		rf_flag="$1"
		shift
        interface_name="$1"
        param="$2"
        shift
        shift
        field="$1"
        shift
		values=`$UCI_CMD get $param`
		values=`echo $values | sed 's/=/ /g'`
		info_print "values=$UCI_CMD get $param"
		info_print "values=$values"
        local num_values=`values_get_count "$values" " "`
        for x in $@; do
                local tmp_val=`values_get_at "$x" "=" "0"`
                local idx=${tmp_val/x}
                local value=`values_get_at "$x" "=" "1"`
                let idx++
                if [ "$idx" -lt "$num_values" ]; then
                        values=`values_replace_at "$values" " " "$idx" "$value"`
                fi
        done
		info_print "$UCI_CMD set ${param}=\"$values\""
		$UCI_CMD set $param="$values"

		if [ "${rf_flag}" = "iw_on" ]; then
			iw $interface_name iwlwav $field ${values/${field}}
		fi
		if [ "${rf_flag}" = "iw_off" ]; then
			debug_print "Dynamic_set_get_helper iw_off not sending plan"
		fi
}

set_get_helper()
{
	param=`values_get_at "$1" "=" "0"`
	shift
	values=`$UCI_CMD get ${param}`
	values=`echo $values | sed 's/=/ /g'`
	local num_values=`values_get_count "$values" " "`
	for x in $@; do
		local tmp_val=`values_get_at "$x" "=" "0"`
		local idx=${tmp_val/x}
		local value=`values_get_at "$x" "=" "1"`
		let idx++
		if [ "$idx" -lt "$num_values" ]; then
			values=`values_replace_at "$values" " " "$idx" "$value"`
		fi
	done
	info_print "$UCI_CMD set ${param}=\"$values\""
	$UCI_CMD set ${param}="$values"
}

set_get_helper_non_debug()
{
	param="$1"
	shift
	values=`$UCI_CMD get $param`
	values=`echo $values | sed 's/=/ /g'`
	local num_values=`values_get_count "$values" " "`
	for x in $@; do
		local tmp_val=`values_get_at "$x" "=" "0"`
		local idx=${tmp_val/x}
		local value=`values_get_at "$x" "=" "1"`
		if [ "$idx" -lt "$num_values" ]; then
			values=`values_replace_at "$values" " " "$idx" "$value"`
		fi
	done
	info_print "$UCI_CMD set $param=\"$values\""
	$UCI_CMD set $param="$values"
} 

get_nss_mcs_val()
{
	local ap_nss_mcs_val ap_nss ap_mcs

	[ -z "$1" ] && echo "get_nss_mcs_val: ERROR: Missing ap_nss" && return
	[ -z "$2" ] && echo "get_nss_mcs_val: ERROR: Missing ap_mcs" && return

	ap_nss=$1
	ap_mcs=$2

	if [ "$ap_program" = "EHT" ]; then
		[ "$ap_mcs" = "12" -o "$ap_mcs" = "13" ] && ap_mcs=11
	fi

	if [ "$ap_nss" = "1" ] && [ "$ap_mcs" = "7" ]; then
		ap_nss_mcs_val=65532
	elif [ "$ap_nss" = "1" ] && [ "$ap_mcs" = "9" ]; then
		ap_nss_mcs_val=65533
	elif [ "$ap_nss" = "1" ] && [ "$ap_mcs" = "11" ]; then
		ap_nss_mcs_val=65534
	elif [ "$ap_nss" = "2" ] && [ "$ap_mcs" = "7" ]; then
		ap_nss_mcs_val=65520
	elif [ "$ap_nss" = "2" ] && [ "$ap_mcs" = "9" ]; then
		ap_nss_mcs_val=65525
	elif [ "$ap_nss" = "2" ] && [ "$ap_mcs" = "11" ]; then
		ap_nss_mcs_val=65530
	elif [ "$ap_nss" = "3" ] && [ "$ap_mcs" = "7" ]; then
		ap_nss_mcs_val=65472
	elif [ "$ap_nss" = "3" ] && [ "$ap_mcs" = "9" ]; then
		ap_nss_mcs_val=65493
	elif [ "$ap_nss" = "3" ] && [ "$ap_mcs" = "11" ]; then
		ap_nss_mcs_val=65514
	elif [ "$ap_nss" = "4" ] && [ "$ap_mcs" = "7" ]; then
		ap_nss_mcs_val=65280
	elif [ "$ap_nss" = "4" ] && [ "$ap_mcs" = "9" ]; then
		ap_nss_mcs_val=65365
	elif [ "$ap_nss" = "4" ] && [ "$ap_mcs" = "11" ]; then
		ap_nss_mcs_val=65450
	else
		error_print "Unsupported value - ap_nss_cap:$1 ap_mcs_max_cap:$2"
		return
	fi

	info_print "$ap_nss_mcs_val"
	echo $ap_nss_mcs_val
}

get_test_case_name()
{
	local ssid_name tc_name

	[ -z "$1" ] && echo "get_test_case_name: ERROR: Missing ssid name" && echo 0
	ssid_name=$1

	tc_name=${ssid_name##*-}  #trim leading prefix
	tc_name=${tc_name%%_*}    #trim trailing postfix

	echo "$tc_name"
}

get_nof_sta_per_he_test_case()
{
	local ssid_name tc_name_1 
	ssid_name=$1

	tc_name_1=`get_test_case_name $ssid_name`

	case "$tc_name_1" in
			"4.58.1"|"4.68.1"|"5.60.1"|"5.61.1"|"5.73.1"|"5.74.1") nof_sta=1 ;;		
			"4.43.1"|"4.46.1"|"4.53.1"|"4.53.2"|"4.53.3"|"4.54.1"|"4.56.1"|"4.63.1"|"4.64.1"|"5.47.1"|"5.48.1"|"5.52.1"|"5.54.1"|"5.55.1"|"5.57.1"|"5.57.2"|"5.57.3"|"5.58.1") nof_sta=2 ;;
			"4.29.1"|"4.36.1"|"4.37.1"|"4.40.1"|"4.40.2"|"4.40.3"|"4.40.4"|"4.40.5"|"4.41.1"|"4.41.2"|"4.44.1"|"4.49.1"|"4.45.1"|"4.30.1"|"4.44.1"|"4.55.1"|"4.60.1"|"4.62.1"|"4.69.1"|"5.44.1"|"5.44.2"|"5.44.3"|"5.44.4"|"5.44.5"|"5.44.6"|"5.44.7"|"5.44.8"|"5.44.9"|"5.45.1"|"5.45.2"|"5.49.1"|"5.50.1"|"5.53.1") nof_sta=4 ;;
			*) nof_sta=0 ;; # not found
	esac
	if [ "$ap_program" = "HE" ]; then
                [ -z "$global_ap_num_users_ofdma" ] && [ -n "$user_given_num_users_ofdma" ] && nof_sta=$user_given_num_users_ofdma
                [ -n "$global_ap_num_users_ofdma" ] && nof_sta=$global_ap_num_users_ofdma
		debug_print "nof_sta:$nof_sta"
       fi
}

get_common_uci_path()
{
	# Get list of bands from DB
	ap_radio0_band=`$UCI_CMD get wireless.radio0.band 2>/dev/null`
	ap_radio2_band=`$UCI_CMD get wireless.radio2.band 2>/dev/null`
	ap_radio4_band=`$UCI_CMD get wireless.radio4.band 2>/dev/null`

	local ap_band i radio24 radio5 radio6 wlan_name radio
	for i in 0 2 4
	do
		# Map the band and the radio index
		eval ap_band=\${ap_radio${i}_band}
		if [ "$ap_band" = "2.4GHz" ]
		then
			ap_radio_24g_uci_path=wireless.radio${i}
			radio24=radio${i}
			ap_uci_24g_idx=10
			[ $i -gt 0 ] && ap_uci_24g_idx=42
		elif [ "$ap_band" = "5GHz" ]
		then
			ap_radio_5g_uci_path=wireless.radio${i}
			radio5=radio${i}
			ap_uci_5g_idx=42
			[ $i -eq 0 ] && ap_uci_5g_idx=10
		elif [ "$ap_band" = "6GHz" ]
		then
			ap_radio_6g_uci_path=wireless.radio${i}
			radio6=radio${i}
			ap_uci_6g_idx=74
		fi
	done

	for i in 24 5 6
	do
		eval radio=\${radio${i}}
		[ -z $radio ] && continue
		wlan_name=`uci show wireless | grep device=\'${radio}\' | head -n 1`
		wlan_name=${wlan_name%.*}
		wlan_name=`$UCI_CMD get ${wlan_name}.ifname`
		wlan_name=${wlan_name%%\.*}
		eval ap_wlan_${i}g_name=$wlan_name
	done
}

get_interface_details()
{
	debug_print get_interface_details $*

	# Not using default values and always find a way to detect the interface
	ap_channel=0
	ap_second_channel=0
	ap_interface=
	ap_channel_freq=0
	ap_wlan_tag=0
	ap_cur_wlan_tag=

	while [ "$1" != "" ]; do
		upper "$1" token
		shift
		case "$token" in
			CHANNEL)
				local channel_given="done"
				ap_tmp_ch=`echo $1 | grep ";"`
				if [ $? -eq 0 ]; then
					ap_channels=$1
					ap_channel=${ap_channels%%;*}
					ap_second_channel=${ap_channels##*;}
					CONFIGURE_BOTH_BANDS=1
				else
					ap_channel=$1
					[ "$1" = "37" ] || [ "$1" = "53" ] && global_primary_channel=$1
				fi
			;;
			INTERFACE)
				local interface_given="done"
				ap_interface=$1
				global_ap_interface=$1
			;;
			WLAN_TAG)
				local tag_given="done"
				ap_wlan_tag=$1
				ap_ucc_wlan_tag=$1
			;;
			CHNLFREQ)
				local channel_freq_given="done"
				ap_channel_freq=$1
			;;
			NONTXBSSINDEX)
				ap_non_tx_index=$1
			;;
		esac
		shift
	done

	if [ "$tag_given" = "done" ]
	then
		eval ap_cur_wlan_tag=\${CURRENT_WLAN_TAG${ap_ucc_wlan_tag}}
		ap_wlan_tag=$(($ap_wlan_tag - 1))
	fi

	if [ "$channel_given" = "" ] && [ "$interface_given" = "" ] && [ "$tag_given" = "" ] && [ "$channel_freq_given" = "" ] && [ "$CURRENT_RADIO_UCI_PATH" != "" ]
	then
		return
	fi

	CURRENT_6G_RADIO_UCI_PATH=$ap_radio_6g_uci_path
	CURRENT_6G_WLAN_NAME=$ap_wlan_6g_name
	CURRENT_6G_IFACE_UCI_PATH=wireless.default_radio$ap_uci_6g_idx
	CURRENT_5G_RADIO_UCI_PATH=$ap_radio_5g_uci_path
	CURRENT_5G_WLAN_NAME=$ap_wlan_5g_name
	CURRENT_5G_IFACE_UCI_PATH=wireless.default_radio$ap_uci_5g_idx
	CURRENT_24G_RADIO_UCI_PATH=$ap_radio_24g_uci_path
	CURRENT_24G_WLAN_NAME=$ap_wlan_24g_name
	CURRENT_24G_IFACE_UCI_PATH=wireless.default_radio$ap_uci_24g_idx	
	
	if [ "$ap_cur_wlan_tag" = "6G" ] || [ "$ap_channel" -eq "33" ] || [ "$ap_channel" -eq "37" ] || [ "$ap_channel" -eq "53" ] || [ "$ap_interface" = "6G" ] || [ "$ap_channel_freq" -gt "5924" ]
	then
		ap_radio_uci_path=$ap_radio_6g_uci_path
		ap_wlan_name=$ap_wlan_6g_name
		if [ "$tag_given" = "done" ]
		then
			eval CURRENT_WLAN_TAG${ap_ucc_wlan_tag}=6G
			RADIO_6G_TAG=${ap_wlan_tag}
		fi
		[ "$BASE_TAG_6G" = "" ] && BASE_TAG_6G="$ap_wlan_tag"
		ap_wlan_tag=$((ap_wlan_tag-BASE_TAG_6G))
		ap_uci_6g_idx=$(($ap_uci_6g_idx + $ap_wlan_tag))
		ap_interface_uci_path=wireless.default_radio$ap_uci_6g_idx
	elif [ "$ap_cur_wlan_tag" = "5G" ] || [ "$ap_channel" -ge "36" ] || [ "$ap_interface" = "5G" ] || [ "$ap_interface" = "5.0" ]
	then
		ap_radio_uci_path=$ap_radio_5g_uci_path
		
		ap_wlan_name=$ap_wlan_5g_name
		if [ "$tag_given" = "done" ]
		then
			eval CURRENT_WLAN_TAG${ap_ucc_wlan_tag}=5G
			RADIO_5G_TAG=${ap_wlan_tag}
		fi
		[ "$BASE_TAG_5G" = "" ] && BASE_TAG_5G="$ap_wlan_tag"
		ap_wlan_tag=$((ap_wlan_tag-BASE_TAG_5G))
		ap_uci_5g_idx=$(($ap_uci_5g_idx + $ap_wlan_tag))
		ap_interface_uci_path=wireless.default_radio$ap_uci_5g_idx
	else
		ap_radio_uci_path=$ap_radio_24g_uci_path
		ap_wlan_name=$ap_wlan_24g_name
		if [ "$tag_given" = "done" ]
		then
			eval CURRENT_WLAN_TAG${ap_ucc_wlan_tag}=24G
		fi
		[ "$BASE_TAG_24G" = "" ] && BASE_TAG_24G="$ap_wlan_tag"
		ap_wlan_tag=$((ap_wlan_tag-BASE_TAG_24G))
		ap_uci_24g_idx=$(($ap_uci_24g_idx + $ap_wlan_tag))
		ap_interface_uci_path=wireless.default_radio$ap_uci_24g_idx
	fi
	
	CURRENT_RADIO_UCI_PATH="$ap_radio_uci_path"
	CURRENT_WLAN_NAME="$ap_wlan_name"
	CURRENT_IFACE_UCI_PATH="$ap_interface_uci_path"
	CURRENT_IFACE_IFNAME=`$UCI_CMD get $ap_interface_uci_path.ifname`
}

# Get the index in the db (default_radioX) of the last VAP for a radio.
get_last_vap_for_radio()
{
	local cur_radio="$1"

	local all_ifaces=`uci show wireless | grep device=\'$cur_radio\' | awk -F"." '{print $1 "." $2}' | awk -v RS=  '{$1=$1}1' | tr -d "'"`
	local all_iface_idxs=`echo $all_ifaces | sed -e 's/[^0-9 ]//g'`

	if [ "$cur_radio" = "radio0" ]; then
		local max_idx=10
	elif [ "$cur_radio" = "radio2" ]; then
		local max_idx=42
	elif [ "$cur_radio" = "radio4" ]; then
		local max_idx=74
	fi

	local old_IFS=$IFS
	IFS=$ORIG_IFS
	for curr_idx in $all_iface_idxs
	do
		if [ $curr_idx -lt 100 ] && [ $curr_idx -gt $max_idx ]
		then
			max_idx=$curr_idx
		fi
	done
	IFS=$old_IFS

	echo $max_idx
}

get_new_wlan_name_for_radio()
{
	local last_vap_idx="$1"
	local base_wlan=`$UCI_CMD get wireless.default_radio${last_vap_idx}.ifname`
	base_wlan=${base_wlan%%.*}

	for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14
	do
		local cur_wlan=$base_wlan.$i
		local output=`uci show wireless | grep ifname=\'$cur_wlan\'`
		if [ "$output" = "" ]; then
			break
		fi

		if [ "$i" = "14" ]; then # 14 is the max vap allowed
			cur_wlan="ERROR"
		fi
	done

	echo $cur_wlan
}

add_interface()
{
	if [ "$1" != "" ]; then
		local cur_radio_path=wireless.$1
	else
		local cur_radio_path=$CURRENT_RADIO_UCI_PATH
	fi

	local cur_radio=`echo $cur_radio_path | awk -F"." '{print $2}'`
	local last_vap_idx=`get_last_vap_for_radio $cur_radio`
	local new_vap_idx=$((last_vap_idx+1))

	last_vap="wireless.default_radio$last_vap_idx"
	new_vap="wireless.default_radio$new_vap_idx"

	local last_vap_mac=`$UCI_CMD get $last_vap.macaddr`
	local last_vap_flex_mac_hexa=`echo $last_vap_mac | awk -F":" '{print $6}'`
	local last_vap_flex_mac="0x$last_vap_flex_mac_hexa"
	tc_name=`get_test_case_name $glob_ssid`
	#function called only for multibss enabled
	if [ "$ucc_program" = "eht" -o "$ucc_program" = "he" -o "$tc_name" = "4.67.1" ]; then
		local new_vap_flex_mac=`printf '%x' $((last_vap_flex_mac+1))`
	else
		local new_vap_flex_mac=`printf '%x' $((last_vap_flex_mac+2))`
	fi
	local new_vap_flex_mac_len=${#new_vap_flex_mac}

	if [ $new_vap_flex_mac_len -eq 1 ]; then
		new_vap_flex_mac="0$new_vap_flex_mac"
	elif [ $new_vap_flex_mac_len -gt 2 ]; then
		new_vap_flex_mac=`echo -n $new_vap_flex_mac | tail -c 2`
	fi

	local new_vap_mac=`echo $last_vap_mac | awk -F":" '{print $1 ":" $2 ":" $3 ":" $4 ":" $5 ":"}'`
	new_vap_mac="$new_vap_mac$new_vap_flex_mac"

	local new_wlan=`get_new_wlan_name_for_radio $last_vap_idx`

	if [ "$new_wlan" = "ERROR" ]; then
		error_print "No place for new VAP"
		return
	fi

	$UCI_CMD set $new_vap='wifi-iface'
	$UCI_CMD set $new_vap.device=$cur_radio
	$UCI_CMD set $new_vap.ifname=$new_wlan
	$UCI_CMD set $new_vap.macaddr=$new_vap_mac
	$UCI_CMD set $new_vap.mode='ap'
	local tmp=`$FACTORY_CMD vap $new_wlan`
	sleep 1 # workaround , let vap factory uci configuration populate
	$UCI_CMD set $new_vap.mode='ap' # make sure atleast mode is set else vap will not come up
	if [ "$MODEL" != "AX11000" ] && [ "$MODEL" != "WAV700_AP" ] && [ "$OS_NAME" = "UGW" ]; then
		chown rpcd:rpcd $UCI_DB_PATH/wireless
		chmod +r $UCI_DB_PATH/wireless
	fi

	echo $new_vap | awk -F"." '{print $2}'
}

create_interface()
{
	debug_print create_interface $*

	ap_uci_vap_idx=$(echo $CURRENT_IFACE_UCI_PATH | sed -e 's/[^0-9 ]//g')
	ap_uci_base_idx=$((ap_uci_vap_idx-ap_wlan_tag))

	ap_base_mac=`$UCI_CMD get wireless.default_radio${ap_uci_base_idx}.macaddr`
	ap_flex_mac_hexa=$(echo $ap_base_mac | awk -F":" '{print $6}')
	ap_flex_mac="0x$ap_flex_mac_hexa"
	ap_new_flex_mac=$(printf '%x' $((ap_flex_mac + 2*ap_wlan_tag)))
	ap_new_flex_mac_len=${#ap_new_flex_mac}

	if [ $ap_new_flex_mac_len -eq 1 ]; then
		ap_new_flex_mac="0$ap_new_flex_mac"
	elif [ $ap_new_flex_mac_len -gt 2 ]; then
		ap_new_flex_mac=$(echo -n $ap_new_flex_mac | tail -c 2)
	fi

	ap_part_mac=$(echo $ap_base_mac | awk -F":" '{print $1 ":" $2 ":" $3 ":" $4 ":" $5 ":"}')
	ap_mew_mac="$ap_part_mac$ap_new_flex_mac"

	ap_radio_name=$(echo $CURRENT_RADIO_UCI_PATH | awk -F"." '{print $2}')

	$UCI_CMD set $CURRENT_IFACE_UCI_PATH='wifi-iface'
	$UCI_CMD set $CURRENT_IFACE_UCI_PATH.device=$ap_radio_name
	$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ifname=$CURRENT_WLAN_NAME.$ap_wlan_tag
	$UCI_CMD set $CURRENT_IFACE_UCI_PATH.macaddr=$ap_mew_mac
	$UCI_CMD set $CURRENT_IFACE_UCI_PATH.mode='ap'
	$FACTORY_CMD vap $CURRENT_WLAN_NAME.$ap_wlan_tag
	if [ "$MODEL" != "AX11000" ] && [ "$MODEL" != "WAV700_AP" ] && [ "$OS_NAME" = "UGW" ]; then
		chown rpcd:rpcd $UCI_DB_PATH/wireless
		chmod +r $UCI_DB_PATH/wireless
	fi
}

get_uci_security_mode()
{
	upper "$1" ap_sigma_security_mode

	case "$ap_sigma_security_mode" in
		NONE)
			ap_uci_security_mode="none"
		;;
		WPA-PSK)
			ap_uci_security_mode="psk"
		;;
		WPA2-PSK)
			ap_uci_security_mode="psk2"
		;;
		WPA-ENT)
			ap_uci_security_mode="wpa"
		;;
		WPA2-ENT)
			ap_uci_security_mode="wpa2"
		;;
		WPA2-PSK-MIXED)
			ap_uci_security_mode="psk-mixed+tkip+ccmp"
		;;
		WPA2-MIXED)
			ap_uci_security_mode="wpa-mixed+tkip+ccmp"
		;;
		WPA2-PSK-SAE)
			ap_uci_security_mode="sae-mixed"
		;;
		SAE)
			ap_uci_security_mode="sae"
		;;
		OWE)
			ap_uci_security_mode="owe"
		;;
		SUITEB)
			ap_uci_security_mode="eap192"
		;;
		SAE-EXT-KEY)
			ap_uci_security_mode="sae-ext-key"
		;;
		*)
			error_print "Unsupported security mode: $ap_sigma_security_mode"
			ap_uci_security_mode=""
		;;
	esac
}

get_uci_encryption()
{
	upper "$1" ap_sigma_encrypt

	case "$ap_sigma_encrypt" in
		WEP)
			ap_uci_encrypt="wep"
		;;
		*)
			error_print "Unsupported encryption: $ap_sigma_encrypt"
			ap_uci_encrypt=""
		;;
	esac
}

get_uci_pairwise_cipher()
{
	ap_cipher=""
	temp_cipher=$*
	for ap_pairwise_cipher in $temp_cipher; do
		temp_ap_cipher=`echo $ap_pairwise_cipher | awk -F"-" '{print $2}'`
		ap_cipher_len=`echo $ap_pairwise_cipher | awk -F"-" '{print $3}'`

		if [ "$ap_cipher_len" = "256" ]; then
			temp_ap_cipher="${temp_ap_cipher}-${ap_cipher_len}"
		fi
		debug_print "temp_ap_cipher : $temp_ap_cipher"
		ap_cipher="${ap_cipher} ${temp_ap_cipher}"
	done
	ap_cipher="${ap_cipher:1}"
}

get_uci_pmf()
{
	upper "$1" ap_sigma_pmf

	case "$ap_sigma_pmf" in
		REQUIRED)
			ap_uci_pmf=2
		;;
		OPTIONAL)
			ap_uci_pmf=1
		;;
		DISABLED)
			ap_uci_pmf=0
		;;
		*)
			error_print "Unsupported pmf: $ap_sigma_pmf"
			ap_uci_pmf=""
		;;
	esac
}

get_freq_from_chan()
{
	ap_freq=`iw $1 info | grep "\[$2\]" | awk '{print $2}' | sed 's/\.[0-9]$//'`
}

get_central_freq_vht()
{
	local ap_chan=$1
	local ap_width=$2
	local ap_phy=$3

	case $ap_width in
		20)
			get_freq_from_chan $ap_phy $ap_chan
			ap_centr_freq=$ap_freq
		;;
		40)
			case $ap_chan in
				36|40) ap_centr_freq=5190 ;;
				44|48) ap_centr_freq=5230 ;;
				52|56) ap_centr_freq=5270 ;;
				60|64) ap_centr_freq=5310 ;;
				100|104) ap_centr_freq=5510 ;;
				108|112) ap_centr_freq=5550 ;;
				116|120) ap_centr_freq=5590 ;;
				124|128) ap_centr_freq=5630 ;;
				132|136) ap_centr_freq=5670 ;;
				149|153) ap_centr_freq=5755 ;;
				157|161) ap_centr_freq=5795 ;;
			esac
		;;
		40-)
			ap_centr_chan=$((ap_chan-2))
			get_freq_from_chan $ap_phy $ap_centr_chan
			ap_centr_freq=$ap_freq
		;;
		40+)
			ap_centr_chan=$((ap_chan+2))
			get_freq_from_chan $ap_phy $ap_centr_chan
			ap_centr_freq=$ap_freq
		;;
		80)
			case $ap_chan in
				36|40|44|48) ap_centr_freq=5210 ;;
				52|56|60|64) ap_centr_freq=5290 ;;
				100|104|108|112) ap_centr_freq=5530 ;;
				116|120|124|128) ap_centr_freq=5610 ;;
				132|136|140|144) ap_centr_freq=5690 ;;
				149|153|157|161) ap_centr_freq=5775 ;;
				49|53|57|61) ap_centr_freq=6225 ;;
				33|37|41|45) ap_centr_freq=6145 ;;
			esac
		;;
		160)
			case $ap_chan in
				36|40|44|48|52|56|60|64) ap_centr_freq=5250 ;;
				100|104|108|112|116|120|124|128) ap_centr_freq=5570 ;;
			esac
		;;
		3201)
			case $ap_chan in
				1|5|9|13|17|21|25|29|33|37|41|45|49|53|57|61)
					ap_centr_freq=6105
					ap_centr_freq1=6185
				;;
			esac
		;;
		3202)
			case $ap_chan in
				33|37|41|45|49|53|57|61|65|69|73|77|81|85|89|93)
					ap_centr_freq=6265
					ap_centr_freq1=6185
				;;
			esac
		;;
	esac
}

get_apqos_data_idx()
{
	case $1 in
		vo)
			ap_data_idx=0
		;;
		vi)
			ap_data_idx=1
		;;
		be)
			ap_data_idx=2
		;;
		bk)
			ap_data_idx=3
		;;
	esac
}

set_uci_offset()
{
	ap_offset_mode=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.htmode`
	ap_offset_mode_num=`echo $ap_offset_mode | sed -e 's/[^0-9 ]//g'`

	if [ "$ap_offset" != "" ] && [ $ap_offset_mode_num -eq 40 ]
	then
		ap_new_mode=`echo $ap_offset_mode | sed 's/[^a-zA-Z0-9]//g'`
		ap_new_mode="${ap_new_mode}${ap_offset}"
		$UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode=$ap_new_mode
	fi
}

config_neighbor()
{
	local band=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.band`
	if [ "$band" = "5GHz" ]; then
		local op_class=73
		local op_chan=36
	elif [ "$band" = "2.4GHz" ]; then
		local op_class=51
		local op_chan=01
	elif [ "$band" = "6GHz" ]; then
		local op_class=131
		local op_chan=37
	fi
	local hex_pref=`printf '%02x' $ap_neighbor_pref`
	local nr=`echo $ap_neighbor_bssid | sed 's/\://g'`
	nr="${nr}00000000${op_class}${op_chan}070301${hex_pref}"
	ap_cmd="$HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME set_neighbor_per_vap $CURRENT_IFACE_IFNAME $ap_neighbor_bssid ssid=\\\"MBO_NEIGHBOR\\\" nr=$nr"
	ap_tmp=`eval "$ap_cmd"`
}

merge_pref_non_pref_mbo_neighbors()
{
	#club pref and non_pref neighbors, once wnm received, non_pref will be removed
	CURRENT_NEIGHBORS=$CURRENT_NEIGHBORS" "$CURRENT_NON_PREF_NEIGHBORS
	echo $CURRENT_NEIGHBORS > /tmp/mbo_neighbors
 	rm /tmp/non_pref_mbo_neighbors
	CURRENT_NON_PREF_NEIGHBORS=""
}
add_neighbor_for_channel()
{
	local channel="$1"
	local new_curr_neighbors=""
	local non_pref_neighbors=""

	local old_IFS=$IFS
	IFS=$ORIG_IFS

	CURRENT_NEIGHBORS=`cat /tmp/mbo_neighbors`
	if [ -f "/tmp/non_pref_mbo_neighbors" ]; then
		CURRENT_NON_PREF_NEIGHBORS=`cat /tmp/non_pref_mbo_neighbors`
	fi
	for single_neighbor in $CURRENT_NON_PREF_NEIGHBORS
	do
		local curr_chan=`echo "$single_neighbor" | awk -F"," '{print $4}'`
		if [ "$curr_chan" == "$channel" ]; then
			new_curr_neighbors="$single_neighbor $new_curr_neighbors"
		else
			non_pref_neighbors="$single_neighbor $non_pref_neighbors"
		fi
	done

	CURRENT_NEIGHBORS=$new_curr_neighbors" "$CURRENT_NEIGHBORS
	CURRENT_NON_PREF_NEIGHBORS=$non_pref_neighbors
	echo $CURRENT_NEIGHBORS > /tmp/mbo_neighbors
	echo $CURRENT_NON_PREF_NEIGHBORS > /tmp/non_pref_mbo_neighbors

	IFS=$old_IFS
}

# Finds the neighbour entry which matches with APUT mac or given channel and sets the corresponding preference value to zero.
update_neighbor_pref()
{
	n_channel=$1
	if [ "$n_channel" = "" ]; then
		local wlan_2g=`$UCI_CMD get $CURRENT_24G_IFACE_UCI_PATH.macaddr`
		local wlan_5g=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.macaddr`
		local wlan_6g=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.macaddr`
	fi
	local old_IFS=$IFS
	IFS=$ORIG_IFS

	CURRENT_NEIGHBORS=`cat /tmp/mbo_neighbors`
	TMP_SET_PREF=/tmp/neighbor_list

	for s in $CURRENT_NEIGHBORS
	do
		echo $s | tr ',' '\n' > $TMP_SET_PREF # replace comma with newline for parsing.

		tmp=`echo "$s" | awk -F"," '{print $1}'`
		channel=`echo "$s" | awk -F"," '{print $4}'`
		bssid=`echo "$tmp" | awk -F"=" '{print $2}'`

		if [ "$bssid" = "$wlan_2g" ] || [ "$bssid" = "$wlan_5g" ] || [ "$bssid" = "$wlan_6g" ] || [ "$channel" = "$n_channel" ]; then
			# The current neighbour's bssid is matched with one of APUT link's mac. Make pref value to 0.
			sed -i "6s/.*/0/" $TMP_SET_PREF
		fi

		# replace newline with comma and replace last comma with space.
		tr '\n' ',' < $TMP_SET_PREF > /tmp/output
		neighbor=`cat /tmp/output`
		neighbor=`echo $neighbor | sed 's/,$//g'`

		updated_neighbor="$neighbor $updated_neighbor"
	done

	rm /tmp/output
	rm $TMP_SET_PREF
	echo $updated_neighbor > /tmp/mbo_neighbors
	updated_neighbor=""
	IFS=$old_IFS
}

remove_neighbor_for_channel()
{
	local channel="$1"
	local new_curr_neighbors=""
	local non_pref_neighbors=""

	local old_IFS=$IFS
	IFS=$ORIG_IFS

	CURRENT_NEIGHBORS=`cat /tmp/mbo_neighbors`
	if [ -f "/tmp/non_pref_mbo_neighbors" ]; then
		CURRENT_NON_PREF_NEIGHBORS=`cat /tmp/non_pref_mbo_neighbors`
	fi
	for single_neighbor in $CURRENT_NEIGHBORS
	do
		local curr_chan=`echo "$single_neighbor" | awk -F"," '{print $4}'`
		if [ "$curr_chan" != "$channel" ]; then
			new_curr_neighbors="$single_neighbor $new_curr_neighbors"
		else
			non_pref_neighbors="$single_neighbor $non_pref_neighbors"
		fi
	done

	CURRENT_NEIGHBORS=$new_curr_neighbors
	CURRENT_NON_PREF_NEIGHBORS=$non_pref_neighbors" "$CURRENT_NON_PREF_NEIGHBORS
	echo $CURRENT_NEIGHBORS > /tmp/mbo_neighbors
	echo $CURRENT_NON_PREF_NEIGHBORS > /tmp/non_pref_mbo_neighbors

	IFS=$old_IFS
}

##### Command Functions #####

ap_ca_version()
{
	send_running
	send_complete ",version,$CA_VERSION"
}

ca_get_version()
{
	send_running
	send_complete ",version,$CA_VERSION"
}

uci_commit_wireless()
{
	$UCI_CMD commit wireless
	if [ "$MODEL" != "AX11000" ] && [ "$MODEL" != "WAV700_AP" ] && [ "$OS_NAME" = "UGW" ]; then
		chown rpcd:rpcd $UCI_DB_PATH/wireless
		chmod +r $UCI_DB_PATH/wireless
	fi
}

run_dwpal_cli_cmd()
{
	local i=0
	while [ "$i" -lt "20" ]; do
		if [ -n "$interface" ]; then
			vap_is_up=`ifconfig | grep -c $interface`
		else
			vap_is_up="1" #MBO Deamon doesn't set interface, no need to wait as it is in infinite loop
		fi
		if [ "$vap_is_up" -gt "0" ] ; then
			if [ "$OS_NAME" = "UGW" ]; then
				local _cmd="dwpal_cli"
				while [ "$1" != "" ]; do
					_cmd="$_cmd '$1'"
					shift
				done
				if [ "$MODEL" == "AX11000" ] || [ "$MODEL" == "WAV700_AP" ]; then
					ap_event_msg=`/bin/sh -c "export LD_LIBRARY_PATH=/opt/intel/lib; $_cmd"`
				else
					ap_event_msg=`sudo cap_provide "nwk:nwk,rpcd" "cap_net_admin,cap_net_bind_service" /bin/sh -c "export LD_LIBRARY_PATH=/opt/intel/lib; $_cmd"`
					ap_event_msg=`echo $ap_event_msg | sed -e "s/Userinput: nwk:nwk,rpcd //"`
				fi
			else
				ap_event_msg=`dwpal_cli "$@"`
			fi
		
			echo $ap_event_msg
			break 
		else 
			sleep 1
			i=$((i+1))
		fi
	done
	if [ "$i" -eq "10" ]; then
		error_print "Timeout- VAP is down"
		send_invalid ",errorCode,220"	
	fi
}

check_6g_tc()
{
	local ssid_6g="Wi-Fi_6E_"
	local is_6g_tc=`eval echo $glob_ssid | grep $ssid_6g`
	if [ "$ucc_program" = "he" -a -n "$is_6g_tc" ]; then
		echo "1"
	else
		echo "0"
	fi
}

ap_uci_commit_and_apply()
{
	ap_changes=`$UCI_CMD changes`
	local _cmd="dwpal_cli"

	if [ "$ucc_program" = "wpa3" ]; then
		ap_tmp=`ap_config_transition_owe`
	fi

#	if [ `eval check_6g_tc` = "1" ]; then
#		ap_tmp=`eval $UPDATE_RNR_UCI enable`
#	fi

	uci_commit_wireless
	ap_tmp=`eval $WIFI_RELOAD_CMD`

	if [ "$MODEL" == "AX11000" ] || [ "$MODEL" == "WAV700_AP" ]; then
		[ -n "$ap_changes" ] && ap_tmp=`sh -c "export LD_LIBRARY_PATH=/opt/intel/lib; $_cmd -ihostap -mMain -vwlan0.0 -vwlan2.0 -dd -l"AP-ENABLED" -l"INTERFACE_RECONNECTED_OK""`
	elif [ "$OS_NAME" = "UGW" ]; then
		[ -n "$ap_changes" ] && ap_tmp=`sudo -u nwk sh -c "export LD_LIBRARY_PATH=/opt/intel/lib; $_cmd -ihostap -mMain -vwlan0.0 -vwlan2.0 -dd -l"AP-ENABLED" -l"INTERFACE_RECONNECTED_OK""`
	fi

	#WA in 6.1.1 to enable ICMP pings with frame size > 15000
	if [ "$OS_NAME" = "UGW" ]; then
		switch_cli GSW_QOS_METER_CFG_SET dev=1 nMeterId=33 nEbs=17000 nCbs=17000 > /dev/null 2>&1
	fi
}

arguments_file_initializer(){
	echo "export current_radio=$1" >> /tmp/sigma_hf_arguments
	echo "export glob_ssid=$2" >> /tmp/sigma_hf_arguments
}

ap_send_addba_req()
{
	send_running
	send_complete
}

get_connected_stations()
{
	[ -z "$1" ] && echo "get_connected_stations: ERROR: Missing radio name" && return
	vaps=`uci show wireless | grep ifname | grep $1 | cut -d"=" -f2 |grep "\." | tr -d "'"`
	connected_stations=0
	for interface_name in $vaps; do
		connected_stations_vap=`iw dev $interface_name station dump | grep -c Station`
		connected_stations=$((connected_stations+connected_stations_vap))
	done
	echo $connected_stations
}

refresh_static_plan()
{
	info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
	send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
	connected_stations=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`
	if [ "$connected_stations" = "1" ] || [ "$connected_stations" = "2" ] || [ "$connected_stations" = "3" ] || [ "$connected_stations" = "4" ]; then
		send_plan_for_${connected_stations}_users ${CURRENT_WLAN_NAME} $connected_stations $CURRENT_RADIO_UCI_PATH $glob_ssid $CURRENT_WLAN_NAME.0
	fi
}

refresh_static_plan_for_eht()
{
	CURRENT_WLAN_NAME=$1
	CURRENT_RADIO_UCI_PATH=$2
	connected_stations=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`
	if [ "$connected_stations" = "1" ] || [ "$connected_stations" = "2" ] || [ "$connected_stations" = "3" ] || [ "$connected_stations" = "4" ]; then
		if [ "$global_emlsr_tb_ul_ofdma" != "1" ]; then
			info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
			send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
		fi
		send_plan_for_${connected_stations}_users ${CURRENT_WLAN_NAME} $connected_stations $CURRENT_RADIO_UCI_PATH $glob_ssid $CURRENT_WLAN_NAME.0
	fi
}

reload_driver_with_acceleration()
{
	remove_modules="mtlkroot.ko mac80211.ko cfg80211.ko compat.ko"
	insmod_modules=`echo "$remove_modules" | awk '{ for (i=NF; i>1; i--) printf("%s ",$i); print $1; }'`
	module_path=`find /lib/modules/ -iname mtlk.ko | rev|cut -d"/" -f2-|rev`
	debug_print "kernel module path:$module_path"

	rmmod $module_path/mtlk.ko;
	for i in $remove_modules
	do
		ap_tmp=`rmmod $module_path/$i`
	done

	for i in $insmod_modules
	do
		ap_tmp=`insmod $module_path/$i`
	done
	if [ "$1" = "0" ]; then
		ap_tmp=`touch /tmp/driver_reload`
		ap_tmp=`insmod $module_path/mtlk.ko`
	else
		ap_tmp=`insmod $module_path/mtlk.ko fastpath=1,1,1 ahb_off=1 loggersid=255,255 dual_pci=1,1`
		ap_tmp=`rm /tmp/driver_reload`
	fi
	
	[ "$ucc_program" != "eht" ] && ap_tmp=`eval $WIFI_RELOAD_CMD`
}

enable_mld_t2lm_negotiation_support()
{
	local CURRENT_IFACE_UCI_PATH=$1
	ap_get_debug_hostap_conf_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
	let ap_get_debug_hostap_conf_idx=ap_get_debug_hostap_conf_idx+1
	ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx))"
	$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_t2lm_support=1"
}

set_mld_mediumsync_params()
{
	local CURRENT_IFACE_UCI_PATH=$1

	ap_get_debug_hostap_conf_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
	let ap_get_debug_hostap_conf_idx=ap_get_debug_hostap_conf_idx+1
	ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx))"
	$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mld_mediumsync_present=$global_ap_mld_mediumsync_present"

	if [ $global_ap_mld_mediumsync_present -eq 1 ]; then
		let ap_get_debug_hostap_conf_idx=ap_get_debug_hostap_conf_idx+1
		ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx))"
		$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mld_mediumsync_duration=$global_ap_mld_mediumsync_delay"

		let ap_get_debug_hostap_conf_idx=ap_get_debug_hostap_conf_idx+1
		ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx))"
		$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mld_mediumsync_ofdmedthresh=$global_ap_mld_mediumsync_ofdmedthresh"

		let ap_get_debug_hostap_conf_idx=ap_get_debug_hostap_conf_idx+1
		ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx))"
		$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mld_mediumsync_maxtxop=$global_ap_mld_mediumsync_maxtxop"
	fi
}

check_for_static_puncturing_test_cases() {
	local tc=0
	if [ "$global_ap_punctchannel" != "" ]; then
		tc=53437
	fi
	echo $tc
}

check_for_btm_test_cases() {
	local tc=0
	if [ "$global_ap_reg_domain" != "" -a "$global_ap_t2lm_negotiation_support" = "" ]; then
		tc=556
	fi
	echo $tc
}

check_and_force_eht_fixed_rate_cfg() {
	if [ "$ucc_program" = "eht" ]; then
		#List of testcases that need NSS=1, MCS=9 Fixed Rate Cfg
		if [ "$ucc_type" = "testbed" ]; then
			local tc_id=0
			tc_id=`check_for_static_puncturing_test_cases`
			[ $tc_id -eq 0 ] && tc_id=`check_for_btm_test_cases`
			if [ $tc_id -gt 0 ]; then
				touch $FORCE_EHT_FIXED_RATE_CFG_FILE_PATH
				[ -e $FORCE_EHT_FIXED_RATE_CFG_FILE_PATH ] && debug_print "Force EHT fixed rate cfg for TC $tc_id"
			fi #Force EHT fixed rate cfg
		fi #EHT Testbed
	fi #EHT
}

#The program name is provided as WPA3 in the WPA3 testing in the EHT(WiFi 7) certification in the CAPI commands
#We were relying on the program name to form an AP-MLD and to set some key security parameters
#Now we are updating the program name to EHT based on 2 conditions,
#First The program name should be given as WPA3
#Second The SSID provided in the CAPI command contains the string "Wi-Fi_7"
#It ensures that it will not imapct the other legacy WPA3 program testing in 11AX mode
check_and_update_prog_for_wifi7()
{
	ap_ssid=`echo $1 | grep "Wi-Fi_7"`

	if [ "$ucc_program" = "wpa3" ] && [ -n "$ap_ssid" ]; then
		ucc_program="eht"

		touch $FORCE_EHT_FIXED_RATE_CFG_FILE_PATH
		touch $FORCE_AKM_SUITE_TYPE_TO_SAE_AND_SAEEXTKEY_FILE_PATH
		ap_eht_reset_default
		force_ap_cleanup
		sleep 10

		get_common_uci_path
		
		iw dev wlan0 iwlwav sDoSimpleCLI 129 1
		iw dev wlan2 iwlwav sDoSimpleCLI 129 1
		iw dev wlan4 iwlwav sDoSimpleCLI 129 1
		upper "$ucc_program" ap_program
	else
		[ -e $FORCE_AKM_SUITE_TYPE_TO_SAE_AND_SAEEXTKEY_FILE_PATH ] && rm -rf $FORCE_AKM_SUITE_TYPE_TO_SAE_AND_SAEEXTKEY_FILE_PATH
	fi
}

check_for_WiFi6R2_test_case()
{
	debug_print "SSID received: $1"
	ap_ssid=`echo $1 | grep "Wi-Fi6R2"`
	if [ -n "$ap_ssid" ] &&	[ "$ap_channel" -ge "1" -a "$ap_channel" -le "11" ]; then
		is_wifi6r2_2gtc="True"
	else
		is_wifi6r2_2gtc="False"
	fi
	debug_print "is R2 testcase: $is_wifi6r2_2gtc"
}


ap_set_wireless()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	[ -z "$mlo_counter" ] && mlo_counter=0

	get_common_uci_path
	get_interface_details $@

	ap_temp_ret=`$UCI_CMD get $CURRENT_IFACE_UCI_PATH 2>/dev/null`
	if [ "$ap_temp_ret" = ""  ]; then
		create_interface
	fi

	debug_print ap_radio_uci_path $CURRENT_RADIO_UCI_PATH
	debug_print ap_interface_uci_path $CURRENT_IFACE_UCI_PATH
	is_interface_known=`echo $@ | grep -i Interface`

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
		NAME)
			debug_print "set parameter ap_name=$1"
		;;
		INTERFACE)
			# skip since it was read in loop before
		;;
		WLAN_TAG)
			debug_print "set parameter ap_wlan_tag=$1"
		;;
		SSID)
			glob_ssid="$1"
			check_and_update_prog_for_wifi7 $glob_ssid  #This is required to pass the WPA3 certification tests in WiFi 7, Check the definition for detailed comments.
			check_for_WiFi6R2_test_case $glob_ssid
			static_plan_init_debug_infra
			debug_print "set parameter ap_ssid=$1"
			
			tc_name=`get_test_case_name $glob_ssid`
			if [ -z "$ap_non_tx_bss_index" ]; then
				#Set SSID only for legacy programs
				#SSID is set for EHT in the later part during MLD configurations
				if [ "$ap_program" != "EHT" ]; then
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ssid=$1
				else
					arguments_file_initializer $CURRENT_RADIO_UCI_PATH $glob_ssid
				fi
			fi 
			
			if [ -z $global_num_non_tx_bss ]; then
				if [ "$tc_name" = "4.68.1" ] || [ "$tc_name" = "5.73.1" ]; then
					info_print "tc_name = $tc_name ==> set ap_ofdma='dl'"
					ap_ofdma="dl"
				fi
			else
				if [ -z "$global_ap_cohosted_bss" ]; then
					ap_ssid_non_tx_bss_index="$1"
					debug_print "ap_ssid_non_tx_bss_index:$ap_ssid_non_tx_bss_index"
				else
					ap_ssid_cohosted_bss_index="$1"
					debug_print "ap_ssid_cohosted_bss_index:$ap_ssid_cohosted_bss_index"
				fi
			fi
			if [ $ap_second_channel -gt 0 ]; then
				$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.ssid=$1
				$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.ssid=$1
			else
				if [ "$change_ssid_one_time" != "1" ]; then
					if [ "$tc_name" = "4.67.1" ]; then
						change_ssid_one_time=1
					fi
					[ -z "$ap_non_tx_bss_index" -a "$ap_program" != "EHT" ] && $UCI_CMD set $CURRENT_IFACE_UCI_PATH.ssid=$1
				fi
			fi
			if [ "$glob_ssid" = "4.2.28" ]; then
				$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.s11nProtection=2
				$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.s11nProtection=2
			fi
			if [ "$ucc_program" = "vht" ]; then
				if [ "$glob_ssid" = "VHT-4.2.5" ] || [ "$glob_ssid" = "VHT-4.2.5A" ] || [ "$glob_ssid" = "VHT-4.2.20" ] || [ "$glob_ssid" = "VHT-4.2.21" ] || [ "$glob_ssid" = "VHT-4.2.40" ]; then
					info_print "Disable Aggr"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.sAggrConfig=0 1 64
				fi
			fi
			if [ "$glob_ssid" = "ioPL98=2bv" ] && [ $ap_channel -lt 36 ]; then
				$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.vendor_vht=0			
			fi
			if [ "$glob_ssid" = "4.2.12" ]; then
				$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.auth_cache=1
			fi
			if [ "$glob_ssid" = "WiFi1-4.2.6" -o "$glob_ssid" = "WiFi1-4.2.6E" ] && [ "$OS_NAME" = "RDKB" ]; then
				cli system/extswitch/setMacAging 0 1
			fi
			tc_name=`get_test_case_name $glob_ssid`
			if [ "$tc_name" = "4.44.1" ] && [ "$OS_NAME" = "RDKB" ]
			then
				cli sys/pp/setDefensiveMode 1
			fi
			#Workaround required for 11n-4.2.30_3SS AMSDU Rx test
			if [ "$glob_ssid" = "4.2.30" ] && [ "$OS_NAME" = "RDKB" ]
			then
				cli sys/pp/setBridgeMode 1
			fi
			if [ "$ap_program" != "EHT" ] && [ "$tc_name" = "4.14.1" ] && [ $ap_channel -lt 36 ]
			then
				iw dev $CURRENT_WLAN_NAME iwlwav sTxopConfig 0x1FF 0 32767 4
				iw dev $CURRENT_WLAN_NAME iwlwav s11nProtection 1
			fi
			if [ "$ap_program" = "EHT" ] && [ "$tc_name" = "4.2.1" ]; then
				iw dev $CURRENT_24G_WLAN_NAME iwlwav sTxopConfig 0x1FF 0 32767 4
				iw dev $CURRENT_24G_WLAN_NAME iwlwav s11nProtection 1
				iw dev $CURRENT_5G_WLAN_NAME iwlwav sTxopConfig 0x1FF 0 32767 4
				iw dev $CURRENT_5G_WLAN_NAME iwlwav s11nProtection 1
				iw dev $CURRENT_6G_WLAN_NAME iwlwav sTxopConfig 0x1FF 0 32767 4
				iw dev $CURRENT_6G_WLAN_NAME iwlwav s11nProtection 1
			fi
			# on WAVE700, disabled BA as workaround for the test VHT 4.2.58, VHT 4.2.42, WLANRTSYS-54023
			if [ "$MODEL" = "WAV700_AP" ] && [ "$glob_ssid" = "VHT-4.2.58" -o "$glob_ssid" = "VHT-4.2.42" ]; then
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.sAggrConfig=1 0 256
			fi
			if [ "$glob_ssid" = "HE-4.31.1_24G" ]; then
				if [ "$OS_NAME" = "UGW" ]; then #on LGM, beerocks is disabled else use root user instead sscripts
					ap_tmp=`sudo -u sscript -- /etc/init.d/prplmesh stop`
					sleep 3 # wait for process to stop
				elif [ "$OS_NAME" = "RDKB" ]; then
					ap_tmp=`systemctl stop systemd-prplmesh.target`
					sleep 3 # wait for process to stop
				fi
			fi
			if [ "$glob_ssid" = "NVCX@7" -a "$OS_NAME" = "RDKB" ]; then
				iptables -t mangle -D FORWARD -m state ! --state NEW -j DSCP --set-dscp 0x00
				iptables -t mangle -D FORWARD -m state --state NEW -j DSCP --set-dscp 0x14
				cli system/pp/setProtSesTimeout UDP 20
			fi
			#Workaround for legacy 11n/11ac where wlan4 interface doesnt come and so MODEL is not set
			atom_cpu=`version.sh | grep "CPU:" | grep -i atom`
			if [ -n "$atom_cpu" ]; then
				if [ "$hw_type" = "0x70" ] || [ "$hw_type" = "0x71" ] || [ "$hw_type" = "0x72" ]; then
					MODEL="WAV700_AP"
				else
					MODEL="AX11000"
				fi
			fi
			if [ "$glob_ssid" = "4.2.3" -a "$OS_NAME" = "RDKB" ]; then
				debug_print "reload driver with acceleration disable"
				reload_driver_with_acceleration 0
			elif [ -f "/tmp/driver_reload" ]; then
				reload_driver_with_acceleration 1
			fi

		;;
		CHANNEL)
			debug_print "set parameter ap_channel=$1"
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.channel=$ap_channel
			if [ "$ap_channel" -ge "50" -a "$ap_channel" -le "144" ]; then
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.doth=1
				iw dev $CURRENT_WLAN_NAME iwlwav s11hChCheckTime 1
				iw dev $CURRENT_WLAN_NAME iwlwav s11hRadarDetect 0
			fi
			if [ $ap_second_channel -gt 0 ]; then
				if [ "$ap_radio_5g_uci_path" = "$CURRENT_RADIO_UCI_PATH" ]; then
					$UCI_CMD set $ap_radio_24g_uci_path.channel=$ap_second_channel
				else
					$UCI_CMD set $ap_radio_5g_uci_path.channel=$ap_second_channel
				fi
			fi
		;;
		MODE)
			debug_print "set parameter glob_ap_mode=$1"
			glob_ap_mode=$1
			debug_print "ap mode is set to : $glob_ap_mode"
			#TODO: currently there is no need to support this
			#$UCI_CMD set $ap_radio_uci_path.hwmode=$1
		;;
		WME)
			debug_print "set parameter ap_wme=$1"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.wmm=$1
		;;
		WMMPS)
			debug_print "set parameter ap_wmmps=$1"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.uapsd_advertisement_enabled=$1
		;;
		RTS)
			# param not supported
			debug_print "set parameter ap_rts=$1"
		;;
		FRGMNT)
			# param not supported
			debug_print "set parameter ap_frgmnt=$1"
		;;
		FRGMNTSUPPORT)
			# param not supported
			debug_print "set parameter ap_frgmntsupport=$1"
		;;
		PWRSAVE)
			# param not supported
			debug_print "set parameter ap_pwrsave=$1"
		;;
		BCNINT)
			debug_print "set parameter ap_bcnint=$1"
			if [ "$ap_program" = "EHT" ]; then
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.beacon_int=$1
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.beacon_int=$1
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.beacon_int=$1
			else
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.beacon_int=$1
			fi
		;;
		DTIM)
			debug_print "set parameter ap_dtim=$1"
			if [ "$ap_program" = "EHT" ] && [ "$ap_interface" = "" ]; then
				$UCI_CMD set $CURRENT_24G_IFACE_UCI_PATH.dtim_period=$1
				$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.dtim_period=$1
				$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.dtim_period=$1
			else
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.dtim_period=$1
			fi
		;;
		ECSA_IE)
			debug_print "set parameter advertise_ecsa_ie=$1"
			local ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'advertise_ecsa_ie' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			if [ "$ap_interface" = "" ]; then
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="advertise_ecsa_ie=$1"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="advertise_ecsa_ie=$1"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="advertise_ecsa_ie=$1"
			else
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="advertise_ecsa_ie=$1"
			fi
		;;
		SGI20)
			debug_print "set parameter ap_sgi20=$1"
			lower "$1" ap_enable_input
			if [ "$ap_enable_input" = "enable" ]; then
				ap_sgi_20=1
			else
				ap_sgi_20=0
			fi
			$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.short_gi_20=$ap_sgi_20
		;;
		SGI40)
			debug_print "set parameter ap_sgi40=$1"
			lower "$1" ap_enable_input
			if [ "$ap_enable_input" = "enable" ]; then
				ap_sgi_40=1
			else
				ap_sgi_40=0
			fi
			$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.short_gi_40=$ap_sgi_40
		;;
		SGI80)
			debug_print "set parameter ap_sgi80=$1"
			lower "$1" ap_enable_input
			if [ "$ap_enable_input" = "enable" ]; then
				ap_sgi_80=1
			else
				ap_sgi_80=0
			fi
			$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.short_gi_80=$ap_sgi_80
		;;
		STBC_TX)
			debug_print "set parameter ap_stbc_tx=$1"
			#TODO: Comma separated list of the number of spatial streams and the number of space time streams.
			#For example 1spatial stream and 2 space time streams = 1;2
			#$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.tx_stbc=$1
			local ap_tx_bf_val ap_sBfMode_local ap_debug_iw_post_up_idx
			if [ "$1" = "1"  -o "$1" = "1;2" ]; then
				ap_tx_bf_val="STBC1X2" 
			elif [ "$1" = "2" -o "$1" = "2;4" ]; then
				ap_tx_bf_val="STBC2X4"
			else
				debug_print "not correct STBC_TX value"
				send_invalid ",errorCode,2"
			fi
			ap_sBfMode_local=`convert_bf_mode $ap_tx_bf_val`	
			debug_print "converted ap_sBfMode_local=$ap_sBfMode_local"
			ap_debug_iw_post_up_idx=`uci show wireless | grep $CURRENT_RADIO_UCI_PATH | grep debug_iw_post_up | cut -d"=" -f 1 | cut -d"_" -f5 | sort -n | tail -1`
			if [ -z "$ap_debug_iw_post_up_idx" ]; then
				ap_debug_iw_post_up_idx=1
			else
				let "ap_debug_iw_post_up_idx=ap_debug_iw_post_up_idx+1"
			fi
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.debug_iw_post_up_$ap_debug_iw_post_up_idx="sBfMode $ap_sBfMode_local"
		;;
		BW_SGNL)
			debug_print "set parameter ap_bw_sgnl=$1"
		;;
		DYN_BW_SGNL)
			debug_print "set parameter ap_dyn_bw_sgnl=$1"
			if [ "$1" = "enable" ]; then
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.debug_hostap_conf_1="sRTSmode=1 0"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.s11nProtection=2
			elif [ "$1" = "disable" ]; then
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.debug_hostap_conf_1="sRTSmode=0 1"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.s11nProtection=2
					iw dev wlan0 iwlwav sOnlineACM 0
					iw dev wlan2 iwlwav sOnlineACM 0
			fi
		;;
		STBC_RX)
			debug_print "set parameter ap_stbc_rx=$1"
			$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.rx_stbc=$1
		;;
		RADIO)
			debug_print "set parameter ap_radio=$1"
			if [ "$1" = "off" ]; then
				ap_radio_op="down"
			elif [ "$1" = "on" ]; then
				ap_radio_op="up"
			else
				send_invalid ",errorCode,2"
				return
			fi
			if [ -n "$is_interface_known" ]; then
				ap_radio_ifaces=`uci show wireless | grep $CURRENT_WLAN_NAME | awk -F"=" '{print $2}'`
			else
				ap_radio_ifaces=`uci show wireless | grep ifname | awk -F"=" '{print $2}'`
			fi
			if [ "$ap_program" != "EHT" ]; then
				for ap_radio_iface in $ap_radio_ifaces; do
					res=`eval ifconfig $ap_radio_iface $ap_radio_op`
				done
			else
				[ "$ap_radio_op" = "down" ] && wifi down
				[ "$ap_radio_op" = "up" ] && wifi up
			fi
			#Verify if interfaces were up for the radio
			if [ "$ap_radio_op" = "up" ]; then
				local ap_radio_verify_up=0
				if [ -z "$is_interface_known" ]; then
					ap_radio_verify_up=`verify_interfaces_up`
				else
					ap_radio_verify_up=`verify_interfaces_up $CURRENT_WLAN_NAME`
				fi
				
				if [ $ap_radio_verify_up -eq 1 ]; then
					error_print "Interfaces are not up after radio ON"
					send_invalid ",errorCode,220"
					return
				fi
			fi
		;;
		P2PMGMTBIT)
			# do nothing
			debug_print "set parameter ap_p2pbit=$1"
		;;
		CHANNELUSAGE)
			# do nothing
			debug_print "set parameter ap_channelusage=$1"
		;;
		TDLSPROHIBIT)
			# do nothing
			debug_print "set parameter ap_tdls=$1"
		;;
		TDLSCHSWITCHPROHIBIT)
			# do nothing
			debug_print "set parameter ap_tdlschannel=$1"
		;;
		WIDTH)
			debug_print "set parameter ap_width=$1"
			ap_width=$1
			ap_curr_mode=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.htmode`
			ap_curr_prefix=`echo "${ap_curr_mode//[^[:alpha:]]/}"`
			if [ "$ap_width" = "320" ]; then
				[ "$ap_channel_freq" = "6105" ] && $UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode="EHT320_1"
				[ "$ap_channel_freq" = "6265" ] && $UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode="EHT320_2"
			else
				if [ "$ucc_program" = "eht" ] && [ "$ap_width" = "40" ]; then
					[ "$ap_interface" = "5G" ] && $UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode=${ap_curr_prefix}40+
					[ "$ap_interface" = "6G" ] && $UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode=${ap_curr_prefix}40-
				else
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode=$ap_curr_prefix$1
				fi
			fi
		;;
		OFFSET)
			debug_print "set parameter ap_offset=$1"
			lower "$1" ap_offset_input
			if [ "$ap_offset_input" = "below" ]; then
				ap_offset="-"
			elif [ "$ap_offset_input" = "above" ]; then
				ap_offset="+"
			fi
		;;
		COUNTRY) ## NB: Extension parameter
			debug_print "set parameter ap_country=$1"
		;;
		COUNTRYCODE)
			debug_print "set parameter ap_countrycode=$1"
			radios=`uci show wireless | grep country | cut -d"." -f1-2`
			for radio in $radios
			do
				$UCI_CMD set $radio.country=$1
			done
			radio_6ghz_disabled=`uci show wireless | grep 6GHz | cut -d"." -f1-2`
			$UCI_CMD set $radio_6ghz_disabled.disabled='1' #currently 6GHz channel support not defined for all countrycode
	;;
		REG_DOMAIN) ## NB: Extension parameter
			# country3 value represents the environment of countrycode.
			# "0x04" represents Global operating class
			if [ "$ucc_program" = "eht" ]; then
				debug_print "set parameter ap_reg_domain=$1"
				lower "$1" ap_reg_domain
				lower "$1" global_ap_reg_domain
				if [ "$ap_reg_domain" = "global" ] ; then
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.country3="0x04"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.country3="0x04"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.country3="0x04"
				fi
			fi
		;;
		CELLULAR_CAP_PREF)
			debug_print "set parameter ap_cellular_cap_pref=$1"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.mbo_cell_aware=1
		;;
		GAS_CB_DELAY)
			debug_print "set parameter ap_gas_cb_delay=$1"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.gas_comeback_delay=$1
		;;
		DOMAIN)
			debug_print "set parameter ap_domain=$1"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.mobility_domain=$1
		;;
		FT_OA)
			debug_print "set parameter ap_ft_oa=$1"
			lower "$1" ap_enable_input
			if [ "$ap_enable_input" = "enable" ]; then
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ieee80211r=1
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ft_over_ds=0
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.nasid=CGR-APUT.intel.com
			else
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ieee80211r=0
			fi
		;;
		FT_BSS_LIST)
			debug_print "set parameter ap_ft_bss_list=$1"
			ap_r0kh_r1kh_key=11002200330044005500660077008800
			ap_macaddr=`$UCI_CMD get $CURRENT_IFACE_UCI_PATH.macaddr`
			ap_mac_no_delimiter=`echo "$ap_macaddr" | tr -d :`
			ap_other_mac="$1"
			ap_other_mac_no_delimiter=`echo "$ap_other_mac" | tr -d :`
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.r1_key_holder="$ap_mac_no_delimiter"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.nasid="$ap_mac_no_delimiter"
			$UCI_CMD add_list $CURRENT_IFACE_UCI_PATH.r0kh="$ap_other_mac,$ap_other_mac_no_delimiter,$ap_r0kh_r1kh_key"
			$UCI_CMD add_list $CURRENT_IFACE_UCI_PATH.r1kh="$ap_other_mac,$ap_other_mac,$ap_r0kh_r1kh_key"
			$UCI_CMD add_list $CURRENT_IFACE_UCI_PATH.r0kh="$ap_macaddr,$ap_mac_no_delimiter,$ap_r0kh_r1kh_key"
			$UCI_CMD add_list $CURRENT_IFACE_UCI_PATH.r1kh="$ap_macaddr,$ap_macaddr,$ap_r0kh_r1kh_key"
			#$UCI_CMD set $CURRENT_IFACE_UCI_PATH.iapp_interface="brlan0" TODO: do we need it?
			#$UCI_CMD set $CURRENT_IFACE_UCI_PATH.debug_hostap_conf="ft_psk_generate_local=1" TODO: do we need it?
		;;
		PROGRAM)
			debug_print "set parameter ap_program=$1"
			upper "$ucc_program" ap_program
		;;
		PROG)
			debug_print "set parameter ap_prog=$1"
			upper "$ucc_program" ap_program
		;;
		FORCEEHTTXMCS)
			debug_print "set parameter glob_ap_forced_mcs=$1"
			glob_ap_forced_mcs=$1
		;;
		FORCESMPDUTX)
			debug_print "set parameter ap_forced_smpdu=$1"
			lower "$1" ap_forced_smpdu
		;;	
		TXEMLOMN)
			debug_print "set parameter ap_tx_omn_resp=$1"
			lower "$1" ap_tx_omn_resp
			[ "$ap_tx_omn_resp" = "disable" ] && global_ap_tx_omn_resp_disable=1
		;;
		MEDIUMSYNC_PRESENT)
			debug_print "set parameter ap_mld_mediumsync_present=$1"
			global_ap_mld_mediumsync_present=$1
		;;
		MEDIUMSYNC_DELAY)
			debug_print "set parameter ap_mld_mediumsync_delay=$1"
			global_ap_mld_mediumsync_delay=$1
		;;
		MEDIUMSYNC_OFDMEDTHRESHOLD)
			debug_print "set parameter ap_mld_mediumsync_ofdmedthresh=$1"
			global_ap_mld_mediumsync_ofdmedthresh=$1
		;;
		MEDIUMSYNC_MAXTXOP)
			debug_print "set parameter ap_mld_mediumsync_maxtxop=$1"
			global_ap_mld_mediumsync_maxtxop=$1
		;;
		OCESUPPORT)
			debug_print "set parameter ap_oce_support=$1"
			lower "$1" ap_oce_support
		;;
		FILSDSCV)
			debug_print "set parameter ap_fils_dscv=$1"
			lower "$1" ap_fils_dscv
			if [ "$ap_fils_dscv" = "enable" ]; then
				ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame fils`
			else
				ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame disable`
			fi
		;;
		UNSOLICITEDPROBERESP)
			debug_print "set parameter ap_unsolicitedproberesp=$1"
			lower "$1" ap_unsolicitedproberesp
			if [ "$ap_unsolicitedproberesp" = "enable" ]; then
				ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame probe`
			else
				ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame disable`
			fi
		;;
		CADENCE_UNSOLICITEDPROBERESP)
			debug_print "set parameter ap_cadence_unsolicitedproberesp=$1"
			lower "$1" ap_cadence_unsolicitedproberesp
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.unsolicited_frame_duration=$ap_cadence_unsolicitedproberesp
		;;
		ACTIVEIND_UNSOLICITEDPROBERESP)
			debug_print "set parameter ap_activeind_unsolicitedproberesp=$1"
			lower "$1" ap_activeind_unsolicitedproberesp
			#ap_tmp=`eval $UPDATE_RNR_UCI enable`
		;;
		FILSDSCVINTERVAL)
			debug_print "set parameter ap_fils_dscv_interval=$1"
		;;
		BROADCASTSSID)
			debug_print "set parameter ap_broadcast_ssid=$1"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ignore_broadcast_ssid=$1
		;;
		FILSHLP)
			debug_print "set parameter ap_filshlp=$1"
			lower "$1" ap_filshlp
		;;
		NAIREALM)
			debug_print "set parameter ap_nairealm=$1"
		;;
		RNR)
			debug_print "set parameter ap_rnr=$1"
			lower "$1" ap_rnr
#			if [ "$ap_rnr" = "enable" ]; then
#				ap_tmp=`eval $UPDATE_RNR_UCI enable`
#			elif [ "$ap_rnr" = "disable" ]; then
#				ap_tmp=`eval $UPDATE_RNR_UCI disable`
#			fi
		;;
		DEAUTHDISASSOCTX)
			debug_print "set parameter ap_deauth_disassoc_tx=$1"
		;;
		BLESTACOUNT)
			debug_print "set parameter ap_ble_sta_count=$1"
		;;
		BLECHANNELUTIL)
			debug_print "set parameter ap_ble_channel_util=$1"
		;;
		BLEAVAILADMINCAP)
			debug_print "set parameter ap_ble_avail_admin_cap=$1"
		;;
		AIRTIMEFRACT)
			debug_print "set parameter ap_air_time_fract=$1"
		;;
		DATAPPDUDURATION)
			debug_print "set parameter ap_data_ppdu_duration=$1"
		;;
		DHCPSERVIPADDR)
			debug_print "set parameter ap_dhcp_serv_ip_addr=$1"
		;;
		NSS_MCS_CAP)
			debug_print "set parameter ap_nss_mcs_cap=$1"
			ap_nss_mcs_cap=$1
		;;
		FILSCAP)
			debug_print "set parameter ap_filscap=$1"
			lower "$1" ap_filscap
		;;
		BAWINSIZE)
			debug_print "set parameter ap_oce_ba_win_size=$1"
		;;
		DATAFORMAT)
			debug_print "set parameter ap_oce_data_format=$1"
		;;
		ESP_IE)
			debug_print "set parameter ap_oce_esp_ie=$1"
		;;
		AMPDU)
			debug_print "set parameter ap_ampdu=$1"
			lower "$1" ap_ampdu
		;;
		AMSDU)
			debug_print "set parameter ap_amsdu=$1"
			lower "$1" ap_amsdu
		;;
		MCS_FIXEDRATE)
			debug_print "set parameter global_mcs_fixedrate=$1"
		;;
		SPATIAL_RX_STREAM)
			debug_print "set parameter ap_spatial_rx_stream=$1"
			ap_spatial_rx_stream=$1

		;;
		SPATIAL_TX_STREAM)
			debug_print "set parameter ap_spatial_tx_stream=$1"
			ap_spatial_tx_stream=$1
		;;
		TXSP_STREAM)
			debug_print "set parameter ap_spatial_tx_stream=$1"
			ap_spatial_tx_stream=$1
		;;
		RXSP_STREAM)
			debug_print "set parameter ap_spatial_rx_stream=$1"
			ap_spatial_rx_stream=$1
		;;	
		BCC)
			debug_print "set parameter ap_bcc=$1"
			lower $1 ap_bcc
		;;
		LDPC)
			debug_print "set parameter ap_ldpc=$1"
			lower $1 ap_ldpc
		;;
		NOACK)
			# param not supported
			debug_print "set parameter ap_no_ack=$1"
			if [ "$ap_no_ack" != "" ]; then
				error_print "Unsupported value - ap_no_ack:$ap_no_ack"
				send_error ",errorCode,120"
				return 
			fi

		;;
		OFDMA)
			debug_print "set parameter ap_ofdma=$1"
			lower "$1" ap_ofdma
			if [ "$ap_ofdma" = "dl-20and80" ]; then
				ap_ofdma="dl"
			fi
			[ "$ap_ofdma" = "ul" ] && global_ap_ul_ofdma=1
			lower "$1" glob_ap_ofdma
		;;
		PPDUTXTYPE)
			debug_print "set parameter ap_ppdutxtype=$1"
			ap_ppdutxtype=$1
			if [ "$ap_ppdutxtype" = "SU" ]; then
				ap_tmp=`eval $UPDATE_RNR_UCI he_beacon enable`
			fi
		;;
		SPECTRUMMGT)
			# do nothing
			debug_print "set parameter ap_specrummgt=$1"
		;;
		NUMUSERSOFDMA)
			debug_print "set parameter global_ap_num_users_ofdma=$1"
			lower "$1" global_ap_num_users_ofdma
		;;
		TXBF)
			debug_print "set parameter ap_tx_bf=$1"
			lower "$1" ap_tx_bf
			lower "$1" global_ap_tx_bf
		;;
		NONTRIGGER_TXBF)
			debug_print "set parameter ap_non_trig_tx_bf=$1"
			lower "$1" ap_non_trig_tx_bf
		;;	
		SUBEAMFORMERMODE)
			debug_print "set parameter ap_su_beamformer=$1"
			ap_su_beamformer=$1
		;;
		MUBEAMFORMERMODE)
			debug_print "set parameter ap_mu_beamformer=$1"
			ap_mu_beamformer=$1
			[ "$ap_program" = "EHT" ] && [ "$ap_mu_beamformer" = "1" ] && global_ap_mimo="dl"
		;;
		NUMSOUNDDIM)
			debug_print "set parameter ap_num_sound_dim=$1"
			lower "$1" ap_num_sound_dim
			if [ "$ap_num_sound_dim" != "" ]; then
				debug_print "ap_num_sound_dim:$ap_num_sound_dim"
				if [ "$ap_num_sound_dim" -gt 4 ]; then
					error_print "Unsupported value - ap_num_sound_dim:$ap_num_sound_dim"
					send_error ",errorCode,185"
					return
				fi
			fi
		;;
		VHT_CAP_160_CW)
			# do nothing
			debug_print "set parameter ap_vht_cap_160_bw=$1"
		;;
		VHT_EXTNSS)
			debug_print "set parameter ap_vht_extnss=$1"
			lower "$1" ap_vht_extnss			
		;;
		MU_EDCA)
			debug_print "set parameter ap_mu_edca=$1"
			lower "$1" ap_mu_edca
		;;
		ACKTYPE)
			# do nothing
			debug_print "set parameter ap_acktype=$1"
		;;
		MU_TXBF)
			debug_print "set parameter global_mu_txbf=$1"
			lower "$1" global_mu_txbf
			tc_name=`get_test_case_name $glob_ssid`
			if [ "$ucc_program" = "vht" -a "$tc_name" = "4.2.56" ]; then
				ap_debug_iw_post_up_idx=`uci show wireless | grep $CURRENT_RADIO_UCI_PATH | grep debug_iw_post_up | cut -d"=" -f 1 | cut -d"_" -f5 | sort -n | tail -1`
				if [ -z "$ap_debug_iw_post_up_idx" ]; then
					ap_debug_iw_post_up_idx=1
				else
					let "ap_debug_iw_post_up_idx=ap_debug_iw_post_up_idx+1"
				fi
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.debug_iw_post_up_$ap_debug_iw_post_up_idx="sMuOperation 1"
				/lib/netifd/sigma_mbo_daemon.sh &  #To catch AP-STA-CONNECT event
			fi	
		;;
		TRIG_MAC_PADDING_DUR)
			# do nothing default is 16usec
			debug_print "set parameter ap_trig_mac_padding_dur=$1"
		;;
		BA_PARAM_AMSDU_SUPPORT)
			# same implementation as AMSDU
			debug_print "set parameter ap_ba_param_amsdu_support=$1"
			lower "$1" ap_ba_param_amsdu_support
			if [ "$ap_program" = "EHT" ]; then
			    if [ "$ap_ba_param_amsdu_support" = "1" ]; then
			        ap_ba_param_amsdu_support="enable"
			    elif [ "$ap_ba_param_amsdu_support" = "0" ]; then
			        ap_ba_param_amsdu_support="disable"
			    else
			        error_print "BA_Param_AMSDU_Support Invalid Value"
			        send_error ",errorCode,172"
			    fi
			fi
			ap_amsdu="$ap_ba_param_amsdu_support"
		;;
		ADDBAREQ_BUFSIZE)
			debug_print "set parameter ap_addbareq_bufsize=$1"
			lower "$1" ap_addbareq_bufsize
		;;
		ADDBARESP_BUFSIZE)
			debug_print "set parameter ap_addbaresp_bufsize=$1"
			lower "$1" ap_addbaresp_bufsize
		;;
		ADDBA_REJECT)
			debug_print "set parameter ap_addba_reject=$1"
			lower "$1" ap_addba_reject
		;;
		GREENFIELD)
			debug_print "set parameter ap_greenfield=$1"
			lower "$1" ap_enable_input
			if [ "$ap_enable_input" = "enable" ]; then
				ap_greenfield=1
			else
				ap_greenfield=0
			fi

			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.greenfield=$ap_greenfield
		;;
		BA_RECV_STATUS)
			# do nothing
			debug_print "set parameter ap_ba_recv_status=$1"
		;;
		OMCONTROL)
			debug_print "set parameter ap_omcontrol=$1"
			lower "$1" ap_omcontrol
		;;
		EHT_OMCONTROL)
			debug_print "set parameter ap_eht_omcontrol=$1"
			lower "$1" ap_eht_omcontrol
		;;
		NONOFDMA_UL_MUMIMO)
			debug_print "set parameter ap_ul_mumimo=$1"
			ap_ul_mumimo=$1
		;;
		MIMO)
			debug_print "set parameter global_ap_mimo=$1"
			lower "$1" global_ap_mimo
			if [ "$global_ap_mimo" = "ul" ]; then
				ap_debug_iw_post_up_idx=`uci show wireless | grep $CURRENT_RADIO_UCI_PATH | grep debug_iw_post_up | cut -d"=" -f 1 | cut -d"_" -f5 | sort -n | tail -1`
				if [ -z "$ap_debug_iw_post_up_idx" ]; then
					ap_debug_iw_post_up_idx=1
				else
					ap_debug_iw_post_up_idx=$((ap_debug_iw_post_up_idx+1))
				fi
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.debug_iw_post_up_$ap_debug_iw_post_up_idx="sDoSimpleCLI 3 13 2000 0"
			fi
		;;
		TWT_RESPSUPPORT)
			debug_print "set parameter ap_twt_respsupport=$1"
			lower "$1" ap_twt_respsupport
		;;
		SRCTRL_SRVALUE15ALLOWED)
			debug_print "set parameter ap_srctrl_srvalue15allowed=$1"
			lower "$1" ap_srctrl_srvalue15allowed
		;;
		MINMPDUSTARTSPACING)
			debug_print "set parameter ap_min_mpdu_start_spacing=$1"
			ap_min_mpdu_start_spacing=$1
		;;
		MBSSID)
			debug_print "set parameter global_ap_mbssid=$1"
			lower "$1" global_ap_mbssid
			[ "$global_ap_mbssid" != "enable" ] && global_ap_mbssid=""
#			if [ "$global_ap_mbssid" = "enable" -a `eval check_6g_tc` = "1" ]; then
#				ap_tmp=`eval $UPDATE_RNR_UCI enable`
#			fi
		;;
		NUMNONTXBSS)
			([ $1 -lt 1 ] || [ $1 -gt 7 ]) && error_print "NumNonTxBSS invalid value '$1'" && send_invalid ",errorCode,95" && return
			global_num_non_tx_bss=$1
			debug_print "global_num_non_tx_bss:$global_num_non_tx_bss"
		;;
		NONTXBSSINDEX)
			debug_print "set parameter ap_non_tx_bss_index=$1"
			([ $1 -lt 1 ] || [ $1 -gt 8 ]) && error_print "NonTxBSSIndex invalid value '$1'" && send_invalid ",errorCode,96" && return
			ap_non_tx_bss_index=$1
		;;
		MLD_ID)
			debug_print "set parameter ap_mld_id=$1"
			ap_mld_id=$1
		;;
		COHOSTEDBSS)
			debug_print "set parameter global_ap_cohosted_bss=$1"
			lower "$1" global_ap_cohosted_bss
		;;
		NUMCOHOSTEDBSS)
			([ $1 -lt 1 ] || [ $1 -gt 7 ]) && error_print "NumCoHostedBSS invalid value '$1'" && send_invalid ",errorCode,97" && return
			global_num_cohosted_bss=$1
			debug_print "global_num_cohosted_bss:$global_num_cohosted_bss"
		;;
		COHOSTEDBSSINDEX)
			debug_print "set parameter ap_cohosted_bss_index=$1"
			([ $1 -lt 1 ] || [ $1 -gt 8 ]) && error_print "CoHostedBSSIndex invalid value '$1'" && send_invalid ",errorCode,98" && return
			ap_cohosted_bss_index=$1
		;;
		HE_TXOPDURRTSTHR)
		lower "$1" ap_he_txop_dur_rts_thr_conf
			if [ "$ap_he_txop_dur_rts_thr_conf" = "enable" ]; then
				ap_he_txop_dur_rts_thr_conf=10
			elif [ "$ap_he_txop_dur_rts_thr_conf" = "disable" ]; then
				ap_he_txop_dur_rts_thr_conf=1023
			else
				ap_he_txop_dur_rts_thr_conf=""
			fi
			
			# We support here "Enable" & "Disable" only (tests # 4.66.1, 5.71.1)
			# 1. "Enable" - any value between 0..1022
			# 2. "Disable" - 1023

		;;
		MCS_32|MCS32)
			# do nothing
			debug_print "set parameter ap_mcs_32=$1"
		;;
		CHNLFREQ)
			debug_print "set parameter ap_channel_freq=$1"
			lower "$1" ap_channel_freq
		;;
		BAND6GONLY)
			debug_print "set parameter ap_band6gonly=$1"
			lower "$1" ap_band6gonly
			iw wlan0 iwlwav sEnableRadio 0
			iw wlan2 iwlwav sEnableRadio 0
			# Enable UPR for DUT mode and FILS for testbed mode by default in BAND6GONLY scenario
			# Check if there was an explicit configuration prior to BAND6GONLY to avoid override of config
			local ap_curr_unsolicited_mode=`$UCI_CMD get $ap_radio_6g_uci_path.unsolicited_frame_support`
			if [ "$ap_curr_unsolicited_mode" = "0" ] || [ "$ap_curr_unsolicited_mode" = "" ]; then
				if [ "$ucc_type" = "dut" ]; then
					ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame probe`
				else
					ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame fils`
				fi
			fi
		;;
		EXPBCNLENGTH)
			debug_print "ignore EXPBCNLENGTH"
			;;
		RSNXE)
		;;
		BSSMEMSELECT)
		;;
		ERSUDISABLE)
			debug_print "set parameter ap_ERSUdisable=$1"
			lower "$1" ap_ersudisable
			local ap_get_debug_hostap_conf_or_Post_Up_idx=`uci show wireless | grep $CURRENT_RADIO_UCI_PATH | grep 'he_operation_er_su_disable' | cut -d"." -f3 | cut -d"=" -f1`
			if [ -z "$ap_get_debug_hostap_conf_or_Post_Up_idx" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_RADIO_UCI_PATH | cut -d"_" -f4 | cut -d"=" -f1 | sort -n | tail -1`
				ap_get_debug_hostap_conf_or_Post_Up_idx="debug_hostap_conf_$((ap_get_debug_hostap_conf_or_Post_Up_idx+1))"
			fi
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_operation_er_su_disable=$ap_ersudisable"
		;;
		TWTINFOFRAMERX)
			# do nothing
			debug_print "set parameter ap_twtinfoframerx=$1"
		;;
		FULLBW_ULMUMIMO)
			debug_print "set parameter ap_fullbw_ulmumimo=$1"
			local ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_full_bandwidth_ul_mu_mimo' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			local val=0
			if [ -z "$ap_get_debug_hostap_conf_or_Post_Up_idx" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_RADIO_UCI_PATH | cut -d"_" -f4 | cut -d"=" -f1 | sort -n | tail -1`
				ap_get_debug_hostap_conf_or_Post_Up_idx="debug_hostap_conf_$((ap_get_debug_hostap_conf_or_Post_Up_idx+1))"
			fi
			if [ "$1" = "enable" ]; then
				val=1
			elif [ "$1" = "disable" ]; then
				val=0
			fi
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_full_bandwidth_ul_mu_mimo=$val"
		;;
		OMCTRL_ULMUDATADISABLERX)
			debug_print "set parameter ap_omctrl_ulmudatadisablerx=$1"
			local ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mac_om_control_ul_mu_data_disable_rx_support' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			local val=0
			if [ -z "$ap_get_debug_hostap_conf_or_Post_Up_idx" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_RADIO_UCI_PATH | cut -d"_" -f4 | cut -d"=" -f1 | sort -n | tail -1`
				ap_get_debug_hostap_conf_or_Post_Up_idx="debug_hostap_conf_$((ap_get_debug_hostap_conf_or_Post_Up_idx+1))"
			fi
			if [ "$1" = "enable" ]; then
				val=1
			elif [ "$1" = "disable" ]; then
				val=0
			fi
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mac_om_control_ul_mu_data_disable_rx_support=$val"
		;;
		HE_SMPS)
			debug_print "set parameter ap_he_smps=$1" #TODO: currently no processing of this param
			lower "$1" ap_he_smps
			if [ "$ap_he_smps" = "enable" ]; then
				debug_print "enable:HE_SMPS"
			elif [ "$ap_he_smps" = "disable" ]; then
				debug_print "disable:HE_SMPS"
			fi
		;;
		BROADCASTTWT)
			debug_print "set parameter global_ap_btwt=$1 ap_twt_respsupport=$1"
			if [ "$1" = "enable" ]; then
				global_ap_btwt=1
			elif [ "$1" = "disable" ]; then
				global_ap_btwt=0
			fi
			ap_twt_respsupport=$1
		;;
		PREAMBLEPUNCTTX)
			debug_print "set parameter global_ap_preamble_puncture=$1"
			lower "$1" global_ap_preamble_puncture
			local ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_preamble_puncturing_rx' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			local val=0
			if [ -z "$ap_get_debug_hostap_conf_or_Post_Up_idx" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_RADIO_UCI_PATH | cut -d"_" -f4 | cut -d"=" -f1 | sort -n | tail -1`
				ap_get_debug_hostap_conf_or_Post_Up_idx="debug_hostap_conf_$((ap_get_debug_hostap_conf_or_Post_Up_idx+1))"
			fi
			if [ "$1" = "enable" ]; then
				val=1
			elif [ "$1" = "disable" ]; then
				val=0
			fi
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_preamble_puncturing_rx=$val"
		;;
		MBSSID_MU)
			debug_print "set parameter global_ap_mbssid_mu=$1"
			lower "$1" global_ap_mbssid_mu
			if [ "$global_ap_mbssid_mu" = "enable" ]; then
				global_ap_mbssid_mu=1
			elif [ "$global_ap_mbssid_mu" = "disable" ]; then
				global_ap_mbssid_mu=0
			fi
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.vendor_vht=0
		;;
		BSS_MAX_IDLE)
			debug_print "set parameter ap_bss_max_idle=$1"
			#Do nothing as we already enable it in assoc resp by default
			lower "$1" ap_bss_max_idle
			if [ "$ap_bss_max_idle" = "enable" ]; then
				ap_bss_max_idle=1
			elif [ "$ap_bss_max_idle" = "disable" ]; then
				ap_bss_max_idle=0
				error_print "Disable of BSS Max Idle unsupported"
				send_error ",errorCode,120"
				return
			fi
		;;
		BSS_MAX_IDLE_PERIOD)
			debug_print "set parameter ap_bss_max_idle_period=$1"
			local inactivity_period=$1
			#Convert to ms - base unit is in 1000TU
			inactivity_period=$((inactivity_period*1024))
			#Convert to sec and round-up to next integer
			inactivity_period=$((inactivity_period/1000))
			inactivity_period=$((inactivity_period+1))
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.max_inactivity=$inactivity_period
			debug_print "configured inactivity period to $inactivity_period"
		;;
		PUNCTCHANNEL)
			debug_print "set parameter global_ap_punctchannel=$1"
			global_ap_punctchannel=$1
			nof_channels=`echo "$1" | awk -F" " '{print NF}'`
		;;
		EPCS)
			lower "$1" global_ap_eht_epcs
			debug_print "set parameter eht_mac_epcs_prio_access=$1"
			if [ "$global_ap_eht_epcs" != "" ]; then
				if [ "$global_ap_eht_epcs" = "enable" ]; then
					global_ap_eht_epcs=1
				elif [ "$global_ap_eht_epcs" = "disable" ]; then
					global_ap_eht_epcs=0
				else
					error_print "Unsupported value - global_ap_eht_epcs:$global_ap_eht_epcs"
					send_error ",errorCode,198"
					return
				fi
			fi
		;;
		EHTSCS_TRAFFICSUPPORT)
			lower "$1" ap_eht_scs_traffic_support
			debug_print "set parameter eht_scs_traffic_support=$1"
			if [ "$ap_eht_scs_traffic_support" != "" ]; then
				if [ "$ap_eht_scs_traffic_support" = "enable" ]; then
					ap_eht_scs_traffic_support=1
				elif [ "$ap_eht_scs_traffic_support" = "disable" ]; then
					ap_eht_scs_traffic_support=0
				else
					error_print "Unsupported value - ap_eht_scs_traffic_support:$ap_eht_scs_traffic_support"
					send_error ",errorCode,198"
					return
				fi
			fi
		;;
		T2LM_NEGOTIATION_SUPPORT)
			debug_print "set parameter ap_t2lm_negotiation_support=$1"
			global_ap_t2lm_negotiation_support=$1
		;;
		OPCLASS_RNR)
			debug_print "set parameter ap_rnr_op_class=$1"
			ap_rnr_op_class=$1
		;;
		BTMSUPT)
			debug_print "Ignore BTMSUPT"
		;;
		RNR_TBTT_RESERVED)
			debug_print "set parameter ap_rnr_tbtt_res=$1"
			lower "$1" ap_rnr_tbtt_res
		;;
		*)
			error_print "while loop error $1"
			send_invalid ",errorCode,2"
			return
		;;
		esac
		shift
	done
	# Work around for WLANRTSYS-84119. Disabling txop for the test case HE-4.78.2_24G.
	# txop will be disabled for all WiFi6R2 2.4G test cases with UL OFDMA.
	if [ "$is_wifi6r2_2gtc" = "True" ] && [ "$glob_ap_ofdma" = "ul" ] && [ "$ucc_type" = "dut" ]; then
		iw dev wlan0 iwlwav sTxopConfig 511 0 500 4  	#Disable TXOP
	else
		iw dev wlan0 iwlwav sTxopConfig 0 1 20000 4		#Enable TXOP
	fi	

	if [ "$ap_program" = "HE" ] || [ "$ap_program" = "EHT" ]; then
		if [ "$ap_width" != "" ]; then
			if [ "$ap_width" = "20" ]; then
				width_val="20MHz"
			elif [ "$ap_width" = "40" ]; then
				width_val="40MHz"
			elif [ "$ap_width" = "80" ]; then
				width_val="80MHz"
			elif [ "$ap_width" = "160" ]; then
				width_val="160MHz"
			elif [ "$ap_width" = "320" ]; then
				[ "$ap_channel_freq" = "6105" ] && width_val="320_1MHz"
				[ "$ap_channel_freq" = "6265" ] && width_val="320_2MHz"
			else
				debug_print "ap_width:$ap_width"
				width_val="Auto"
			fi
		fi

		###COnfiguring the FW to transmit using EHT PPDU
		if [ "$ap_program" = "EHT" ] && [ "$ap_interface" != "" ]; then
			iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 0
		###COnfiguring the FW to transmit using HE PPDU
		###by default EHT is set in FW
		elif [ "$ap_program" = "HE" ]; then
			iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 1
		fi

		if [ "$width_val" != "" ]; then
			convert_fixed_rate ${width_val}
			[ "$ap_program" != "EHT" ] && set_get_helper_non_debug $CURRENT_RADIO_UCI_PATH.sFixedRateCfg x2=$bw_converted

			# Only in 160 MHz / 5GHz, change channel check time to 1 sec to save configuration time.
			# and disable radar detection to ensure no radar is detected during test and BW stays at 160MHz.
			tc_name=`get_test_case_name $glob_ssid`
			if [ "$width_val" = "160MHz" ] || [ "$tc_name" = "4.60.1" ]; then
				ap_band=`eval $UCI_CMD show $CURRENT_RADIO_UCI_PATH.band | cut -d"=" -f2 | tr -d "'"`
				ap_channel=`eval $UCI_CMD show $CURRENT_RADIO_UCI_PATH.channel | cut -d"=" -f2 | tr -d "'"`
				if [ "$ap_channel" -ge "36" ] && [ "$ap_band" = "5GHz" ]; then
					$UCI_CMD set ${CURRENT_RADIO_UCI_PATH}.doth=1
					iw dev $CURRENT_WLAN_NAME iwlwav s11hChCheckTime 1
					iw dev $CURRENT_WLAN_NAME iwlwav s11hRadarDetect 0
				fi
			fi
			
			# if static plan is on, turn it off, since we are going to change band (SMD will turn it back on).
			info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
			send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH

			[ "$width_val" = "20MHz" ] && ap_txop_com_start_bw_limit=0
			[ "$width_val" = "40MHz" ] && ap_txop_com_start_bw_limit=1
			[ "$width_val" = "80MHz" ] && ap_txop_com_start_bw_limit=2
			[ "$width_val" = "160MHz" ] && ap_txop_com_start_bw_limit=3
			#Host/FW interface is configured with only one bandwidth value(4) for both 320MHz-1 and 320MHz-2 channel
			[ "$width_val" = "320_1MHz" ] && ap_txop_com_start_bw_limit=4
			[ "$width_val" = "320_2MHz" ] && ap_txop_com_start_bw_limit=4

			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x${txop_com_start_bw_limit_idx}=${ap_txop_com_start_bw_limit}
		fi
		
		## WA WLANRTSYS-13765 for TC 4.31.1 and 4.52.1_5G - set fixed rate with 2NSS.
		tc_name=`get_test_case_name $glob_ssid`
		if [ "$tc_name" = "4.31.1" ] ; then
			convert_fixed_rate ${ap_txbandwidth} "ax"
			set_get_helper_non_debug $CURRENT_RADIO_UCI_PATH.sFixedRateCfg x1=0 x2=${bw_converted} x3=4 x4=2 x5=11 x6=2
		elif [ "$tc_name" = "4.52.1" ] && [ $ap_channel -ge "36" ]; then
			onvert_fixed_rate ${ap_txbandwidth} "ax"
			set_get_helper_non_debug $CURRENT_RADIO_UCI_PATH.sFixedRateCfg x1=0 x2=${bw_converted} x3=4 x4=2 x5=11 x6=2
		fi
		#To set the DL-MIMO when TXBF and MU_TXBF parameters are provided in the CAPIs
		#as there is no other parameter to configure the same
		#For TC-5.38.x in EHT
		[ "$ucc_program" = "eht" -a "$glob_ap_ofdma" = "" ] && [ "$ap_tx_bf" = "enable" -a "$global_mu_txbf" = "enable" ] && global_ap_mimo="dl"

		if [ "$ap_ofdma" != "" ]; then
			# JIRA WLANRTSYS-9736: in case of the below tests (4.68.1 & 5.73.1), setting of OFDMA to DL, even if the test was setting it as UL
			tc_name=`get_test_case_name $glob_ssid`
			if [ "$ap_ofdma" != "dl" ] && ([ "$tc_name" = "4.68.1" ] || [ "$tc_name" = "5.73.1" ]); then
				info_print "tc_name = $tc_name (ap_ofdma = $ap_ofdma) ==> overwrite ap_ofdma, set it to 'dl'"
				ap_ofdma="dl"
			fi

			if [ "$ap_ofdma" = "dl" ] || [ "$ap_ofdma" = "ul" ]; then
				if [ "$ap_program" != "EHT" ]; then
					get_nof_sta_per_he_test_case $glob_ssid
					ap_num_users_ofdma=$nof_sta
					arguments_file_initializer $CURRENT_RADIO_UCI_PATH $glob_ssid
					kill_sigmaManagerDaemon
					if [ -z "$global_ap_mbssid_mu" ] || [ "$global_ap_mbssid_mu" != "1" ]; then
						/lib/netifd/sigmaManagerDaemon.sh $CURRENT_WLAN_NAME.0 $ap_num_users_ofdma &
					fi

					if [ "$ap_ofdma" = "dl" ]; then
						glob_ofdma_phase_format=0
					elif [ "$ap_ofdma" = "ul" ]; then
						glob_ofdma_phase_format=1 		
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
						set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x7=1
					fi

					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
					set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x4=${glob_ofdma_phase_format}
					if [ "$ap_num_users_ofdma" != "" ]; then
						set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x5=${ap_num_users_ofdma}
					else
						if [ "$glob_ssid" != "" ]; then
							# check if num_of_users can be obtained from the predefined list (by test plan)
							get_nof_sta_per_he_test_case $glob_ssid
							ap_num_users_ofdma=$nof_sta
							[ "$ap_num_users_ofdma" != "0" ] && set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x5=${ap_num_users_ofdma}
						fi
					fi
					if [ "$ap_program" = "HE" ] && [ "$ap_ofdma" = "ul" ]; then
						debug_print "Sending an IW command to disable the AQM in FW"
						local res=1
						while [ $res != "0" ]; do
							iw dev wlan0 iwlwav sDoSimpleCLI 152 0
							res=$?
							sleep 1
						done
					fi
				elif [ "$ap_program" = "EHT" ]; then
					[ -n "$global_ap_num_users_ofdma" ] && nof_sta=$global_ap_num_users_ofdma
					ap_num_users_ofdma=$nof_sta
					kill_sigmaManagerDaemon

					if [ "$ap_ofdma" = "dl" ]; then
						glob_ofdma_phase_format=0
					elif [ "$ap_ofdma" = "ul" ]; then
						glob_ofdma_phase_format=1 		
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_24G_RADIO_UCI_PATH`
						set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x7=1
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_5G_RADIO_UCI_PATH`
						set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x7=1
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_6G_RADIO_UCI_PATH`
						set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x7=1
					fi

					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_24G_RADIO_UCI_PATH`
					set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x4=${glob_ofdma_phase_format}
					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_5G_RADIO_UCI_PATH`
					set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x4=${glob_ofdma_phase_format}
					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_6G_RADIO_UCI_PATH`
					set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x4=${glob_ofdma_phase_format}

					set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x5=${ap_num_users_ofdma}
					set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x5=${ap_num_users_ofdma}
					set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x5=${ap_num_users_ofdma}
				else
					debug_print "Wrong Program Name"
				fi		
			else
				error_print "Unsupported value - ap_ofdma:$ap_ofdma"
				send_error ",errorCode,150"
				return
			fi

			# set fixed rate for OFDMA MU
			info_print "sDoSimpleCLI 70 1"
			if [ "$ap_program" != "EHT" ]; then
				uci set $CURRENT_RADIO_UCI_PATH.debug_iw_post_up_2="sDoSimpleCLI 70 1"
			else
				uci set $CURRENT_24G_RADIO_UCI_PATH.debug_iw_post_up_2="sDoSimpleCLI 70 1"
				uci set $CURRENT_5G_RADIO_UCI_PATH.debug_iw_post_up_2="sDoSimpleCLI 70 1"
				uci set $CURRENT_6G_RADIO_UCI_PATH.debug_iw_post_up_2="sDoSimpleCLI 70 1"
			fi	
		fi

		# Set coding (LDPC/BCC) for DL
		if [ "$ap_ldpc" != "" ] || [ "$ap_bcc" != "" ]; then
			debug_print "ap_ldpc:$ap_ldpc ap_bcc:$ap_bcc"
			if [ "$ap_ldpc" = "enable" ] && [ "$ap_bcc" = "enable" ]; then
				error_print "Unsupported value - ap_ldpc:$ap_ldpc ap_bcc:$ap_bcc"
				send_error ",errorCode,125"
				return
			elif [ "$ap_ldpc" = "disable" ] && [ "$ap_bcc" = "disable" ]; then
				error_print "Unsupported value - ap_ldpc:$ap_ldpc ap_bcc:$ap_bcc"
				send_error ",errorCode,130"
				return
			fi

			if [ "$ap_ldpc" = "disable" ]; then ap_bcc="enable"; fi
			if [ "$ap_bcc" = "disable" ]; then ap_ldpc="enable"; fi

			if [ "$ap_ldpc" = "enable" ]; then
				# set for SU, only if not OFDMA MU TC
				if [ "$glob_ofdma_phase_format" = "" ]; then
					if [ "$ap_program" != "EHT" ]; then
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.ldpc=1
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.rxldpc=1
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_ldpc_coding_in_payload' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_ldpc_coding_in_payload=1"
					else
						#Do nothing because it is setted to 1 in our default DB
						debug_print "Do Nothing"
					fi
				fi
				
				# set for MU
				for usr_index in 1 2 3 4
				do
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlannUser$ap_usr_index"  x18=1
				done
			elif [ "$ap_bcc" = "enable" ]; then
				# set for SU, only if not OFDMA MU TC
				if [ "$glob_ofdma_phase_format" = "" ]; then 
					if [ "$ap_program" != "EHT" ]; then
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.ldpc=0
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.rxldpc=0
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_ldpc_coding_in_payload' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_ldpc_coding_in_payload=0"
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'enable_he_debug_mode' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="enable_he_debug_mode=1"
					else
						if [ "$tc_name" = "4.11.1" ]; then
							$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.ldpc=0	
							$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.rxldpc=0
							ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'enable_eht_debug_mode' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
							$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="enable_eht_debug_mode=1"
						fi
					fi			
				fi			
				# set for MU
				for usr_index in 1 2 3 4
				do
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlannUser$ap_usr_index" x18=0 
				done
			else
				error_print "Unsupported value - ap_ldpc:$ap_ldpc ap_bcc:$ap_bcc"
				send_error ",errorCode,135"
				return
			fi
		fi

		if [ "$global_mcs_fixedrate" != "" ]; then
			debug_print "global_mcs_fixedrate:$global_mcs_fixedrate"

			# set for SU, only if not OFDMA MU TC
			if [ "$glob_ofdma_phase_format" = "" ]; then #related to ap_ofdma
				set_get_helper_non_debug $CURRENT_RADIO_UCI_PATH.sFixedRateCfg x1=0 x5=4 x7=${global_mcs_fixedrate} x8=5	
			fi			
				
			# set for MU
			for ap_usr_index in 1 2 3 4
			do
				# get MU DL NSS value from FAPI
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				sp_nss_mcs=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x1`
				let ap_nss="$sp_nss_mcs/16+1"

				# calculate the OFDMA MU NSS-MCS value (NSS: bits 5-4, MCS: bits 3-0)
				let ap_ofdma_mu_nss_mcs_val="($ap_nss-1)*16+$global_mcs_fixedrate"

				# set MU DL NSS MCS value
				set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlannUser$ap_usr_index" x1=${ap_ofdma_mu_nss_mcs_val}

				# get MU UL NSS value
				sp_nss_mcs=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x3`
				let ap_nss="$sp_nss_mcs%16"

				# calculate the OFDMA MU NSS-MCS value (NSS: bits 5-4, MCS: bits 3-0)
				let ap_ofdma_mu_nss_mcs_val="($ap_nss-1)*16+$global_mcs_fixedrate"

				# set MU UL NSS MCS value
				set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlannUser$ap_usr_index" x3=${ap_ofdma_mu_nss_mcs_val}
			done
		fi

		#Specifically for wifi 7 EMLSR-STR test ,not to send OMN Response
		if [ "$ap_tx_omn_resp" != "" ]; then #TODO
			if [ "$ap_tx_omn_resp" = "disable" ]; then
				ap_tx_omn_resp_val=1
			else
				ap_tx_omn_resp_val=0
			fi

			debug_print "Disable the OMN Response frame from the AP : $ap_tx_omn_resp_val"
			$SEND_IW_WLAN0 sDoSimpleCLI 140 $ap_tx_omn_resp_val 0 0
			$SEND_IW_WLAN2 sDoSimpleCLI 140 $ap_tx_omn_resp_val 0 0
			$SEND_IW_WLAN4 sDoSimpleCLI 140 $ap_tx_omn_resp_val 0 0
		fi

		if [ "$ap_nss_mcs_cap" != "" ]; then
			debug_print "ap_nss_mcs_cap:$ap_nss_mcs_cap"
			ap_nss_cap=${ap_nss_mcs_cap%%;*}
			ap_mcs_cap=${ap_nss_mcs_cap##*;}

			ap_mcs_min_cap=${ap_mcs_cap%%-*}
			ap_mcs_max_cap=${ap_mcs_cap##*-}
			
			rx_mcs_max_cap=$ap_mcs_max_cap
			tx_mcs_max_cap=$ap_mcs_max_cap

			# calculate the OFDMA MU NSS-MCS value (NSS: bits 5-4, MCS: bits 3-0)
			let ap_ofdma_mu_nss_mcs_val="($ap_nss_cap-1)*16+$ap_mcs_max_cap"
			local nss_1 nss_2 nss_3

			if [ "$ap_mcs_max_cap" = "9" ]; then
				nss_1=${ap_nss_cap}
				nss_2=0
				nss_3=0
			elif [ "$ap_mcs_max_cap" = "11" ]; then
				nss_1=${ap_nss_cap}
				nss_2=${ap_nss_cap}
				nss_3=0	
			elif [ "$ap_mcs_max_cap" = "13" ]; then
				nss_1=${ap_nss_cap}
				nss_2=${ap_nss_cap}
				nss_3=${ap_nss_cap}
			else 
				debug_print "$ap_mcs_max_cap is not supported"
			fi	

			# set for MU
			for ap_usr_index in 1 2 3 4
			do
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				if [ "$global_ap_mimo" != "ul" ]; then	
					set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlannUser$ap_usr_index" x$dl_usr_psdu_rate_per_usp_idx=${ap_ofdma_mu_nss_mcs_val} x$dl_usr_ul_psdu_rate_per_usp_idx=${ap_ofdma_mu_nss_mcs_val}
				fi
			done

			# set the nss mcs capabilities
			ap_nss_mcs_val=`get_nss_mcs_val $ap_nss_cap $ap_mcs_max_cap`
			if [ "$ap_nss_mcs_val" = "" ]; then
				error_print "Unsupported value - ap_nss_cap:$ap_nss_cap ap_mcs_max_cap:$ap_mcs_max_cap"
				send_error ",errorCode,137"
				return
			fi
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz=${ap_nss_mcs_val}"

			## JIRA WLANRTSYS-11028: part0-Rx part1-Tx
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'vht_mcs_set_part0' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part0=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part0=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part0=${ap_nss_mcs_val}"
			global_nss_opt_ul=${ap_nss_cap}

			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz=${ap_nss_mcs_val}"

			# JIRA WLANRTSYS-11028: part0-Rx part1-Tx
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'vht_mcs_set_part1' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part1=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part1=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part1=${ap_nss_mcs_val}"
			global_nss_opt_dl=${ap_nss_cap}

			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mcs_nss_rx_he_mcs_map_160_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_160_mhz=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_160_mhz=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_160_mhz=${ap_nss_mcs_val}"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mcs_nss_tx_he_mcs_map_160_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_160_mhz=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_160_mhz=${ap_nss_mcs_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_160_mhz=${ap_nss_mcs_val}"
			if [ "$ap_program" = "EHT" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_0_9=${nss_1}"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_0_9=${nss_1}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_0_9=${nss_1}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_0_9=${nss_1}"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_0_9=${nss_1}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_0_9=${nss_1}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_0_9=${nss_1}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_0_9=${nss_1}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_0_9=${nss_1}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_0_9=${nss_1}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_320_mhz_rx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_320_mhz_rx_max_nss_eht_mcs_0_9=${nss_1}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_320_mhz_tx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_320_mhz_tx_max_nss_eht_mcs_0_9=${nss_1}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_10_11' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_10_11=${nss_2}"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_10_11=${nss_2}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_10_11=${nss_2}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_10_11' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_10_11=${nss_2}"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_10_11=${nss_2}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_10_11=${nss_2}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_10_11' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_10_11=${nss_2}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_10_11=${nss_2}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_10_11' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_10_11=${nss_2}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_10_11=${nss_2}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_320_mhz_rx_max_nss_eht_mcs_10_11' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_320_mhz_rx_max_nss_eht_mcs_10_11=${nss_2}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_320_mhz_tx_max_nss_eht_mcs_10_11' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_320_mhz_tx_max_nss_eht_mcs_10_11=${nss_2}"
				
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_12_13' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_12_13=${nss_3}"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_12_13=${nss_3}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_12_13=${nss_3}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_12_13' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_12_13=${nss_3}"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_12_13=${nss_3}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_12_13=${nss_3}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_12_13' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_12_13=${nss_3}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_12_13=${nss_3}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_12_13' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_12_13=${nss_3}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_12_13=${nss_3}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_320_mhz_rx_max_nss_eht_mcs_12_13' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_320_mhz_rx_max_nss_eht_mcs_12_13=${nss_3}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_320_mhz_tx_max_nss_eht_mcs_12_13' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_320_mhz_tx_max_nss_eht_mcs_12_13=${nss_3}"
			fi
		fi

		if [ "$ap_spatial_rx_stream" != "" ]; then
			debug_print "ap_spatial_rx_stream:$ap_spatial_rx_stream"
			debug_print "ap_program:$ap_program"

			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			mu_type=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x6`

			if [ "$global_ap_mimo" != "" ] || [ "$mu_type" = "1" ]; then
				[ "$ap_spatial_rx_stream" = "2SS" ] && ap_spatial_rx_stream="1SS"
				[ "$ap_spatial_rx_stream" = "4SS" ] && ap_spatial_rx_stream="2SS"
			fi

			spatial_rx_stream_number=${ap_spatial_rx_stream%%S*}

			# check that the NSS # is 1, 2, 3 or 4
			case $spatial_rx_stream_number in
			1|2|3|4) ;;
			*)
				error_print "Unsupported value - ap_spatial_rx_stream:$ap_spatial_rx_stream"
				send_error ",errorCode,140"
				return
			;;
			esac

			if [ -z "$ucc_type" ] || [ "$ucc_type" = "testbed" ]; then
				if [ -n "$rx_mcs_max_cap" ]; then
					# JIRA WLANRTSYS-9372: When SPATIAL_RX_STREAM or SPATIAL_TX_STREAM are set, use ap_mcs_max_cap; otherwise, use the default value
					ap_local_mcs=$rx_mcs_max_cap
					rx_mcs_max_cap=""
				else
					ap_local_mcs=$mcs_def_val_ul_testbed
				fi
			elif [ "$ucc_type" = "dut" ]; then
				ap_local_mcs=$mcs_def_val_ul
			fi

			ap_spatial_rx_stream_val=`get_nss_mcs_val $spatial_rx_stream_number $ap_local_mcs`
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz=${ap_spatial_rx_stream_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz=${ap_spatial_rx_stream_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz=${ap_spatial_rx_stream_val}"
			# JIRA WLANRTSYS-11028: part0-Rx part1-Tx
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'vht_mcs_set_part0' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part0=${ap_spatial_rx_stream_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part0=${ap_spatial_rx_stream_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part0=${ap_spatial_rx_stream_val}"
			global_nss_opt_ul=${spatial_rx_stream_number}
			if [ "$ap_program" = "EHT" ] && [ "$ucc_type" = "testbed" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_0_9=${spatial_rx_stream_number}"
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_0_9=${spatial_rx_stream_number}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_rx_max_nss_eht_mcs_0_9=${spatial_rx_stream_number}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_rx_max_nss_eht_mcs_0_9=${spatial_rx_stream_number}"
			fi	
		fi

		if [ "$ap_spatial_tx_stream" != "" ]; then
			debug_print "ap_spatial_tx_stream:$ap_spatial_tx_stream"
			debug_print "ap_program:$ap_program"

			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			mu_type=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x6`

			if [ "$global_ap_mimo" != "" ] || [ "$mu_type" = "1" ]; then
				[ "$ap_spatial_tx_stream" = "2SS" ] && ap_spatial_tx_stream="1SS"
				[ "$ap_spatial_tx_stream" = "4SS" ] && ap_spatial_tx_stream="2SS"
			fi

			spatial_tx_stream_number=${ap_spatial_tx_stream%%S*}

			# check that the NSS # is 1, 2, 3 or 4
			case $spatial_tx_stream_number in
			1|2|3|4) ;;
			*)
				error_print "Unsupported value - ap_spatial_tx_stream:$ap_spatial_tx_stream"
				send_error ",errorCode,145"
				return
			;;
			esac

			if [ -z "$ucc_type" ] || [ "$ucc_type" = "testbed" ]; then
				if [ -n "$tx_mcs_max_cap" ]; then
					# JIRA WLANRTSYS-9372: When SPATIAL_RX_STREAM or SPATIAL_TX_STREAM are set, use ap_mcs_max_cap; otherwise, use the default value
					ap_local_mcs=$tx_mcs_max_cap
					tx_mcs_max_cap=""
				else
					ap_local_mcs=$mcs_def_val_dl_testbed
				fi
			elif [ "$ucc_type" = "dut" ]; then
				ap_local_mcs=$mcs_def_val_dl
			fi

			ap_spatial_tx_stream_val=`get_nss_mcs_val $spatial_tx_stream_number $ap_local_mcs`
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz=${ap_spatial_tx_stream_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz=${ap_spatial_tx_stream_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz=${ap_spatial_tx_stream_val}"
			# JIRA WLANRTSYS-11028: part0-Rx part1-Tx
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'vht_mcs_set_part1' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part1=${ap_spatial_tx_stream_val}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part1=${ap_spatial_tx_stream_val}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part1=${ap_spatial_tx_stream_val}"
			global_nss_opt_dl=${spatial_tx_stream_number}

			# set for MU
			for usr_index in 1 2 3 4
			do
				# get MU DL MCS value
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'${usr_index} $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				current_ap_mcs=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x1`
				let current_ap_mcs="$current_ap_mcs%16"

				# calculate the OFDMA MU NSS-MCS value (NSS: bits 5-4, MCS: bits 3-0)
				let ap_ofdma_mu_nss_mcs_val="($spatial_tx_stream_number-1)*16+$current_ap_mcs"

				# set MU DL NSS MCS value
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x1=${ap_ofdma_mu_nss_mcs_val}
				# TBD: do we need to set the UL value here?
				#Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x3=${ap_ofdma_mu_nss_mcs_val}
			done
			if [ "$ap_program" = "EHT" ] && [ "$ucc_type" = "testbed" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_0_9=${spatial_tx_stream_number}"
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_0_9=${spatial_tx_stream_number}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_less_than_or_equal_80_mhz_tx_max_nss_eht_mcs_0_9=${spatial_tx_stream_number}"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_0_9' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mcs_map_160_mhz_tx_max_nss_eht_mcs_0_9=${spatial_tx_stream_number}"
			fi
		fi

		if [ "$ap_ampdu" != "" ]; then
			if [ "$ap_ampdu" = "enable" ]; then
				ap_ampdu_val="1"
				ap_ampdu_exp_val="2"
			elif [ "$ap_ampdu" = "disable" ]; then
				ap_ampdu_val="0"
				ap_ampdu_exp_val="0"
			else
				error_print "Unsupported value - ap_ampdu"
				send_error ",errorCode,165"
				return
			fi
			
			if [ "$ap_program" = "EHT" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mac_max_ampdu_len_exp_ext' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				#uci_set_eht "radio" "set" $ap_get_debug_hostap_conf_or_Post_Up_idx "eht_mac_max_ampdu_len_exp_ext=$ap_ampdu_exp_val"
                $UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_max_ampdu_len_exp_ext=$ap_ampdu_exp_val"
                $UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_max_ampdu_len_exp_ext=$ap_ampdu_exp_val"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_max_ampdu_len_exp_ext=$ap_ampdu_exp_val"
				# JIRA WLANRTSYS-9583 [Silicon limitation A1] ap_set_wireless AMPDU,Disable -> Disable BA Agreements in FW using sAggrConfig
                #uci_set_eht "iface" "set_get_helper_non_debug" "sAggrConfig" "x1=$ap_ampdu_val"
				set_get_helper_non_debug $CURRENT_24G_IFACE_UCI_PATH.sAggrConfig x1=$ap_ampdu_val
				set_get_helper_non_debug $CURRENT_5G_IFACE_UCI_PATH.sAggrConfig x1=$ap_ampdu_val
				set_get_helper_non_debug $CURRENT_6G_IFACE_UCI_PATH.sAggrConfig x1=$ap_ampdu_val
			else
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mac_a_msdu_in_ack_enabled_a_mpdu_support' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mac_a_msdu_in_ack_enabled_a_mpdu_support=$ap_ampdu_val"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mac_maximum_a_mpdu_length_exponent' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mac_maximum_a_mpdu_length_exponent=$ap_ampdu_exp_val"
				# JIRA WLANRTSYS-9583 [Silicon limitation A1] ap_set_wireless AMPDU,Disable -> Disable BA Agreements in FW using sAggrConfig  
				set_get_helper_non_debug $CURRENT_IFACE_UCI_PATH.sAggrConfig x1=$ap_ampdu_val 	
			fi 
		fi
				
		if [ "$ap_amsdu" != "" ]; then
			if [ "$ap_amsdu" = "enable" ]; then
				ap_amsdu_val="1"
			elif [ "$ap_amsdu" = "disable" ]; then
				ap_amsdu_val="0"
			else
				error_print "Unsupported value - ap_amsdu:$ap_amsdu"
				send_error ",errorCode,170"
				return
			fi

			tc_name=`get_test_case_name $glob_ssid`
			if [ "$ap_program" = "EHT" ]; then
				set_get_helper_non_debug $CURRENT_6G_IFACE_UCI_PATH.sAggrConfig x0=$ap_amsdu_val
				set_get_helper_non_debug $CURRENT_5G_IFACE_UCI_PATH.sAggrConfig x0=$ap_amsdu_val
				set_get_helper_non_debug $CURRENT_24G_IFACE_UCI_PATH.sAggrConfig x0=$ap_amsdu_val
			else
                set_get_helper $CURRENT_IFACE_UCI_PATH.sAggrConfig x0=$ap_amsdu_val
            fi

			if [ "$ap_amsdu_val" = "1" ]; then
				if [ "$ap_program" = "EHT" ]; then
					#uci_set_eht "radio" "set" $ap_get_debug_hostap_conf_or_Post_Up_idx "sMaxMpduLen=11000"
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMaxMpduLen' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMaxMpduLen=11000"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMaxMpduLen=11000"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMaxMpduLen=11000"
				else ## WLANRTSYS-11027 [Silicon limitation A1] upon AMSDU enable Set sMaxMpduLen to 11000
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMaxMpduLen' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMaxMpduLen=11000"
				fi
			fi
		fi

		#For EHT specific TCs where Forced S-MPDU is enabled i.e. Disable the addba
		if [ "$ap_addba_reject" != "" ] || [ "$ap_forced_smpdu" != "" ]; then
			debug_print "ap_addba_reject:$ap_addba_reject"
			if [ "$ap_addba_reject" = "enable" ] || [ "$ap_forced_smpdu" = "enable" ]; then
				ap_addba_reject_val="0" # reject=enable means 0 (disable BA agreement) 
			elif [ "$ap_addba_reject" = "disable" ]; then
				ap_addba_reject_val="1" # reject=disable means 1 (enable BA agreement)
			else
				error_print "Unsupported value - ap_addba_reject:$ap_addba_reject"
				send_error ",errorCode,175"
				return
			fi
			if [ "$ap_program" = "EHT" ] || [ "$ap_program" = "HE" ]; then
				#uci_set_eht "iface" "set_get_helper_non_debug" "sAggrConfig" "x2=${ap_addba_reject_val}"
				set_get_helper_non_debug $CURRENT_24G_IFACE_UCI_PATH.sAggrConfig x1=${ap_addba_reject_val}
				set_get_helper_non_debug $CURRENT_5G_IFACE_UCI_PATH.sAggrConfig x1=${ap_addba_reject_val}
				set_get_helper_non_debug $CURRENT_6G_IFACE_UCI_PATH.sAggrConfig x1=${ap_addba_reject_val}
			else
				set_get_helper_non_debug $CURRENT_IFACE_UCI_PATH.sAggrConfig x2=${ap_addba_reject_val}
			fi
		fi

		if [ "$ap_addbareq_bufsize" != "" ]; then
			if [ "$ap_addbareq_bufsize" = "gt64" ] || [ "$ap_addbareq_bufsize" = "eq256" ] ; then
				ap_addbareq_bufsize="256"
			elif [ "$ap_addbareq_bufsize" = "le64" ]; then
				ap_addbareq_bufsize="64"
			else
				error_print "Unsupported value - ap_addba_reject:$ap_addba_reject"
				send_error ",errorCode,176"
				return
			fi
			
			if [ "$ap_program" = "EHT" ]; then
				[ "$ap_addbareq_bufsize" != "0" ] && set_get_helper_non_debug $CURRENT_6G_IFACE_UCI_PATH.sAggrConfig x2=${ap_addbareq_bufsize}
				[ "$ap_addbareq_bufsize" != "0" ] && set_get_helper_non_debug $CURRENT_5G_IFACE_UCI_PATH.sAggrConfig x2=${ap_addbareq_bufsize}
				[ "$ap_addbareq_bufsize" != "0" ] && set_get_helper_non_debug $CURRENT_24G_IFACE_UCI_PATH.sAggrConfig x2=${ap_addbareq_bufsize}
			else
				[ "$ap_addbareq_bufsize" != "0" ] && set_get_helper_non_debug $CURRENT_IFACE_UCI_PATH.sAggrConfig x2=${ap_addbareq_bufsize}
			fi	
		fi

		## JIRA WLANRTSYS-10849
		if [ "$ap_addbaresp_bufsize" != "" ]; then
			if [ "$ap_addbaresp_bufsize" = "gt64" ] || [ "$ap_addbaresp_bufsize" = "eq256" ] ; then
				ap_addbaresp_bufsize="256"
			elif [ "$ap_addbaresp_bufsize" = "le64" ]; then
				ap_addbaresp_bufsize="64"
			else
				error_print "Unsupported value - ap_addbaresp_bufsize:$ap_addbaresp_bufsize"
				send_error ",errorCode,178"
				return
			fi

			[ "$ap_addbaresp_bufsize" != "0" ] && set_get_helper_non_debug $CURRENT_IFACE_UCI_PATH.sAggrConfig x2=${ap_addbaresp_bufsize} 
		fi

		if [ "$ap_tx_bf" != "" ]; then
			debug_print "ap_tx_bf:$ap_tx_bf"
			if [ "$ap_tx_bf" = "enable" ]; then
				ap_tx_bf_val="EXPLICIT"
				debug_print "ap_program=$ap_program"
				tc_name=`get_test_case_name $glob_ssid`
				debug_print "tc_name=$tc_name"
				debug_print "width_val=$width_val"
				if [ "$ap_program" != "EHT" ]; then
					if [ "$tc_name" = "4.35.1" ] && [ "$width_val" = "80MHz" ]; then
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.debug_hostap_conf="he_phy_channel_width_set=2"
					fi
					# WLANRTSYS-10947
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.debug_hostap_conf="he_phy_su_beamformer_capable=1"
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.debug_hostap_conf="he_phy_mu_beamformer_capable=1"
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.debug_hostap_conf="he_phy_su_beamformee_capable=1"
					# set the maximum but will not be set more the hw antennas.
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_max_nc' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_max_nc=4"
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.debug_hostap_conf="he_phy_triggered_su_beamforming_feedback=1"
				else #Specific for EHT program
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_su_beamformer' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformer=1"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformer=1"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformer=1"	
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_su_beamformee' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformee=1"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformee=1"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformee=1"	
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_max_nc' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_max_nc=3"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_max_nc=3"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_max_nc=3"
				fi
			elif [ "$ap_tx_bf" = "disable" ]; then
				ap_tx_bf_val="Disabled"
			else
				error_print "Unsupported value - ap_tx_bf:$ap_tx_bf"
				send_error ",errorCode,180"
				return
			fi

			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sBfMode' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			sBfMode_local=`convert_bf_mode $ap_tx_bf_val`
			debug_print "converted sBfMode_local=$sBfMode_local"
			if [ "$ap_program" = "EHT" ]; then
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sBfMode $sBfMode_local"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sBfMode $sBfMode_local"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sBfMode $sBfMode_local"	
			else	
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx=\"sBfMode $sBfMode_local\"	
			fi	
		fi

		if [ "$ap_num_sound_dim" != "" ]; then
			debug_print "ap_num_sound_dim:$ap_num_sound_dim"
			if [ "$ap_program" = "EHT" ] && [ "$ap_num_sound_dim" -le 4 ] ; then
				debug_print "Setting number of sounding dimention to $ap_num_sound_dim"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_num_sounding_dim_80_mhz_or_below' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_num_sounding_dim_80_mhz_or_below=$((ap_num_sound_dim - 1 ))"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_num_sounding_dim_80_mhz_or_below=$((ap_num_sound_dim -1 ))"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_num_sounding_dim_80_mhz_or_below=$((ap_num_sound_dim - 1 ))"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_num_sounding_dim_160_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_num_sounding_dim_160_mhz=$((ap_num_sound_dim -1 ))"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_num_sounding_dim_160_mhz=$((ap_num_sound_dim -1 ))"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_num_sounding_dim_320_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_num_sounding_dim_320_mhz=$((ap_num_sound_dim -1 ))"
			elif [ "ap_num_sound_dim" -gt 4 ]; then
				error_print "Unsupported value - ap_num_sound_dim:$ap_num_sound_dim"
				send_error ",errorCode,185"
				return
			fi
		fi

		if [ "$ap_omcontrol" != "" ]; then
			debug_print "ap_omcontrol:$ap_omcontrol"
			if [ "$ap_omcontrol" = "enable" ]; then
				ap_omcontrol="true"
			elif [ "$ap_omcontrol" = "disable" ]; then
				ap_omcontrol="false"
			else
				error_print "Unsupported value - ap_omcontrol:$ap_omcontrol"
				send_error ",errorCode,195"
				return
			fi
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mac_om_control_support' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mac_om_control_support=${ap_omcontrol}"
		fi

		if [ "$ap_eht_omcontrol" != "" ]; then
			debug_print "ap_eht_omcontrol:$ap_eht_omcontrol"
			if [ "$ap_eht_omcontrol" = "enable" ]; then
				ap_eht_omcontrol=1
			elif [ "$ap_eht_omcontrol" = "disable" ]; then
				ap_eht_omcontrol=0
			else
				error_print "Unsupported value - ap_eht_omcontrol:$ap_eht_omcontrol"
				send_error ",errorCode,197"
				return
			fi
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mac_eht_om_control' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_eht_om_control=${ap_eht_omcontrol}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_eht_om_control=${ap_eht_omcontrol}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_eht_om_control=${ap_eht_omcontrol}"		
		fi

		if [ "$ap_ul_mumimo" != "" ]; then
			if [ "$ap_ul_mumimo" = 1 ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_non_ofdma_ul_mu_mimo_bw_80_mhz_or_below' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_non_ofdma_ul_mu_mimo_bw_80_mhz_or_below=${ap_ul_mumimo}"
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_non_ofdma_ul_mu_mimo_bw_80_mhz_or_below=${ap_ul_mumimo}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_non_ofdma_ul_mu_mimo_bw_80_mhz_or_below=${ap_ul_mumimo}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_non_ofdma_ul_mu_mimo_bw_160_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_non_ofdma_ul_mu_mimo_bw_160_mhz=${ap_ul_mumimo}"
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_non_ofdma_ul_mu_mimo_bw_160_mhz=${ap_ul_mumimo}"

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_non_ofdma_ul_mu_mimo_bw_320_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_non_ofdma_ul_mu_mimo_bw_320_mhz=${ap_ul_mumimo}"
			fi
		fi

		# MU-MIMO
		if [ "$global_ap_mimo" != "" ]; then
			if [ "$global_ap_mimo" = "dl" ] || [ "$global_ap_mimo" = "ul" ]; then
				kill_sigmaManagerDaemon
				if [ "$ap_program" != "EHT" ]; then
					get_nof_sta_per_he_test_case $glob_ssid
					ap_num_users_ofdma=$nof_sta
					arguments_file_initializer $CURRENT_RADIO_UCI_PATH $glob_ssid
					/lib/netifd/sigmaManagerDaemon.sh $CURRENT_WLAN_NAME.0 $ap_num_users_ofdma &

					if [ "$global_ap_mimo" = "dl" ]; then
						glob_ofdma_phase_format=0
						## Common PART
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
						set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=1 x6=1 x15=406
						# WLANRTSYS-9638: 'WaveSPDlUsrPsduRatePerUsp' will NOT be set at all
					elif [ "$global_ap_mimo" = "ul" ]; then
						glob_ofdma_phase_format=1
						## Common PART
						## Phase repetitions to be set as we do for UL OFDMA in order to efficiently utilize the TXOP
						## Default CP=1 (1.6us), LTF=0 (1x), GI=0 (1xLTF + 1.6 GI)
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
						set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x6=1 x7=1 x12=1 x13=0 x14=0
					fi
					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
					set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x4=${glob_ofdma_phase_format}
					## ap_num_users_ofdma in case UCC will send num of users if not user will be set according to the test
					if [ "$ap_num_users_ofdma" != "" ]; then
						set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x5=${ap_num_users_ofdma}
					else
						if [ "$glob_ssid" != "" ]; then
							# check if num_of_users can be obtained from the predefined list (by test plan)
							get_nof_sta_per_he_test_case $glob_ssid
							ap_num_users_ofdma=$nof_sta
							[ "$ap_num_users_ofdma" != "0" ] && set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x5=${ap_num_users_ofdma}
						fi
					fi
				else #Specific for EHT
					if [ "$global_ap_mimo" = "dl" ]; then
						glob_ofdma_phase_format=0
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
						set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=1 x6=1 x15=406
						set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=1 x6=1 x15=406
						set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=1 x6=1 x15=406
					elif [ "$global_ap_mimo" = "ul" ]; then
						glob_ofdma_phase_format=1
						## Default CP=1 (1.6us), LTF=1 (2x), GI_LTF=1 (2xLTF + 1.6 GI), UL_LEN=3082->TPE=16us
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
						set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x6=1 x7=1 x12=1 x13=1 x14=1 x15=3082
						set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x6=1 x7=1 x12=1 x13=1 x14=1 x15=3082
						set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x6=1 x7=1 x12=1 x13=1 x14=1 x15=3082
					fi
					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
					set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x4=${glob_ofdma_phase_format}
					set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x4=${glob_ofdma_phase_format}
					set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x4=${glob_ofdma_phase_format}
					[ "$ap_num_users_ofdma" = "" ] && ap_num_users_ofdma=2
					set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x5=${ap_num_users_ofdma}
				fi
			else
				error_print "Unsupported value - global_ap_mimo:$global_ap_mimo"
				send_error ",errorCode,197"
				return
			fi
			# set fixed rate for MU-MIMO
			info_print "sDoSimpleCLI 70 1"
			uci set $CURRENT_RADIO_UCI_PATH.debug_iw_post_up_2="sDoSimpleCLI 70 1"
		fi

		if [ "$global_mu_txbf" != "" ] || [ "$ap_mu_beamformer" != "" ]; then
			if [ "$global_mu_txbf" = "enable" ] || [ "$ap_mu_beamformer" = "1" ]; then
				if [ "$ap_program" != "EHT" ]; then
					# WLANRTSYS-10947
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_su_beamformer_capable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_su_beamformer_capable=1"
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_mu_beamformer_capable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_mu_beamformer_capable=1"
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_su_beamformee_capable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_su_beamformee_capable=1"
					# set the maximum but will not be set more the hw antennas.
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_max_nc' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_max_nc=4"
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_phy_triggered_su_beamforming_feedback' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_phy_triggered_su_beamforming_feedback=1"
					if [ "$ucc_type" = "testbed" ]; then
						ap_get_debug_hostap_conf_or_Post_Up_idx=`uci show wireless | grep $CURRENT_RADIO_UCI_PATH | grep 'he_mac_ndp_feedback_report_support' | cut -d"." -f3 | cut -d"=" -f1`
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mac_ndp_feedback_report_support=1"
					fi
			
					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
					set_get_helper  $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$dl_com_mu_type_idx=1
					if [ "$ucc_type" = "testbed" ]; then
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'enable_he_debug_mode' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="enable_he_debug_mode=0"
					fi
			
					get_nof_sta_per_he_test_case $glob_ssid
					ap_num_users_ofdma=$nof_sta
					arguments_file_initializer $CURRENT_RADIO_UCI_PATH $glob_ssid
					kill_sigmaManagerDaemon
					[ "$ap_program" = "HE" ] && /lib/netifd/sigmaManagerDaemon.sh $CURRENT_WLAN_NAME.0 $ap_num_users_ofdma &
				else #Specific for EHT
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_su_beamformer' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformer=1"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformer=1"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformer=1"	
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_su_beamformee' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformee=1"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformee=1"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_su_beamformee=1"	
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_max_nc' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_max_nc=3"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_max_nc=3"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_max_nc=3"
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_mu_beamformer_bw_80_mhz_or_below' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_mu_beamformer_bw_80_mhz_or_below=1"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_mu_beamformer_bw_80_mhz_or_below=1"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_mu_beamformer_bw_80_mhz_or_below=1"
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_mu_beamformer_bw_160_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_mu_beamformer_bw_160_mhz=1"
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_mu_beamformer_bw_160_mhz=1"
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_phy_mu_beamformer_bw_320_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_phy_mu_beamformer_bw_320_mhz=1"
					if [ "$global_ap_mimo" = "" -a "$glob_ap_ofdma" = "" -a "$global_mu_txbf" = "enable" -a "$ap_tx_bf" = "enable" ] || [ "$global_ap_mimo" != "" ]; then
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
						set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$dl_com_mu_type_idx=1
						set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$dl_com_mu_type_idx=1
						set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$dl_com_mu_type_idx=1
					else
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
						set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$dl_com_mu_type_idx=0
						set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$dl_com_mu_type_idx=0
						set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$dl_com_mu_type_idx=0
					fi
					#Set the mu_sequence_type=9 to set the HE_MU_SEQ_DL_BASIC_TF_WITH_SOUNDING for TC-4.19.1 & TC-5.21.1
					if [ "$ap_non_trig_tx_bf" = "enable" ] || [ "$glob_ap_ofdma" != "" -a "$global_mu_txbf" = "enable" -a "$ap_tx_bf" = "enable" ]; then
						set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$sequence_type_idx=9
						set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$sequence_type_idx=9
						set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$sequence_type_idx=9
					fi
				fi
			fi	
		fi	

		if [ "$ap_mu_edca" != "" ]; then
			## JIRA WLANRTSYS-10947: WaveHeMuEdcaIePresent
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mu_edca_ie_present' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			if [ "$ap_mu_edca" = "override" ]; then
				if [ "$ap_program" = "EHT" ]; then
					$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mu_edca_ie_present=1"
					$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mu_edca_ie_present=1"
					$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mu_edca_ie_present=1"
				else
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mu_edca_ie_present=1"
				fi
			fi		
		fi

		if [ "$ap_twt_respsupport" != "" ]; then
			debug_print "ap_twt_respsupport:$ap_twt_respsupport"
			if [ "$ap_twt_respsupport" = "enable" ]; then
				ap_twt_respsupport="1"
				info_print "dl_com_number_of_phase_repetitions = 2"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
				set_get_helper  $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x$dl_com_number_of_phase_repetitions_idx=2
			elif [ "$ap_twt_respsupport" = "disable" ]; then
				ap_twt_respsupport="0"
			else
				error_print "Unsupported value - ap_twt_respsupport:$ap_twt_respsupport"
				send_error ",errorCode,200"
				return
			fi
			
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep  -w 'twt_responder_support' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="twt_responder_support=${ap_twt_respsupport}"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mac_twt_responder_support' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mac_twt_responder_support=${ap_twt_respsupport}"
		fi

		if [ "$global_ap_btwt" = "1" ]; then
			debug_print "global_ap_btwt:$global_ap_btwt"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`uci show wireless | grep $CURRENT_RADIO_UCI_PATH | grep 'he_mac_broadcast_twt_support' | cut -d"." -f3 | cut -d"=" -f1`
			if [ -z "$ap_get_debug_hostap_conf_or_Post_Up_idx" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_RADIO_UCI_PATH | cut -d"_" -f4 | cut -d"=" -f1 | sort -n | tail -1`
				ap_get_debug_hostap_conf_or_Post_Up_idx="debug_hostap_conf_$((ap_get_debug_hostap_conf_or_Post_Up_idx+1))"
			fi
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mac_broadcast_twt_support=${global_ap_btwt}"
		fi

		if [ -n "$ap_min_mpdu_start_spacing" ]; then
			debug_print "ap_min_mpdu_start_spacing:$ap_min_mpdu_start_spacing"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'ht_minimum_mpdu_start_spacing' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="ht_minimum_mpdu_start_spacing=${ap_min_mpdu_start_spacing}"
		fi
		
		# JIRA WLANRTSYS-9943
		if [ "$ap_vht_extnss" != "" ]; then
			if [ "$ap_vht_extnss" = "eq0" ]; then
				ap_width="40"  # "40MHz", will set he_op_vht_channel_width to '0'
			elif [ "$ap_vht_extnss" = "eq1" ]; then
				ap_width="80"  # "80MHz", will set he_op_vht_channel_width to '1'
			else
				error_print "Unsupported value - ap_vht_extnss:$ap_vht_extnss"
				send_error ",errorCode,116"
				return
			fi
		fi
		# Handle MBSSID feature - start
		if [ -n "$global_ap_mbssid" ] || [ -n "$global_ap_cohosted_bss" ]; then
			debug_print "global_ap_mbssid:$global_ap_mbssid"
			# In order to avoid issues with new VAPs MACs, setting MAC for first VAP in the format XX:XX:XX:XX:XX:X0
			local macaddr_suffix=${CURRENT_WLAN_NAME##wlan}
			macaddr_suffix=$((macaddr_suffix+1))
			macaddr_suffix=$((macaddr_suffix*10))
			base_addr=`uci show wireless | grep $CURRENT_RADIO_UCI_PATH.macaddr | cut -d"=" -f2 | cut -d":" -f1-5 | cut -d"'" -f2`
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.macaddr=$base_addr:${macaddr_suffix}
			if [ "$global_ap_mbssid" = "enable" ] || [ "$global_ap_cohosted_bss" = "enable" ]; then
				if [ -n "$global_num_non_tx_bss" ] && [ -z "$global_ap_cohosted_bss" ]; then
					if [ $global_num_non_tx_bss -le 3 ]; then
						ap_mbssid_num_non_tx_bss=3  # numNonTxBss <= 3 [1,2,3] creating additional 3 VAPs (in addition to the main AP).
					else
						ap_mbssid_num_non_tx_bss=7  # numNonTxBss > 3 [4,5,6,7] creating additional 7 VAPs (in addition to the main AP).
					fi
				fi
				if [ "$ap_program" = "EHT" -a "$ap_mld_id" = "2" ] || ([ "$ap_program" != "EHT" ] && [ -z "$global_is_vaps_created" ] && [ -n "$ap_non_tx_bss_index" ] && [ -n "$ap_mbssid_num_non_tx_bss" ]); then
					debug_print "ap_non_tx_bss_index:$ap_non_tx_bss_index"
					ap_non_tx_bss_index_count=$global_num_non_tx_bss
					if [ "$global_ap_cohosted_bss" = "enable" ]; then
						ap_non_tx_bss_index_count=$global_num_cohosted_bss
						ap_non_tx_bss_index=$((ap_cohosted_bss_index-1))
					fi
					local count=0
					local pmf=0
					while [ $count -lt $ap_non_tx_bss_index_count ]; do
						count=$((count+1))
						if [ $count -eq $ap_non_tx_bss_index ]; then
							([ -n "$ap_ssid_non_tx_bss_index" ] || [ -n "$ap_ssid_cohosted_bss_index" ]) && eval mbss_vap_$count=`add_interface`
							tmp_current_o_vap="mbss_vap_$count"
							current_o_vap=`eval 'echo $'$tmp_current_o_vap`
							[ -n "$global_ap_mbssid" ] && $UCI_CMD set wireless.$current_o_vap.ssid="$ap_ssid_non_tx_bss_index"
							[ -n "$global_ap_cohosted_bss" ] && $UCI_CMD set wireless.$current_o_vap.ssid="$ap_ssid_cohosted_bss_index"
							pmf=`uci get $CURRENT_IFACE_UCI_PATH.ieee80211w`
							[ -n "$pmf" ] && $UCI_CMD set wireless.$current_o_vap.ieee80211w=$pmf
							bpe=`uci get $CURRENT_IFACE_UCI_PATH.beacon_protection_enabled`
							[ -n "$bpe" ] && $UCI_CMD set wireless.$current_o_vap.beacon_protection_enabled=$bpe
							[ -n "$global_ap_cohosted_bss" ] && CURRENT_IFACE_UCI_PATH_2="wireless.$current_o_vap"
							[ -n "$global_ap_mbssid" ] && CURRENT_6G_IFACE_UCI_PATH_2="wireless.$current_o_vap"
						else
							eval mbss_vap_$count=`add_interface`
							tmp_current_o_vap="mbss_vap_$count"
							current_o_vap=`eval 'echo $'$tmp_current_o_vap`
							$UCI_CMD set wireless.$current_o_vap.ssid="MBSSID_VAP_${count}"
							$UCI_CMD set wireless.$current_o_vap.mbo="0"
							pmf=`uci get $CURRENT_IFACE_UCI_PATH.ieee80211w`
							[ -n "$pmf" ] && $UCI_CMD set wireless.$current_o_vap.ieee80211w=$pmf
						fi
					done
					if [ -n "$global_ap_mbssid" ] && [ "$global_ap_mbssid" = "enable" ]; then
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'multibss_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="multibss_enable=1"
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_operation_cohosted_bss' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_operation_cohosted_bss=0"
					fi
					if 	[ -n "$global_ap_cohosted_bss" ] && [ "$global_ap_cohosted_bss" = "enable" ]; then
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'multibss_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="multibss_enable=0"
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_operation_cohosted_bss' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_operation_cohosted_bss=1"
					fi

					# JIRA WLANRTSYS-9713: rais a flag; otherwise, when getting 'NONTXBSSINDEX' again, a new set of vaps will be created
					global_is_vaps_created=1
				fi
				if [ "$global_is_vaps_created" = "1" ] && [ -n "$ap_ssid_non_tx_bss_index" ] && [ -n "$ap_non_tx_bss_index" ] && [ "$ap_non_tx_bss_index" -gt "1" ]; then
					# handle indexes '2' and above; index '1' SSID was already set
					local ap_vap_idx=$ap_non_tx_bss_index
					tmp_current_o_vap="mbss_vap_$ap_vap_idx"
					current_o_vap=`eval 'echo $'$tmp_current_o_vap`
					$UCI_CMD set wireless.$current_o_vap.ssid="$ap_ssid_non_tx_bss_index"
				fi
				if [ "$ap_program" != "EHT" ]; then
					[ "$ap_non_tx_bss_index" = "$global_num_non_tx_bss" ] && global_ap_mbssid=""
				else
					[ -n "$ap_non_tx_bss_index" ] && global_ap_mbssid=""
				fi

			else
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'multibss_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="multibss_enable=0"
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_operation_cohosted_bss' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_operation_cohosted_bss=1"
			fi
		fi
		# Handle MBSSID feature - end

		# Create AP-MLDs between 2.4GHz/5GHz + 6GHz band for MLO+MBSSID feature in EHT
		if [ -n "$ap_mld_id" ] && [ -z "$global_ap_mbssid" ] && [ -n "$global_ap_cohosted_bss" ]; then
			rand_mac_mld="ac:9a:96:84:68:45"
			if [ "$ap_mld_id" = "2" ]; then
				CURRENT_IFACE_UCI_PATH=$CURRENT_IFACE_UCI_PATH_2
				CURRENT_6G_IFACE_UCI_PATH=$CURRENT_6G_IFACE_UCI_PATH_2
				rand_mac_mld="ac:9a:96:84:68:46"
			fi
			debug_print "AP MLD mac address : $rand_mac_mld"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ssid=$ap_ssid_cohosted_bss_index
			$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.ssid=$ap_ssid_cohosted_bss_index
			ap_get_debug_hostap_conf=`grep 'mlo_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
			$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
			ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_6G_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
			$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
			ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_6G_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
			mac_addr=`$UCI_CMD get $CURRENT_IFACE_UCI_PATH.macaddr`
			$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
			mac_addr=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.macaddr`
			$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
		fi

		if [ "$ap_srctrl_srvalue15allowed" != "" ]; then
			debug_print "ap_srctrl_srvalue15allowed:$ap_srctrl_srvalue15allowed"

			if [ "$ap_srctrl_srvalue15allowed" = "enable" ] || [ "$ap_srctrl_srvalue15allowed" = "1" ]; then
				ap_srctrl_srvalue15allowed="true"
			elif [ "$ap_srctrl_srvalue15allowed" = "disable" ] || [ "$ap_srctrl_srvalue15allowed" = "0" ]; then
				ap_srctrl_srvalue15allowed="false"
			else
				error_print "Unsupported value - ap_srctrl_srvalue15allowed:$ap_srctrl_srvalue15allowed"
				send_error ",errorCode,203"
				return
			fi
				
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sr_control_field_hesiga_spatial_reuse_value15_allowed' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sr_control_field_hesiga_spatial_reuse_value15_allowed=${ap_srctrl_srvalue15allowed}"
		fi

		if [ "$ap_program" = "EHT" ] && [ "$ap_interface" != "" ] && [ "$glob_ap_mode" = "11be" ]; then
			if [ "$global_ap_mbssid" = "" -a "$ap_mld_id" = "" -a "$global_ap_cohosted_bss" = "" ]; then
				rand_mac_mld="ac:9a:96:84:68:44"
				debug_print "AP MLD mac address : $rand_mac_mld"
				mlo_counter=$((mlo_counter+1))
				if [ "$ap_interface" = "24G" ]; then
					ap_get_debug_hostap_conf=`grep 'mlo_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ssid=$glob_ssid
					mlo_enable_5G=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
					mlo_enable_5G=${mlo_enable_5G##*=}
					mlo_enable_6G=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
					mlo_enable_6G=${mlo_enable_6G##*=}
					ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
					ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
					if [ "$mlo_enable_5G" = "1" ]; then
						mac_addr=`$UCI_CMD get $CURRENT_24G_IFACE_UCI_PATH.macaddr`
						ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
						ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
						$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
						mac_addr=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.macaddr`
						$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
						ML_VAP1=$ap_interface
						ML_VAP2="5G"
					else
						if [ "$mlo_enable_6G" = "1" ]; then
							mac_addr=`$UCI_CMD get $CURRENT_24G_IFACE_UCI_PATH.macaddr`
							ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
							ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
							$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
							mac_addr=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.macaddr`
							$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
							ML_VAP2="6G"
							ML_VAP1=$ap_interface
						fi
					fi
				elif [ "$ap_interface" = "5G" ]; then
					ap_get_debug_hostap_conf=`grep 'mlo_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ssid=$glob_ssid
					mlo_enable_24G=`$UCI_CMD get $CURRENT_24G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
					mlo_enable_24G=${mlo_enable_24G##*=}
					mlo_enable_6G=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
					mlo_enable_6G=${mlo_enable_6G##*=}
					ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
					ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
					if [ "$mlo_enable_24G" = "1" ]; then
						mac_addr=`$UCI_CMD get $CURRENT_24G_IFACE_UCI_PATH.macaddr`
						ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
						ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
						$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
						mac_addr=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.macaddr`
						$UCI_CMD set $CURRENT_24G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
						ML_VAP2=$ap_interface
						ML_VAP1="24G"
					else
						if [ "$mlo_enable_6G" = "1" ]; then
							mac_addr=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.macaddr`
							ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
							ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
							$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
							mac_addr=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.macaddr`
							$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
							ML_VAP1=$ap_interface
							ML_VAP2="6G"
						fi
					fi	
				elif [ "$ap_interface" = "6G" ]; then
					ap_get_debug_hostap_conf=`grep 'mlo_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.ssid=$glob_ssid
					mlo_enable_24G=`$UCI_CMD get $CURRENT_24G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
					mlo_enable_24G=${mlo_enable_24G##*=}
					mlo_enable_5G=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
					mlo_enable_5G=${mlo_enable_5G##*=}
					ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
					ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
					if [ "$mlo_enable_24G" = "1" ]; then
						mac_addr=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.macaddr`
						ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
						ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
						$UCI_CMD set $CURRENT_24G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
						mac_addr=`$UCI_CMD get $CURRENT_24G_IFACE_UCI_PATH.macaddr`
						$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
						ML_VAP2=$ap_interface
						ML_VAP1="24G"
					else
						if [ "$mlo_enable_5G" = "1" ]; then
							mac_addr=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.macaddr`
							ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
							ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
							$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
							mac_addr=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.macaddr`
							$UCI_CMD set $CURRENT_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
							ML_VAP2=$ap_interface
							ML_VAP1="5G"
						fi
					fi
				else
					debug_print "!! Wrong Interface name !!"
				fi
			fi

			# Toffset = Floor((TA –TB)/2).
			#2.4G TSF calculation (LongPreamble(192 us), + WiFi Header 192 bits (@ Data rate 1 Mbps)) = 192us + 192us = 384 us
			#5G/6G TSF calculation (Preamble (20us), + WiFi Header 192 bits(@ Data rate 6 Mbps)) = 20 us + 32 us = 52 us
			#Toffset = (384 - 52)/2 = 166
			#With an offset of 166 the WFA tests were failing, and hence the value of 150 has been chosen empirically for now
			if [ "$ML_VAP1" = "24G" ]; then
				ap_get_debug_hostap_conf=`grep 'eht_mld_tsf_diff' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf="eht_mld_tsf_diff=150"
			fi

			#TC-5.43.1 - Configure Medium Synchronization Delay parameters only for MLD VAP's
			if [ "$ML_VAP1" != "" ] && [ "$ML_VAP2" != "" ] && [ "$global_ap_mld_mediumsync_present" != "" ]; then
				eval ML_VAP1_UCI_PATH=\${CURRENT_${ML_VAP1}_IFACE_UCI_PATH}
				set_mld_mediumsync_params $ML_VAP1_UCI_PATH

				eval ML_VAP2_UCI_PATH=\${CURRENT_${ML_VAP2}_IFACE_UCI_PATH}
				set_mld_mediumsync_params $ML_VAP2_UCI_PATH
			fi

			#TC-4.45.1/5.45.1 - EMLSR TB UL
			if [ "$ap_program" = "EHT" ] && [ "$global_ap_ul_ofdma" = "1" ] && [ "$global_ap_tx_omn_resp_disable" = "1" ] && [ "$ML_VAP1" != "" ] && [ "$ML_VAP2" != "" ]; then
				[ "$ML_VAP1" = "24G" ] && CONFIG_WLAN_NAME=$CURRENT_24G_WLAN_NAME
				[ "$ML_VAP1" = "5G" ] && CONFIG_WLAN_NAME=$CURRENT_5G_WLAN_NAME

				#Enable synchronous link switch config in FW
				debug_print "Request FW to sync all MLD STA's active link in the same band"
				iw dev $CONFIG_WLAN_NAME iwlwav sDoSimpleCLI 151 1

				#Two static plan (two bands, one per band) are needed
				debug_print "Two static plan config enabled"
				global_emlsr_tb_ul_ofdma=1
			fi

			#Handling the EPCS enable command
			if [ "$ML_VAP1" != "" ] && [ "$ML_VAP2" != "" ] && [ "$global_ap_eht_epcs" != "" ]; then
				eval ML_VAP1_UCI_PATH=\${CURRENT_${ML_VAP1}_IFACE_UCI_PATH}
				eval ML_VAP2_UCI_PATH=\${CURRENT_${ML_VAP2}_IFACE_UCI_PATH}
				ap_get_debug_hostap_conf_idx_vap1=`uci show wireless | grep debug_hostap | grep $ML_VAP1_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
				let ap_get_debug_hostap_conf_idx_vap1=ap_get_debug_hostap_conf_idx_vap1+1
				ap_get_debug_hostap_conf_vap1="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx_vap1))"
				ap_get_debug_hostap_conf_idx_vap2=`uci show wireless | grep debug_hostap | grep $ML_VAP2_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
				let ap_get_debug_hostap_conf_idx_vap2=ap_get_debug_hostap_conf_idx_vap2+1
				ap_get_debug_hostap_conf_vap2="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx_vap2))"
				$UCI_CMD set $ML_VAP1_UCI_PATH.$ap_get_debug_hostap_conf_vap1="eht_mac_epcs_prio_access=$global_ap_eht_epcs"
				$UCI_CMD set $ML_VAP2_UCI_PATH.$ap_get_debug_hostap_conf_vap2="eht_mac_epcs_prio_access=$global_ap_eht_epcs"
			fi

			#TC-4.50.1 - Basic load balancing Test - Tid to link mapping negotiation support
			if [ "$ML_VAP1" != "" ] && [ "$ML_VAP2" != "" ] && [ "$global_ap_t2lm_negotiation_support" != "" ] ; then
				eval ML_VAP1_UCI_PATH=\${CURRENT_${ML_VAP1}_IFACE_UCI_PATH}
				eval ML_VAP2_UCI_PATH=\${CURRENT_${ML_VAP2}_IFACE_UCI_PATH}
				enable_mld_t2lm_negotiation_support $ML_VAP1_UCI_PATH
				enable_mld_t2lm_negotiation_support $ML_VAP2_UCI_PATH
			fi
		else
			debug_print "Program doesn't supports MLO"
		fi

		#Handling the static puncturing of 6Ghz channels in Wi-Fi 7
		if [ "$global_ap_punctchannel" != "" ]; then

			STATIC_PUNC_CHNL_FILE="/tmp/sigma_static_punc_chnl"
			rm -f $STATIC_PUNC_CHNL_FILE
			echo $global_ap_punctchannel | tr ' ' '\n' >> $STATIC_PUNC_CHNL_FILE

			#Third argument provided to the subroutine
			#1-dynamic puncturing
			#0-static puncturing
			dis_subchnl_bitmap_val=`get_disabled_subchannel_bitmap_val $CURRENT_6G_RADIO_UCI_PATH $nof_channels 0`

			debug_print "dis_subchannel_bitmap_value=$dis_subchnl_bitmap_val"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'punct_bitmap' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="punct_bitmap=${dis_subchnl_bitmap_val}"
		fi

		if [ "$ap_he_txop_dur_rts_thr_conf" != "" ]; then
			debug_print "ap_he_txop_dur_rts_thr_conf:$ap_he_txop_dur_rts_thr_conf"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_operation_txop_duration_rts_threshold' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_operation_txop_duration_rts_threshold=${ap_he_txop_dur_rts_thr_conf}"
		fi

		if [ "$ap_eht_scs_traffic_support" == "1" ]; then
			debug_print "ap_eht_scs_traffic_support:$ap_eht_scs_traffic_support"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'eht_mac_scs_traffic_desc' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_scs_traffic_desc=${ap_eht_scs_traffic_support}"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_scs_traffic_desc=${ap_eht_scs_traffic_support}"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="eht_mac_scs_traffic_desc=${ap_eht_scs_traffic_support}"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_24G_RADIO_UCI_PATH`
            set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x3=0 x4=1 x5=1 x6=0 x7=1 x8=2300 x9=26 x10=6 x11=6 x12=2 x13=2 x14=2 x15=3082 x16=3
            set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x3=0 x4=1 x5=1 x6=0 x7=1 x8=2300 x9=26 x10=6 x11=6 x12=2 x13=2 x14=2 x15=3082 x16=3
            set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=5 x3=0 x4=1 x5=1 x6=0 x7=1 x8=2300 x9=26 x10=6 x11=6 x12=2 x13=2 x14=2 x15=3082 x16=3	
			usr_index=1
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`

			set_get_helper $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlannUser$usr_index" x$dl_usr_ul_psdu_rate_per_usp_idx=9 x$dl_usr_psdu_rate_per_usp_idx=9 x$rcr_tf_usr_psdu_rate_idx=9
			set_get_helper $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlannUser$usr_index" x$dl_usr_ul_psdu_rate_per_usp_idx=9 x$dl_usr_psdu_rate_per_usp_idx=9 x$rcr_tf_usr_psdu_rate_idx=9
			set_get_helper $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlannUser$usr_index" x$dl_usr_ul_psdu_rate_per_usp_idx=9 x$dl_usr_psdu_rate_per_usp_idx=9 x$rcr_tf_usr_psdu_rate_idx=9

		fi

		#Re-spawn SMD in-case Preamble Puncture was enabled as the previous SMD was spawned before Preamble Puncture config reached us
		if [ "$global_ap_preamble_puncture" = "enable" ]; then
			get_nof_sta_per_he_test_case $glob_ssid
			ap_num_users_ofdma=$nof_sta
			arguments_file_initializer $CURRENT_RADIO_UCI_PATH $glob_ssid
			kill_sigmaManagerDaemon
			/lib/netifd/sigmaManagerDaemon.sh $CURRENT_WLAN_NAME.0 $ap_num_users_ofdma &
		fi

		if [ "$ap_rnr_op_class" != "" ] && [ "$ap_rnr_op_class" = "6_137" ]; then
			eval ML_VAP1_UCI_PATH=\${CURRENT_${ML_VAP1}_RADIO_UCI_PATH}
			ap_get_debug_hostap_conf_idx=`uci show wireless | grep debug_hostap | grep $ML_VAP1_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			let ap_get_debug_hostap_conf_idx=ap_get_debug_hostap_conf_idx+1
			ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx))"
			$UCI_CMD set $ML_VAP1_UCI_PATH.$ap_get_debug_hostap_conf="rnr_6g_op_class_137_allowed=1"
		fi
		if [ "$ap_rnr_tbtt_res" != "" -a "$ap_rnr_tbtt_res" = "nonzero" ] && [ "$ap_program" = "EHT" ]; then
			ap_get_debug_hostap_conf_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_24G_RADIO_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx+1))"
			$UCI_CMD set $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf="rnr_tbtt_mld_non_zero_pad=2"
			ap_get_debug_hostap_conf_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_5G_RADIO_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx+1))"
			$UCI_CMD set $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf="rnr_tbtt_mld_non_zero_pad=2"
			ap_get_debug_hostap_conf_idx=`uci show wireless | grep debug_hostap | grep $CURRENT_6G_RADIO_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf_idx+1))"
			$UCI_CMD set $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf="rnr_tbtt_mld_non_zero_pad=2"
		fi
		check_and_force_eht_fixed_rate_cfg
	fi #HE and EHT
	if [ -n "$ap_non_tx_bss_index" ]; then
		sleep 10	# adding enough time for non-Tx interface to come up.
	fi
	send_complete
}

ap_set_11n_wireless()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	if [ "$CURRENT_IFACE_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			WLAN_TAG)
				# skip as it is determined in get_interface_details
			;;
			AMPDU)
				debug_print "set parameter ap_ampdu=$1"
			;;
			SPATIAL_RX_STREAM)
				# do nothing
				debug_print "set parameter ap_spatial_rx_stream=$1"
			;;
			SPATIAL_TX_STREAM)
				# do nothing
				debug_print "set parameter ap_spatial_tx_stream=$1"
			;;
			SGI20)
				debug_print "set parameter ap_sgi20=$1"
				lower "$1" ap_enable_input
				if [ "$ap_enable_input" = "enable" ]; then
					ap_sgi_20=1
				else
					ap_sgi_20=0
				fi
				$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.short_gi_20=$ap_sgi_20
			;;
			WIDTH)
				debug_print "set parameter ap_width=$1"
				ap_curr_mode=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.htmode`
				ap_curr_prefix=`echo "${ap_curr_mode//[^[:alpha:]]/}"`
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode=$ap_curr_prefix$1
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,7"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_set_11h()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	if [ "$CURRENT_RADIO_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			WLAN_TAG)
				# skip as it is determined in get_interface_details
			;;
			DFS_CHAN)
				debug_print "set parameter ap_dfs_chan=$1"
				$UCI_CMD set ${CURRENT_RADIO_UCI_PATH}.channel=$1
			;;
			DFS_MODE)
				debug_print "set parameter ap_dfs_mode=$1"
				lower "$1" ap_enable_input
				if [ "$ap_enable_input" = "enable" ]; then
					ap_doth=1
				else
					ap_doth=0
				fi
				$UCI_CMD set ${CURRENT_RADIO_UCI_PATH}.doth=$ap_doth
			;;
			REGULATORY_MODE)
				# param not supported
				debug_print "set parameter ap_regulatory_mode=$1"
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,7"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_set_11d()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	if [ "$CURRENT_RADIO_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			WLAN_TAG)
				# skip as it is determined in get_interface_details
			;;
			COUNTRYCODE)
				debug_print "set parameter ap_country_code=$1"
				radios=`uci show wireless | grep country | cut -d"." -f1-2`
				for radio in $radios
				do
					$UCI_CMD set $radio.country=$1
				done
				radio_6ghz_disabled=`uci show wireless | grep 6GHz | cut -d"." -f1-2`
				$UCI_CMD set $radio_6ghz_disabled.disabled='1' #currently 6GHz channel support not defined for all countrycode
			;;
			REGULATORY_MODE)
				# param not supported
				debug_print "set parameter ap_regulatory_mode=$1"
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,7"
				return
			;;
		esac
		shift
	done

	send_complete
}

derive_key_mgnt_from_akmsuitetype()
{
		debug_print "set parameter ap_keymgnt=$1"
		ap_keymgnt=$1
		get_uci_security_mode "$1"
		ap_reg_domain=`$UCI_CMD get ${CURRENT_RADIO_UCI_PATH}.country3`

		if [ "$ap_uci_security_mode" = "" ]; then
			send_invalid ",errorCode,2"
			return
		else
			if [ "$CONFIGURE_BOTH_BANDS" != "" ] && [ $CONFIGURE_BOTH_BANDS -gt 0 ]; then
				$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.encryption=$ap_uci_security_mode
				$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.encryption=$ap_uci_security_mode
			else
				if [ "$ucc_program" = "eht" -a "$ap_mld_id" = "" ]; then
					$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.encryption=$ap_uci_security_mode
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.encryption=$ap_uci_security_mode
					$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.encryption=$ap_uci_security_mode
				else
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.encryption=$ap_uci_security_mode
				fi
			fi
		fi

		if [ "$ap_uci_security_mode" = "sae-mixed" ]; then
			$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ieee80211w=1
			if [ "$ucc_program" = "wpa3" ]; then
				$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=1
			else
				$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=2
            		fi
		fi
		if [ "$ap_uci_security_mode" = "sae" ] || [ "$ap_uci_security_mode" = "sae-ext-key" ]; then
			if [ "$ucc_program" = "eht" ]; then
				$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.ieee80211w=2
                $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.auth_cache=1
                $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.interworking=1
				if [ "$ap_reg_domain" != "" ]; then
					$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.mbo=1
				else
					$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.mbo=0
				fi

				$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.ieee80211w=2
                $UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.auth_cache=1
                $UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.interworking=1
				if [ "$ap_reg_domain" != "" ]; then
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.mbo=1
				else
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.mbo=0
				fi

				$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.ieee80211w=2
                $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.auth_cache=1
                $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.interworking=1
				if [ "$ap_reg_domain" != "" ]; then
					$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=1
				else
					$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=0
				fi

				if [ -z "$ap_non_tx_bss_index" ]; then
					$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=1
                    $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.sae_pwe=1
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.sae_pwe=1
					$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.sae_pwe=1
				fi
			else
				$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ieee80211w=2
	            $UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.auth_cache=1
        	    $UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.interworking=1
                $UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.mbo=0
                #Enable both HnP and H2E in 2.4GHz/5GHz testbed mode if the base security configured is WPA3-SAE
                #Enable H2E for both 6GHz DUT and Testbed modes
                ap_sae_band=`$UCI_CMD get ${CURRENT_RADIO_UCI_PATH}.band | cut -d"=" -f2`
                if [ -z "$ap_non_tx_bss_index" ]; then
                    if [ "$ap_sae_band" = "6GHz" ]; then
                        $UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.mbo=1
                        $UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=1
                    else #2.4GHz/5GHz
                        $UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=2
                    fi
                fi
			fi
		fi
		if [ "$ap_uci_security_mode" = "owe" ]; then
			$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ieee80211w=2
			$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.mbo=0
		fi
}

ap_set_security()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	if [ "$ucc_program" = "eht" ]; then
		if [ "$global_ap_mimo" = "dl" ] && [ "$ucc_type" = "dut" ]; then
			if [ "$ML_VAP1" = "24G" ]; then #Handles cases 2.4GHz+5GHz and 2.4GHz+6GHz AP-MLDs
				/lib/netifd/sigmaManagerDaemon.sh $CURRENT_24G_WLAN_NAME.0 2 &
				[ "$ML_VAP2" = "5G" ] && /lib/netifd/sigmaManagerDaemon.sh $CURRENT_5G_WLAN_NAME.0 2 &
				[ "$ML_VAP2" = "6G" ] && /lib/netifd/sigmaManagerDaemon.sh $CURRENT_6G_WLAN_NAME.0 2 &
			else #Handles 5GHz+6GHz AP-MLD
				/lib/netifd/sigmaManagerDaemon.sh $CURRENT_5G_WLAN_NAME.0 2 &
				/lib/netifd/sigmaManagerDaemon.sh $CURRENT_6G_WLAN_NAME.0 2 &
			fi
		fi

		if [ "$global_mu_txbf" = "" ] && [ "$glob_ap_ofdma" = "dl" ] && [ "$global_ap_tx_bf" = "" ] && [ "$global_ap_num_users_ofdma" = "2" ] && [ "$ucc_type" = "dut" ]; then
			if [ "$ML_VAP1" = "24G" ]; then #Handles cases 2.4GHz+5GHz and 2.4GHz+6GHz AP-MLDs
				/lib/netifd/sigmaManagerDaemon.sh $CURRENT_24G_WLAN_NAME.0 2 &
				[ "$ML_VAP2" = "5G" ] && /lib/netifd/sigmaManagerDaemon.sh $CURRENT_5G_WLAN_NAME.0 2 &
				[ "$ML_VAP2" = "6G" ] && /lib/netifd/sigmaManagerDaemon.sh $CURRENT_6G_WLAN_NAME.0 2 &
			else #Handles 5GHz+6GHz AP-MLD
				/lib/netifd/sigmaManagerDaemon.sh $CURRENT_5G_WLAN_NAME.0 2 &
				/lib/netifd/sigmaManagerDaemon.sh $CURRENT_6G_WLAN_NAME.0 2 &
			fi
		fi
	fi

	debug_print "The value of the mlo_counter is $mlo_counter"
	if [ "$mlo_counter" = "1" ] && [ "$global_ap_interface" != "" ]; then
		rand_mac_mld="ac:9a:96:84:68:44"
		if [ "$global_ap_interface" = "5G" ] || [ "$global_ap_interface" = "6G" ]; then
			ap_get_debug_hostap_conf=`grep 'mlo_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
			$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.ssid=$glob_ssid
			$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
			$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.ssid=$glob_ssid

			ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$ap_get_debug_hostap_conf"
			$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
			$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
			mac_addr=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.macaddr`
			ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
			$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
			mac_addr=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.macaddr`
			$UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
			ML_VAP1="5G"
			ML_VAP2="6G"
		else
			ap_get_debug_hostap_conf=`grep 'mlo_enable' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
			$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.ssid=$glob_ssid
			$UCI_CMD set $CURRENT_24G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mlo_enable=1"
			$UCI_CMD set $CURRENT_24G_IFACE_UCI_PATH.ssid=$glob_ssid

			ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$ap_get_debug_hostap_conf"
			$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
			$UCI_CMD set $CURRENT_24G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="ap_mld_mac=$rand_mac_mld"
			mac_addr=`$UCI_CMD get $CURRENT_24G_IFACE_UCI_PATH.macaddr`
			ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
			ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
			$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
			mac_addr=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.macaddr`
			$UCI_CMD set $CURRENT_24G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="sibling_bss_mac=$mac_addr"
			ML_VAP1="24G"
			ML_VAP2="5G"
		fi
		ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_IFACE_UCI_PATH | cut -d"_" -f5 | cut -d"=" -f1 | sort -n | tail -1`
		ap_get_debug_hostap_conf="debug_hostap_conf_$((ap_get_debug_hostap_conf+1))"
		$UCI_CMD set $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mld_num_simul_links=0"
		[ "$ML_VAP2" = "6G" ] && $UCI_CMD set $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mld_num_simul_links=0"
		[ "$ML_VAP1" = "24G" ] && $UCI_CMD set $CURRENT_24G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf="mld_num_simul_links=0"
	fi

	get_common_uci_path
	get_interface_details $@

	if [ "$CURRENT_IFACE_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			WLAN_TAG)
				# skip as it is determined in get_interface_details
			;;
			KEYMGNT)
				debug_print "set parameter ap_keymgnt=$1"
				ap_keymgnt=$1
				if [ "$ucc_program" = "eht" ] && [ ! -e "/tmp/sae_override" ]; then
					ap_uci_security_mode="sae-ext-key"
				else
					get_uci_security_mode "$1"
				fi
				debug_print "Setting security to $ap_uci_security_mode"
				if [ "$ap_uci_security_mode" = "" ]; then
					send_invalid ",errorCode,2"
					return
				else
					if [ "$CONFIGURE_BOTH_BANDS" != "" ] && [ $CONFIGURE_BOTH_BANDS -gt 0 ]
					then
						$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.encryption=$ap_uci_security_mode
						$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.encryption=$ap_uci_security_mode
					else
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.encryption=$ap_uci_security_mode
					
					fi
				fi
			
				tc_name=`get_test_case_name $glob_ssid`
				if [ "$ML_VAP1" != "" ] && [ "$ML_VAP2" != "" ]; then
					eval ML_VAP1_UCI_PATH=\${CURRENT_${ML_VAP1}_IFACE_UCI_PATH}
					$UCI_CMD set $ML_VAP1_UCI_PATH.encryption=$ap_uci_security_mode
					eval ML_VAP2_UCI_PATH=\${CURRENT_${ML_VAP2}_IFACE_UCI_PATH}
					$UCI_CMD set $ML_VAP2_UCI_PATH.encryption=$ap_uci_security_mode
				else
					debug_print "MLD is not configured or the Program is not EHT"
				fi
								
				if [ "$ap_uci_security_mode" = "sae-mixed" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ieee80211w=1
					if [ "$ucc_program" = "wpa3" ]; then
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=1
					else
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=2
					fi
				fi
				if [ "$ap_uci_security_mode" = "sae" ] || [ "$ap_uci_security_mode" = "sae-ext-key" ]; then
					if [ "$ML_VAP1" != "" ] && [ "$ML_VAP2" != "" ]; then #Specific for EHT
						debug_print "ML VAPS are $ML_VAP1 and $ML_VAP2"
						ap_reg_domain=`$UCI_CMD get ${CURRENT_RADIO_UCI_PATH}.country3`
						if [ "$ML_VAP1" = "24G" ]; then
							$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.ieee80211w=2
	        	            $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.auth_cache=1
        	        	    $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.interworking=1
							if [ "$ap_reg_domain" != "" ]; then
								$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.mbo=1
							else
								$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.mbo=0
							fi
							[ -z "$ap_non_tx_bss_index" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.sae_pwe=1
							$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.ap_protected_keep_alive_required=1
							if [ "$ML_VAP2" = "5G" ]; then
								$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.ieee80211w=2
								$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.auth_cache=1
								$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.interworking=1
								if [ "$ap_reg_domain" != "" ]; then
									$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.mbo=1
								else
									$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.mbo=0
								fi
								[ -z "$ap_non_tx_bss_index" ] && $UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.sae_pwe=1
								$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.ap_protected_keep_alive_required=1
							else
								$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.ieee80211w=2
								$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.auth_cache=1
								$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.interworking=1
								if [ "$ap_reg_domain" != "" ]; then
									$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=1
								else
									$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=0
								fi
								[ -z "$ap_non_tx_bss_index" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=1
								[ -z "$ap_non_tx_bss_index" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.sae_pwe=1
								#Advertise protected keepalive frames in BSS Max Idle IE when PMF is set
								#Note that the lower layers may still accept unprotected keepalive frames from the station
								$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.ap_protected_keep_alive_required=1
							fi
						elif [ "$ML_VAP1" = "5G" ] && [ "$ML_VAP2" = "6G" ]; then
							$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.ieee80211w=2
							$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.auth_cache=1
							$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.interworking=1
							if [ "$ap_reg_domain" != "" ]; then
								$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.mbo=1
							else
								$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.mbo=0
							fi
							[ -z "$ap_non_tx_bss_index" ] && $UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.sae_pwe=1
							$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.ap_protected_keep_alive_required=1
		                    $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.ieee80211w=2
                		    $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.auth_cache=1
                            $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.interworking=1
							if [ "$ap_reg_domain" != "" ]; then
								$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=1
							else
								$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=0
							fi
							[ -z "$ap_non_tx_bss_index" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.mbo=1
                            [ -z "$ap_non_tx_bss_index" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.sae_pwe=1
							#Advertise protected keepalive frames in BSS Max Idle IE when PMF is set
	                        #Note that the lower layers may still accept unprotected keepalive frames from the station
        	        	    $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.ap_protected_keep_alive_required=1
						else
							debug_print "MLD is  not configured yet"
						fi
					else
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ieee80211w=2
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.auth_cache=1
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.interworking=1
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.mbo=0
						#Enable both HnP and H2E in 2.4GHz/5GHz testbed mode if the base security configured is WPA3-SAE
						#Enable H2E for both 6GHz DUT and Testbed modes
						ap_sae_band=`$UCI_CMD get ${CURRENT_RADIO_UCI_PATH}.band | cut -d"=" -f2`
						if [ -z "$ap_non_tx_bss_index" ]; then
							if [ "$ucc_program" != "eht" ] && [ "$ap_sae_band" = "6GHz" ]; then
								$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.mbo=1
								$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=1
							else #2.4GHz/5GHz
								$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=2
							fi
						fi
					#Advertise protected keepalive frames in BSS Max Idle IE when PMF is set
					#Note that the lower layers may still accept unprotected keepalive frames from the station
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ap_protected_keep_alive_required=1
					fi
				fi

				if [ "$ap_uci_security_mode" = "owe" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ieee80211w=2
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.mbo=0
				fi
			;;
			ENCRYPT)
				debug_print "set parameter ap_encrypt=$1"
				get_uci_encryption "$1"
				if [ "$ap_uci_encrypt" = "" ]; then
					send_invalid ",errorCode,2"
					return
				else
					if [ "$ap_program" = "EHT" ]; then
						echo "Requested configuration is not supported."
					else
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.encryption=$ap_uci_encrypt
					fi
				fi
			;;
			PSK)
				debug_print "set parameter ap_psk=$1"
				ap_psk=$1
				if [ "$CONFIGURE_BOTH_BANDS" != "" ] && [ $CONFIGURE_BOTH_BANDS -gt 0 ]
				then
					$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.key=$1
					$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.key=$1
				else
					if [ -n "$ML_VAP1" ] && [ -n "$ML_VAP2" ]; then
						$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.key=$1
						if [ "$ML_VAP1" = "24G" ] && [ "$ML_VAP2" = "5G" ]; then
							$UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.key=$1
						elif [ "$ML_VAP1" = "5G" ] && [ "$ML_VAP2" = "6G" ]; then
							$UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.key=$1
						else
							debug_print "MLD is not configured yet"
						fi
					else
						[ -z $ap_non_tx_bss_index ] && $UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.key=$1
					fi
				fi
			;;
			WEPKEY)
				debug_print "set parameter ap_wepkey=$1"
				$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.key=$1
			;;
			SSID)
				debug_print "set parameter ap_ssid=$1"
			;;
			PMF)
				debug_print "set parameter ap_pmf=$1"
				get_uci_pmf "$1"
				if [ "$ap_uci_pmf" = "" ]; then
					send_invalid ",errorCode,2"
					return
				else
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ieee80211w=$ap_uci_pmf
				fi
			;;
			SHA256AD)
				# param not supported
				debug_print "set parameter ap_sha256ad=$1"
			;;
			AKMSUITETYPE)
				debug_print "set parameter ap_akm_suite_type=$1"
				case "$1" in
					"2;8")
						derive_key_mgnt_from_akmsuitetype "WPA2-PSK-SAE"
					;;
					"24"|"8;24"|"24;8")
						derive_key_mgnt_from_akmsuitetype "SAE-EXT-KEY"
					;;
					"18")
						derive_key_mgnt_from_akmsuitetype "OWE"
					;;
				esac
			;;
			PMKSACACHING)
				debug_print "set parameter ap_pmks_a_caching=$1"
				upper "$1" ap_pmksacaching
				if [ "$ap_pmksacaching" = "DISABLED" ]; then
					local ap_ac_enable=0
				elif [ "$ap_pmksacaching" = "ENABLED" ]; then
					local ap_ac_enable=1
				else
					send_invalid ",errorCode,2"
					return
				fi
				$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.auth_cache=$ap_ac_enable
			;;
			ANTICLOGGINGTHRESHOLD)
				debug_print "set parameter sae_anti_clogging_threshold=$1"
				$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.debug_hostap_conf="sae_anti_clogging_threshold=$1"
			;;
			PAIRWISECIPHER)
				debug_print "set parameter pairwise_cipher=$1"
				get_uci_pairwise_cipher $1
				if [ "$ucc_program" = "eht" ]; then
					if [ -n "$ML_VAP1" ] || [ -n "$ML_VAP2" ]; then
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'wpa_pairwise' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.$ap_get_debug_hostap_conf_or_Post_Up_idx="wpa_pairwise=$ap_cipher"
						$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.$ap_get_debug_hostap_conf_or_Post_Up_idx="wpa_pairwise=$ap_cipher"
						[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.$ap_get_debug_hostap_conf_or_Post_Up_idx="wpa_pairwise=$ap_cipher"
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'rsn_pairwise' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.$ap_get_debug_hostap_conf_or_Post_Up_idx="rsn_pairwise=$ap_cipher"
						$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.$ap_get_debug_hostap_conf_or_Post_Up_idx="rsn_pairwise=$ap_cipher"
						[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.$ap_get_debug_hostap_conf_or_Post_Up_idx="rsn_pairwise=$ap_cipher"
					else
						ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'wpa_pairwise' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
						$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.$ap_get_debug_hostap_conf_or_Post_Up_idx="wpa_pairwise=$ap_cipher"
					fi
				else
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.debug_hostap_conf="wpa_pairwise=$ap_cipher"
				fi
			;;
			GROUPCIPHER)
				# param not supported
				debug_print "set parameter group_cipher=$1"
			;;
			GROUPMGNTCIPHER)
				debug_print "set parameter group_mgnt_cipher=$1"
				if [ "$1" == "BIP-CMAC-128" ]; then
					debug_print "Recieved BIP-CMAC-128"
				else
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.debug_hostap_conf="group_mgmt_cipher=$1"
				fi
			;;
			REFLECTION)
				# param not supported
				debug_print "set parameter reflection=$1"
			;;
			INVALIDSAEELEMENT)
				# param not supported
				debug_print "set parameter invalid_sae_element=$1"
			;;
			ECGROUPID)
				debug_print "set parameter ec_group_id=$1"
				ap_sae_groups=$1
				if [ "$ucc_program" != "eht" ]; then
					ap_sae_groups=`echo $1 | sed 's/;/ /g'`
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.debug_hostap_conf="sae_groups=$ap_sae_groups"
				else
					debug_print "do not configure ecgroup as hostapd is taking 19 0 as default"
				fi
			;;
			NONTXBSSINDEX)
				debug_print "ap_set_security: set ap_non_tx_bss_index=$1"
				ap_non_tx_bss_index=$1
			;;
			MLD_ID)
				debug_print "set parameter ap_mld_id=$1"
				ap_mld_id=$1
				if [ "$ap_mld_id" = "2" ]; then
					CURRENT_IFACE_UCI_PATH=$CURRENT_IFACE_UCI_PATH_2
					[ "$ap_interface" = "6G" ] && CURRENT_IFACE_UCI_PATH=$CURRENT_6G_IFACE_UCI_PATH_2
				fi
			;;
			COHOSTEDBSSINDEX)
				debug_print "set parameter ap_cohosted_bss_index=$1"
				ap_cohosted_bss_index=$1
			;;
			CHNLFREQ)
				debug_print "ignore CHNLFREQ"
			;;
			SAE_PWE)
				if [ "$1" = "looping" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=0
				fi
				if [ "$1" = "h2e" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.sae_pwe=1
				fi
			;;
			TRANSITION_DISABLE)
				ap_transition_disable=$1
			;;
			TRANSITION_DISABLE_INDEX)
				ap_transition_disable_index=$1
			;;
			*)
				debug_print "while loop error $1"
				send_invalid ",errorCode,18"
				return
			;;
		esac
		shift
	done

	if [ -n "$ap_transition_disable" ]; then
		if [ "$ap_transition_disable" = "1" ]; then
			if [ -n "$ap_transition_disable_index" ]; then
				local transition_disable=$((0x1 << $ap_transition_disable_index))
				debug_print "transition_disable set to $transition_disable"
				$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.transition_disable=$transition_disable
			fi
		fi
	fi

	if [ -n "$ap_non_tx_bss_index" ]; then
		([ $ap_non_tx_bss_index -lt 1 ] || [ $ap_non_tx_bss_index -gt 8 ]) && error_print "NonTxBSSIndex invalid value '$1'" && send_invalid ",errorCode,96" && return
		vap_index=$((ap_non_tx_bss_index))
		if [ -n "$ap_keymgnt" ] && [ -n "$ap_psk" ]; then
			[ "$ap_keymgnt" = "wpa2-psk" ] && ap_keymgnt="WPA2-Personal"
			tmp_current_o_vap="mbss_vap_$vap_index"
			current_o_vap=`eval 'echo $'$tmp_current_o_vap`
			debug_print "------------------------ security: current_o_vap=$current_o_vap ------------------------"
			$UCI_CMD set wireless.$current_o_vap.encryption="$ap_uci_security_mode"
			$UCI_CMD set wireless.$current_o_vap.key="$ap_psk"
			if [ "$ucc_program" = "eht" ]; then
				$UCI_CMD set wireless.$current_o_vap.debug_hostap_conf_1="wpa_pairwise=GCMP-256"
				$UCI_CMD set wireless.$current_o_vap.debug_hostap_conf_2="rsn_pairwise=GCMP-256"
				$UCI_CMD set wireless.$current_o_vap.debug_hostap_conf_3="eml_capab_transition_timeout=4"
				$UCI_CMD set wireless.$current_o_vap.group_mgmt_cipher="BIP-GMAC-256"
			fi
			#Enable both HnP and H2E in 2.4GHz/5GHz testbed mode if the base security configured is WPA3-SAE
			#Enable H2E for both 6GHz DUT and Testbed modes
			if [ "$ucc_program" != "eht" ] && [ "$ap_sae_band" = "6GHz" ]; then
				$UCI_CMD set wireless.$current_o_vap.mbo=1
				$UCI_CMD set wireless.$current_o_vap.sae_pwe=1
			else #2.4GHz/5GHz
				$UCI_CMD set wireless.$current_o_vap.sae_pwe=2
			fi
			ap_non_tx_bss_index=""
			ap_keymgnt=""
			ap_psk=""
			ap_sae_band=""
		fi
	fi

	if [ -n "$ap_cohosted_bss_index" ]; then
		if [ -n "$ap_keymgnt" ] && [ -n "$ap_psk" ]; then
			if [ "$ap_mld_id" = "$ap_cohosted_bss_index" ]; then
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.encryption="$ap_uci_security_mode"
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.key="$ap_psk"
				#Enable both HnP and H2E testbed mode if the base security configured is WPA3-SAE
				$UCI_CMD set $CURRENT_IFACE_UCI_PATH.sae_pwe=2
				if [ "$ap_mld_id" = "2" ]; then
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.debug_hostap_conf_1="wpa_pairwise=GCMP-256"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.debug_hostap_conf_2="rsn_pairwise=GCMP-256"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.debug_hostap_conf_3="eml_capab_transition_timeout=4"
					$UCI_CMD set $CURRENT_IFACE_UCI_PATH.group_mgmt_cipher="BIP-GMAC-256"
				fi
			fi
		fi
	fi

	send_complete
}

start_wps_registration()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			WPSROLE)
				debug_print "set parameter ap_wps_role=$1"
				# no param for this in our DB.
				# we are already configured correctly by default no action here.
				# By default AP is Registrar and STA is Enrollee
			;;
			WPSCONFIGMETHOD)
				debug_print "set parameter ap_wps_config_method=$1"
				# ConfigMethodsEnabled
				# we are already configured correctly by default no action here.
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,20"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_set_wps_pbc()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,21"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_set_pmf()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			PMF)
				debug_print "set parameter ap_pmf_ena=$1"
				get_uci_pmf "$1"
				if [ "$ap_uci_pmf" = "" ]; then
					send_invalid ",errorCode,2"
					return
				else
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.ieee80211w=$ap_uci_pmf
				fi
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,22"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_set_apqos()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	if [ "$CURRENT_IFACE_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip as it is determined in get_interface_details
			;;
			CWMIN*)
				lower "${token#CWMIN_*}" ap_actype
				ap_acpref=${ap_actype#*cwmin_}
				get_apqos_data_idx $ap_acpref
				local ap_cwmin=$((1<<$1))
				ap_cwmin=$((ap_cwmin-1))
				debug_print "set parameter ap_cwmin=$ap_cwmin"
				if [ "$ucc_program" != "eht" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_cwmin=$ap_cwmin
				else #Specific for EHT
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_cwmin=$ap_cwmin
					[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_cwmin=$ap_cwmin	
					[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_cwmin=$ap_cwmin
				fi		
			;;
			CWMAX*)
				lower "${token#CWMAX_*}" ap_actype
				ap_acpref=${ap_actype#*cwmax_}
				get_apqos_data_idx $ap_acpref
				local ap_cwmax=$((1<<$1))
				ap_cwmax=$((ap_cwmax-1))
				debug_print "set parameter ap_cwmax=$ap_cwmax"
				if [ "$ucc_program" != "eht" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_cwmax=$ap_cwmax
				else #Specific for EHT
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_cwmax=$ap_cwmax
					[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_cwmax=$ap_cwmax
					[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_cwmax=$ap_cwmax
				fi
			;;
			AIFS*)
				lower "${token#AIFS_*}" ap_actype
				debug_print "set parameter ap_aifs=$1"
				ap_acpref=${ap_actype#*aifs_}
				get_apqos_data_idx $ap_acpref
				if [ "$ucc_program" != "eht" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_aifs=$1
				else #Specific for EHT
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_aifs=$1	
					[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_aifs=$1
					[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.tx_queue_data${ap_data_idx}_aifs=$1
				fi	
			;;
			TXOP*)
				lower "${token#TXOP_*}" ap_actype
				debug_print "set parameter ap_txop=$1"
			;;
			ACM*)
				lower "${token#ACM_*}" ap_actype
				debug_print "set parameter ap_acm=$1"
				lower "$ap_acm" ap_acm_${ap_actype}
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,31"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_set_staqos()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	if [ "$CURRENT_IFACE_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip as it is determined in get_interface_details
			;;
			CWMIN*)
				lower "${token#CWMIN_*}" ap_actype
				debug_print "set parameter ap_cwmin=$1"
				ap_acpref=${ap_actype#*cwmin_}
				if [ "$ucc_program" != "eht" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_cwmin=$1
				else #Specific for EHT	
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_cwmin=$1
					[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_cwmin=$1
					[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_cwmin=$1
				fi	
			;;
			CWMAX*)
				lower "${token#CWMAX_*}" ap_actype
				debug_print "set parameter ap_cwmax=$1"
				ap_acpref=${ap_actype#*cwmax_}
				if [ "$ucc_program" != "eht" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_cwmax=$1
				else #Specific for EHT
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_cwmax=$1	
					[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_cwmax=$1	
					[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_cwmax=$1	
				fi	
			;;
			AIFS*)
				lower "${token#AIFS_*}" ap_actype
				debug_print "set parameter ap_aifs=$1"
				ap_acpref=${ap_actype#*aifs_}
				if [ "$ucc_program" != "eht" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_aifs=$1
				else #Specif for EHT
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_aifs=$1
					[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_aifs=$1
					[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_aifs=$1
				fi	
			;;
			TXOP*)
				lower "${token#TXOP_*}" ap_actype
				debug_print "set parameter ap_txop=$1"
				ap_acpref=${ap_actype#*txop_}
				if [ "$ucc_program" != "eht" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_txop_limit=$1
				else #Specific for EHT	
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_txop_limit=$1
					[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_txop_limit=$1
					[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_txop_limit=$1
				fi
			;;
			ACM*)
				lower "${token#ACM_*}" ap_actype
				debug_print "set parameter ap_acm=$1"

				if [ "$1" = "off" ]; then
					ap_acm_enable=0
				elif [ "$1" = "on" ]; then
					ap_acm_enable=1
				else
					send_invalid ",errorCode,2"
					return
				fi

				ap_acpref=${ap_actype#*acm_}
				if [ "$ucc_program" != "eht" ]; then
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_acm=$ap_acm_enable
				else #Specific for aEHT	
					$UCI_CMD set ${CURRENT_5G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_acm=$ap_acm_enable
					[ "$ML_VAP1" = "24G" ] && $UCI_CMD set ${CURRENT_24G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_acm=$ap_acm_enable
					[ "$ML_VAP2" = "6G" ] && $UCI_CMD set ${CURRENT_6G_IFACE_UCI_PATH}.wmm_ac_${ap_acpref}_acm=$ap_acm_enable
				fi	
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,37"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_set_radius()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	if [ "$CURRENT_IFACE_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			IPADDR)
				debug_print "set parameter ap_ipaddr=$1"
				tc_name=`get_test_case_name $glob_ssid`
				if [ "$ap_type" != "EHT" ] && [ "$tc_name" = "4.7.1" ]; then 
					CONFIGURE_BOTH_BANDS=1
				fi
				if [ "$CONFIGURE_BOTH_BANDS" != "" ] && [ $CONFIGURE_BOTH_BANDS -gt 0 ]
				then
					$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.server=$1
					$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.server=$1
				else
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.server=$1
				fi
			;;
			PORT)
				debug_print "set parameter ap_port=$1"
				if [ "$CONFIGURE_BOTH_BANDS" != "" ] && [ $CONFIGURE_BOTH_BANDS -gt 0 ]
				then
					$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.port=$1
					$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.port=$1
				else
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.port=$1
				fi
			;;
			PASSWORD)
				debug_print "set parameter ap_password=$1"
				if [ "$CONFIGURE_BOTH_BANDS" != "" ] && [ $CONFIGURE_BOTH_BANDS -gt 0 ]
				then
					$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.key=$1
					$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.key=$1
				else
					$UCI_CMD set ${CURRENT_IFACE_UCI_PATH}.key=$1
				fi
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,38"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_set_hs2()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERWORKING)
				debug_print "set parameter ap_interworking=$1"
			;;
			ACCS_NET_TYPE)
				debug_print "set parameter ap_accs_net_type=$1"
			;;
			INTERNET)
				debug_print "set parameter ap_internet=$1"
			;;
			VENUE_GRP)
				debug_print "set parameter ap_venue_grp=$1"
			;;
			VENUE_TYPE)
				debug_print "set parameter ap_venue_type=$1"
			;;
			VENUE_NAME)
				debug_print "set parameter ap_venue_name=$1"
			;;
			HESSID)
				debug_print "set parameter ap_hessid=$1"
			;;
			ROAMING_CONS)
				debug_print "set parameter ap_roaming_cons=$1"
			;;
			DGAF_DISABLE)
				debug_print "set parameter ap_dgaf_disabled=$1"
			;;
			ANQP)
				debug_print "set parameter ap_anqp=$1"
			;;
			NET_AUTH_TYPE)
				debug_print "set parameter ap_net_auth_type=$1"
			;;
			NAI_REALM_LIST)
				debug_print "set parameter ap_nai_realm_list=$1"
			;;
			DOMAIN_LIST)
				debug_print "set parameter ap_domain_list=$1"
			;;
			OPER_NAME)
				debug_print "set parameter ap_oper_name=$1"
			;;
			GAS_CB_DELAY)
				debug_print "set parameter ap_gas_cb_delay=$1"
			;;
			MIH)
				# param not supported
				debug_print "set parameter ap_mih=$1"
			;;
			L2_TRAFFIC_INSPECT)
				# not defined in Oliver's doc
				debug_print "set parameter ap_l2_traffic_inspect=$1"
			;;
			BCST_UNCST)
				# param not supported
				debug_print "set parameter ap_bcst_uncst=$1"
			;;
			PLMN_MCC)
				PLMN_MCC_VAL="$1"
				debug_print "set parameter ap_plmn_mcc=$1"
			;;
			PLMN_MNC)
				debug_print "set parameter ap_plmn_mnc=$1"
			;;
			PROXY_ARP)
				debug_print "set parameter ap_proxy_arp=$1"
			;;
			WAN_METRICS)
				debug_print "set parameter ap_wan_metrics=$1"
			;;
			CONN_CAP)
				case "$1" in
					1)
						debug_print "set parameter addConnectionCap 6:20:1"
						debug_print "set parameter addConnectionCap 6:80:1"
						debug_print "set parameter addConnectionCap 6:443:1"
						debug_print "set parameter addConnectionCap 17:244:1"
						debug_print "set parameter addConnectionCap 17:4500:1"
					;;
				esac
			;;
			IP_ADD_TYPE_AVAIL)
				case "$1" in
					1)
						debug_print "set parameter ipv4AddrType"
					;;
				esac
			;;
			ICMPv4_ECHO)
				debug_print "set parameter ap_icmpv4_echo=$1"
				#wlancli -c set_wlan_hs_l2_firewall_list -P addAction "$1" addProtocol 1
			;;
			OPER_CLASS)
				case "$1" in
					1)
						debug_print "set parameter operatingClass=51"
					;;
					2)
						debug_print "set parameter operatingClass=73"
					;;
					3)
						debug_print "set parameter operatingClass=5173"
					;;
				esac
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,39"
				return
			;;
		esac
		shift
	done

	send_complete
}

# DEV_EXEC_ACTION CAPI triggers our AP to do specific actions
dev_exec_action()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@
    
	if [ "$CURRENT_IFACE_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi
	
	while [ "$1" != "" ]; do
        # for upper case only
        upper "$1" token
        shift
        debug_print "while loop $1 - token:$token"
        case "$token" in
            NAME)
                debug_print "set parameter ap_name=$1"
            ;;
            INTERFACE)
                # skip as it is determined in get_interface_details
            ;;
			PROGRAM)
				debug_print "set parameter ap_program=$1"
                upper "$ucc_program" ap_program
            ;;
			KEYROTATION)
                debug_print "set parameter ap_keyrotation=$1"
                ap_keyrotation=$1
			;;
            *)
                error_print "while loop error $1"
                send_invalid ",errorCode,111"
                return
            ;;
        esac
        shift
    done
	if [ "$ap_keyrotation" -eq "1" ]; then
		# Trigger the REKEY_GTK
		hostapd_cli -i $CURRENT_WLAN_NAME.0 raw REKEY_GTK
	fi

	send_complete
}
	
ap_set_rfeature()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	if [ "$CURRENT_RADIO_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	if [ "$CURRENT_IFACE_UCI_PATH" = "" ]; then
		debug_print "Can't obtain uci path"
	fi

	if [ "$CURRENT_WLAN_NAME" = "" ]; then
		debug_print "Can't obtain wlan name"
	fi

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			INTERFACE)
				# skip as it is determined in get_interface_details
			;;
			WLAN_TAG)
				# skip as it is determined in get_interface_details
			;;
			TYPE)
				debug_print "set parameter ap_type=$1"
				ap_type=$1
			;;
			BSS_TRANSITION)
				# do nothing
				debug_print "set parameter ap_bss_transition=$1"
			;;
			NSS_MCS_OPT)
				debug_print "set parameter ap_nss_mcs_opt=$1"
				ap_nss_mcs_opt=$1
			;;
			OPT_MD_NOTIF_IE)
				debug_print "set parameter ap_opt_md_notif_ie=$1"
			;;
			CHNUM_BAND)
				debug_print "set parameter ap_chnum_band=$1"

				ap_chnum_band=$1
				ap_phy=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.phy`
				ap_chan=${ap_chnum_band%%;*}
				ap_band=${ap_chnum_band##*;}

				get_freq_from_chan $ap_phy $ap_chan
				ap_new_freq=$ap_freq
				get_central_freq_vht $ap_chan $ap_band $ap_phy

				if [ "$ap_type" != "EHT" ]; then
					ap_cmd="$HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME chan_switch 5 $ap_new_freq center_freq1=$ap_centr_freq bandwidth=$ap_band auto-ht"
				else #Specific for EHT
					ap_cmd="$HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME chan_switch 10 $ap_new_freq center_freq1=$ap_centr_freq bandwidth=$ap_band blocktx=1 auto-ht"
				fi
				ap_tmp=`eval $ap_cmd`
			;;
			RTS_FORCE)
				debug_print "set parameter ap_rts_force=$1"
				local cur_rts_mode=`uci show wireless | grep sRTSmode | cut -d "=" -f3 | tr -d "'"`
				if [ -n "$cur_rts_mode" ]; then
					iw dev $CURRENT_WLAN_NAME iwlwav sRTSmode $cur_rts_mode
				fi
			;;
			BTM_DISASSOCIMNT)
				debug_print "set parameter ap_btmreq_disassoc_imnt=$1"
			;;
			BTMREQ_DISASSOC_IMNT)
				debug_print "set parameter ap_btmreq_disassoc_imnt=$1"
				BTM_DISASSOC_IMMITIENT=$1
				if [ "$BTM_DISASSOC_IMMITIENT" = 1 ]; then
					[ "$BTM_REASSOC_DELAY" = "" ] && BTM_REASSOC_DELAY=100
					[ "$ucc_program" = "eht" ] && [ "$global_ap_t2lm_negotiation_support" = "" ] && update_neighbor_pref
				fi
			;;
			BTMREQ_LINKREMOVAL_IMNT)
				debug_print "set parameter ap_btmreq_link_removal_imnt=$1"
				BTM_LINK_REMOVAL_IMMINENT=$1
				if [ "$BTM_LINK_REMOVAL_IMMINENT" != 1 ] && [ "$BTM_LINK_REMOVAL_IMMINENT" != 0 ]; then
					error_print "Invalid link removal imminent value $BTM_LINK_REMOVAL_IMMINENT"
					send_error ",errorCode,273"
				fi
			;;
			BTMREQ_TERM_BIT)
				debug_print "set parameter ap_btmreq_term_bit=$1"
				BTM_BSS_TERM_BIT=$1
				[ "$ucc_program" = "eht" ] && update_neighbor_pref
			;;
			BTM_BSSTERM)
				debug_print "set parameter ap_btm_bssterm=$1"
			;;
			BSS_TERM_DURATION)
				debug_print "set parameter ap_btm_bssterm=$1"
				BTM_BSS_TERM_DURATION=$1
			;;
			ASSOC_DISALLOW)
				debug_print "set parameter ap_assoc_disallow=$1"
				lower "$1" ap_enable_input
				if [ "$ap_enable_input" = "enable" ]; then
					ap_enable=1
				else
					ap_enable=0
				fi

				ap_macaddr=`$UCI_CMD get $CURRENT_IFACE_UCI_PATH.macaddr`
				ap_cmd="$HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME mbo_bss_assoc_disallow $ap_macaddr $ap_enable"
				ap_tmp=`eval $ap_cmd`
			;;
			DISASSOC_TIMER)
				debug_print "set parameter ap_disassoc_timer=$1"
				ap_disassoc_timer=$1
			;;
			ASSOC_DELAY)
				debug_print "set parameter ap_assoc_delay=$1"
				BTM_REASSOC_DELAY=$1
			;;
			NEBOR_BSSID)
				debug_print "set parameter ap_neighbor_bssid=$1"
				ap_neighbor_bssid=$1
			;;
			NEBOR_OP_CLASS)
				debug_print "set parameter ap_neighbor_op_class=$1"
				ap_neighbor_op_class=$1
			;;
			NEBOR_OP_CH)
				debug_print "set parameter ap_neighbor_op_ch=$1"
				ap_neighbor_op_ch=$1
			;;
			NEBOR_PREF)
				debug_print "set parameter ap_neighbor_priority=$1"
				ap_neighbor_pref=$1
			;;
			NEBOR_MLD_ADDRESS)
				debug_print "set parameter ap_neighbor_mld_mac=$1"
				ap_neighbor_mld_mac=$1
			;;
			NEBOR_MLD_LINKIDS)
				debug_print "set parameter ap_neighbor_mld_linkid=$1"
				ap_neighbor_mld_linkid=$1
			;;
			BSS_TERM_TSF)
				debug_print "set parameter ap_bssTermTSF=$1"
				BTM_BSS_TERM_TSF=$1
			;;
			PROGRAM)
				debug_print "set parameter ap_program=$1"
				upper "$ucc_program" ap_program
			;;
			DOWNLINKAVAILCAP)
				debug_print "set parameter ap_down_link_avail_cap=$1"
			;;
			UPLINKAVAILCAP)
				debug_print "set parameter ap_up_link_avail_cap=$1"
			;;
			RSSITHRESHOLD)
				debug_print "set parameter ap_rssi_threshold=$1"
			;;
			RETRYDELAY)
				debug_print "set parameter ap_retry_delay=$1"
			;;
			TXPOWER)
				debug_print "set parameter ap_tx_power=$1"
			;;
			TXBANDWIDTH)
				debug_print "set parameter ap_txbandwidth=$1"
				ap_txbandwidth=$1
				glob_ap_txbandwidth=$1
			;;
			LTF)
				debug_print "set parameter ap_ltf=$1"
				ap_ltf=$1
			;;
			EXTRALTFSYMBOLS)
				debug_print "set parameter ap_extraltfsymbols=$1"
				ap_extraltfsymbols=$1
			;;
			GI)
				debug_print "set parameter ap_gi=$1"
				ap_gi=$1
			;;
			RUALLOCTONES)
				debug_print "set parameter ap_rualloctones=$1"
				ap_rualloctones=$1
				glob_ap_rualloctones=$1
			;;
			MRUALLOCTONES)
				debug_print "set parameter ap_mrualloctones=$1"
				ap_mrualloctones=$1
			;;
			ACKPOLICY)
				ap_ack_policy=$1
			;;
			NUMSS)
				debug_print "set parameter ap_num_ss=$1"
				ap_num_ss=$1
			;;
			NUMSS_MAC)
				debug_print "set parameter ap_num_ss_mac=$1"
				ap_num_ss_mac=$1
			;;	
			ACKPOLICY_MAC)
				debug_print "set parameter glob_ap_ack_policy_mac=$1"
				glob_ap_ack_policy_mac=$1
			;;
			TRIGGERTYPE)
				debug_print "set parameter ap_trigger_type=$1"
				ap_trigger_type=$1
			;;
			FORCEEHTTXNSS)
				debug_print "set parameter ap_forced_nss=$1"
				ap_forced_nss=$1
			;;
			TRIGGER_TXBF)
				# do nothing
				debug_print "set parameter ap_trigger_tx_bf=$1"
				iw dev $CURRENT_WLAN_NAME iwlwav sBfMode 0
				# currently this command is passive. Should affect the OFDMA TF BF only.
			;;
			TRIGGERCODING)
				debug_print "set parameter glob_ap_trigger_coding=$1"
				glob_ap_trigger_coding=$1
			;;
			CODINGTYPE)
				debug_print "set parameter ap_coding=$1"
				ap_coding=$1
			;;
			AID)
				debug_print "set parameter ap_sta_aid=$1"
				glob_ap_sta_aid=`echo "$1" | tr -d ' '`
			;;
			TRIG_COMINFO_BW)
				debug_print "set parameter ap_cominfo_bw=$1"
				ap_cominfo_bw=$1
			;;
			TRIG_COMINFO_GI-LTF)
				debug_print "set parameter ap_cominfo_gi_ltf=$1"
				ap_cominfo_gi_ltf=$1
			;;
			TRIG_USRINFO_SSALLOC_RA-RU)
				debug_print "set parameter ap_usrinfo_ss_alloc_ra_ru=$1"
				ap_usrinfo_ss_alloc_ra_ru=`echo "$1" | tr -d ' '`
			;;
			TRIG_USRINFO_RUALLOC)
				debug_print "set parameter glob_ap_usrinfo_ru_alloc=$1"
				glob_ap_usrinfo_ru_alloc=$1
			;;
			TRIG_USRINFO_MRUALLOC)
				debug_print "set parameter ap_mrualloctones=$1"
				ap_mrualloctones=$1
			;;
			ACKTYPE)
				# do nothing
			;;
			TRIGGER_VARIANT)
				debug_print "set parameter ap_trig_variant=$1"
				ap_trig_variant=$1
			;;
			PPDUTXTYPE)
				debug_print "set parameter ap_ppdutxtype=$1"
				ap_ppdutxtype=$1
			;;
			DISABLETRIGGERTYPE)
				debug_print "set parameter ap_disable_trigger_type=$1"
				ap_disable_trigger_type=$1
			;;
			TXOPDURATION)
				# do nothing WLANRTSYS-46439
			;;
			UNSOLICITEDPROBERESP)
				debug_print "set parameter ap_unsolicitedproberesp=$1"
				lower "$1" ap_unsolicitedproberesp
				if [ "$ap_unsolicitedproberesp" = "enable" ]; then
					ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame probe`
				else
					ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame disable`
				fi
				#ap_tmp=`eval $UPDATE_RNR_CLI enable`
			;;
			CADENCE_UNSOLICITEDPROBERESP)
				debug_print "set parameter ap_cadence_unsolicitedproberesp=$1"
				lower "$1" ap_cadence_unsolicitedproberesp
				ap_tmp=`eval $HOSTAPD_CLI_CMD -i $ap_wlan_6g_name set_unsolicited_frame_duration $ap_cadence_unsolicitedproberesp`
			;;
			FILSDSCV)
				debug_print "set parameter ap_fils_dscv=$1"
				lower "$1" ap_fils_dscv
				if [ "$ap_fils_dscv" = "enable" ]; then
					ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame fils`
				else
					ap_tmp=`eval $UPDATE_RNR_UCI unsolicited_frame disable`
				fi
			;;
			TRIG_USRINFO_UL-MCS)
				debug_print "set parameter ap_trig_usrinfo_ul_mcs=$1"
				ap_trig_usrinfo_ul_mcs=$1
			;;
			MPDU_MU_SPACINGFACTOR)
				debug_print "set parameter ap_mpdu_mu_spacingfactor=$1"
				ap_mpdu_mu_spacingfactor=$1
			;;
			TRIG_COMINFO_ULLENGTH)
				debug_print "set parameter ap_trig_cominfo_ullength=$1"
				ap_trig_cominfo_ullength=$1
			;;
			NAV_UPDATE)
				debug_print "set parameter ap_nav_update=$1"
				ap_nav_update=$1
				#Enable SDoSimpleCLI command to disable NAV update in RxC
				if [ "$ap_nav_update" = "disable" ]; then
					ap_tmp=`eval iw $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 4 0`
				else
					ap_tmp=`eval iw $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 4 1`
				fi
			;;
			TRIG_INTERVAL)
				debug_print "set parameter ap_trig_interval=$1"
				ap_trig_interval=$1
			;;
			TRIG_COMINFO_CSREQUIRED)
				# do nothing
				# for test # 5.62.1: in the FW 'commonTfInfoPtr->tfCsRequired' = 1 by default
				if [ "$1" != "1" ]; then
					error_print "Trig_ComInfo_CSRequired = '$1' ; only '1' is supported"
					send_invalid ",errorCode,390"
					return
				fi
			;;
			MBSSIDSET)
				#We did not support this parameter
			;;
			COHOSTEDBSSINDEX)
				debug_print "set parameter ap_cohosted_bss_idx=$1"
				ap_cohosted_bss_idx=$1
			;;
			NONTXBSSINDEX)
				debug_print "set parameter ap_non_tx_bss_idx=$1"
				ap_non_tx_bss_idx=$1
			;;
			STA_WMMPE_ECWMAX*)
				ap_acpref=
				lower "${token#STA_WMMPE_ECWMAX_*}" ap_actype
				ap_acpref=${ap_actype#*cwmax_}
				get_apqos_data_idx $ap_acpref
				local ap_cwmax=$((1<<$1))
				ap_cwmax=$((ap_cwmax-1))
				debug_print "set parameter ap_cwmax=$ap_cwmax"
				if [ "$global_ap_epcs_frame" != "" ]; then
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_IFACE_IFNAME set epcs_wmm_ac_${ap_acpref}_cwmax $1`
				elif [ "$ap_non_tx_bss_idx" = "1" ]; then
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.1 set wmm_ac_${ap_acpref}_cwmax $1`
				else
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.0 set wmm_ac_${ap_acpref}_cwmax $1`
				fi
			;;
			STA_WMMPE_ECWMIN*)
				ap_acpref=
				lower "${token#STA_WMMPE_ECWMIN_*}" ap_actype
				ap_acpref=${ap_actype#*cwmin_}
				get_apqos_data_idx $ap_acpref
				local ap_cwmin=$((1<<$1))
				ap_cwmin=$((ap_cwmin-1))
				debug_print "set parameter ap_cwmin=$ap_cwmin"
				if [ "$global_ap_epcs_frame" != "" ]; then
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_IFACE_IFNAME set epcs_wmm_ac_${ap_acpref}_cwmin $1`
				elif [ "$ap_non_tx_bss_idx" = "1" ]; then
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.1 set wmm_ac_${ap_acpref}_cwmin $1`
				else
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.0 set wmm_ac_${ap_acpref}_cwmin $1`
				fi
			;;
			STA_WMMPE_AIFSN*)
				ap_acpref=
				lower "${token#STA_WMMPE_AIFSN_*}" ap_actype
				ap_acpref=${ap_actype#*aifsn_}
				get_apqos_data_idx $ap_acpref
				debug_print "set parameter ap_aifsn=$1"
				if [ "$global_ap_epcs_frame" != "" ]; then
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_IFACE_IFNAME set epcs_wmm_ac_${ap_acpref}_aifs $1`
				elif [ "$ap_non_tx_bss_idx" = "1" ]; then
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.1 set wmm_ac_${ap_acpref}_aifs $1`
				else
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.0 set wmm_ac_${ap_acpref}_aifs $1`
				fi
			;;
			STA_WMMPE_TXOP*)
				ap_acpref=
				lower "${token#STA_WMMPE_TXOP_*}" ap_actype
				debug_print "set parameter ap_txop=$1"
				ap_acpref=${ap_actype#*txop_}
				if [ "$global_ap_epcs_frame" != "" ]; then
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_IFACE_IFNAME set epcs_wmm_ac_${ap_acpref}_txop_limit $1`
				elif [ "$ap_non_tx_bss_idx" = "1" ]; then
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.1 set wmm_ac_${ap_acpref}_txop_limit $1`
				else
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.0 set wmm_ac_${ap_acpref}_txop_limit $1`
				fi
			;;
			BTWT_ID)
				debug_print "set parameter ap_bwt_id=$1"
				ap_btwt_id=$1
			;;
			TWT_TRIGGER)
				debug_print "set parameter ap_btwt_trigger=$1"
				if [ "$1" = "enable" ]; then
					ap_btwt_trigger=1
				elif [ "$1" = "disable" ]; then
					ap_btwt_trigger=0
				fi
			;;
			SOUNDING)
				debug_print "set parameter ap_sounding=$1"
				lower "$1" ap_sounding
			;;
			FEEDBACKTYPE)
				debug_print "set parameter ap_feedback=$1"
				ap_feedback=$1
			;;
			NG)
				debug_print "set parameter ap_ng=$1"
				ap_ng=$1
			;;
			CODEBOOKSIZE)
				debug_print "set parameter ap_codebook_size=$1"
				ap_codebook_size=$1
			;;
			BANDWIDTHFEEDBACK)
				debug_print "set parameter ap_bw_feedback=$1"
				lower "$1" ap_bw_feedback
			;;
			EHTSOUNDINGNDP_LTF)
				debug_print "set parameter ap_ndp_ltf=$1"
				ap_ndp_ltf=$1
			;;
			EHTSOUNDINGNDP_GI)
				debug_print "set parameter ap_ndp_gi=$1"
				ap_ndp_gi=$1
			;;
			FLOWTYPE)
				debug_print "set parameter ap_btwt_flowtype=$1"
				ap_btwt_flowtype=$1
			;;
			BTWT_RECOMMENDATION)
				debug_print "set parameter ap_btwt_recommendation=$1"
				ap_btwt_recommendation=$1
			;;
			WAKEINTERVALEXP)
				debug_print "set parameter ap_btwt_wakeintervalexp=$1"
				ap_btwt_wakeintervalexp=$1
			;;
			WAKEINTERVALMANTISSA)
				debug_print "set parameter ap_btwt_wakeintervalmantissa=$1"
				ap_btwt_wakeintervalmantissa=$1
			;;
			NOMINALMINWAKEDUR)
				debug_print "set parameter ap_btwt_nominalminwakedur=$1"
				ap_btwt_nominalminwakedur=$1
			;;
			BTWT_PERSISTENCE)
				debug_print "set parameter ap_btwt_persistence=$1"
				ap_btwt_persistence=$1
			;;
			RXMAC)
				debug_print "set parameter ap_rxmac=$1"
				ap_rxmac=$1
			;;
			TEARDOWNALLTWT)
				debug_print "set parameter ap_teardownalltwt=$1"
				ap_teardownalltwt=$1
			;;
			TWTELEMENT)
				debug_print "set parameter ap_twtelement=$1"
				ap_twtelement=$1
			;;
			PREAMBLEPUNCTMODE)
				debug_print "set parameter global_ap_preamblepunctmode=$1"
				lower "$1" global_ap_preamblepunctmode
			;;
			PUNCTCHANNEL)
				if [ "$ap_type" = "EHT" ]; then
					ap_dyn_punct_channel=$1
					nof_channels=`echo "$1" | awk -F" " '{print NF}'`
					debug_print "set parameter ap_dyn_punct_channel=$1 : No Of channels punctured=$nof_channels"
				else
					debug_print "set parameter global_ap_preamblepunctchannel=$1"
					lower "$1" global_ap_preamblepunctchannel
				fi
			;;
			TRANSMITOMI)
				debug_print "set parameter ap_transmit_omi=$1"
				ap_transmit_omi=$1
			;;
			OMCTRL_CHNLWIDTH)
				debug_print "set parameter ap_omctrl_chwidth=$1"
				ap_omctrl_chwidth=$1
			;;
			CLIENT_MAC)
				debug_print "set parameter ap_client_mac=$1"
				if [ "$global_ap_epcs_frame" != "" ]; then
					epcs_sta_mac=$1
					if [ "$global_ap_epcs_frame" = "teardown" ]; then
						$HOSTAPD_CLI_CMD -i $CURRENT_IFACE_IFNAME SEND_EPCS_TEARDOWN_FRAME $CURRENT_IFACE_IFNAME $epcs_sta_mac
					elif [ "$global_ap_epcs_frame" = "request" ]; then
						$HOSTAPD_CLI_CMD -i $CURRENT_IFACE_IFNAME SEND_EPCS_REQ_FRAME $CURRENT_IFACE_IFNAME $epcs_sta_mac dialog_token=10
					fi
				fi
			;;
			OMCTRL_RXNSS)
				debug_print "set parameter ap_omctrl_nss=$1"
				ap_omctrl_nss=$1
			;;
			TRANSMITEHTOMI)
				debug_print "set parameter ap_transmit_eht_omi=$1"
				ap_transmit_eht_omi=$1
			;;
			EHT_OMCTRL_CHNLWIDTH_EXT)
				debug_print "set parameter ap_eht_omctrl_chwidth=$1"
				ap_eht_omctrl_chwidth=$1
			;;
			EHT_OMCTRL_RXNSS_EXT)
				debug_print "set parameter ap_eht_omctrl_nss_ext=$1"
				ap_eht_omctrl_nss_ext=$1
			;;
			EHT_OMCTRL_TXNSTS_EXT)
				debug_print "set parameter ap_eht_omctrl_nsts_ext=$1"
				ap_eht_omctrl_nsts_ext=$1
			;;
			EPCS_SETUP)
				debug_print "set parameter global_ap_epcs_frame=$1"
				lower "$1" global_ap_epcs_frame
				if [ "$global_ap_epcs_frame" != "teardown" ] && [ "$global_ap_epcs_frame" != "request" ] && [ "$global_ap_epcs_frame" != "authorize" ]; then
					error_print "Unsupported value - global_ap_epcs_frame:$global_ap_epcs_frame"
					send_error ",errorCode,198"
					return
				fi
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,40"
				return
			;;
		esac
		shift
	done

	if [ "$ucc_program" = "mbo" -o "$ucc_program" = "he" -o "$ucc_program" = "eht" ]
	then
		if [ "${ap_neighbor_mld_mac}" = "" ]; then
			config_neighbor
		fi

		if [ "${ap_neighbor_bssid}" != "" ] && [ "${ap_neighbor_op_class}" != "" ] && [ "${ap_neighbor_op_ch}" != "" ] && [ "${ap_neighbor_pref}" != "" ]
		then
			local old_IFS=$IFS
			IFS=""
			CURRENT_NEIGHBORS=`cat /tmp/mbo_neighbors`
			neighbor_index=1
			# Two or more neighbor info of same AP is given in single command separated with semicolon.
			# Replacing ; with - as semicolon is treated as termination.
			ap_neighbor_bssid=${ap_neighbor_bssid//;/-}
			ap_neighbor_op_class=${ap_neighbor_op_class//;/-}
			ap_neighbor_op_ch=${ap_neighbor_op_ch//;/-}
			btm_other_channel=`eval echo "${ap_neighbor_op_ch}" | awk -F"-" '{print $2}'`
			new_neighbor_count=`eval echo "${ap_neighbor_bssid}" | awk -F"-" '{print NF}'`
			while [ $neighbor_index -le $new_neighbor_count ]
			do
				ap_new_neighbor_bssid=`eval echo "${ap_neighbor_bssid}" | awk -F"-" '{print $'$neighbor_index'}'`
				ap_new_neighbor_op_class=`eval echo "${ap_neighbor_op_class}" | awk -F"-" '{print $'$neighbor_index'}'`
				ap_new_neighbor_op_ch=`eval echo "${ap_neighbor_op_ch}" | awk -F"-" '{print $'$neighbor_index'}'`
				already_present=`grep "${ap_new_neighbor_bssid}" "/tmp/mbo_neighbors"`
				if [ "$already_present" != "" ]; then
					neighbor_index=$((neighbor_index + 1))
					continue
				fi
				if [ "${ap_neighbor_mld_mac}" != "" ]; then
					ap_neighbor_mld_linkid=${ap_neighbor_mld_linkid//;/-}
					ap_new_neighbor_mld_linkid=`eval echo "${ap_neighbor_mld_linkid}" | awk -F"-" '{print $'$neighbor_index'}'`
					if [ "${ap_new_neighbor_mld_linkid}" != "" ]; then
						CURRENT_NEIGHBORS="neighbor=${ap_new_neighbor_bssid},0,${ap_new_neighbor_op_class},${ap_new_neighbor_op_ch},9,${ap_neighbor_pref},${ap_neighbor_mld_mac},${ap_new_neighbor_mld_linkid} $CURRENT_NEIGHBORS"
					else
						CURRENT_NEIGHBORS="neighbor=${ap_new_neighbor_bssid},0,${ap_new_neighbor_op_class},${ap_new_neighbor_op_ch},9,${ap_neighbor_pref},${ap_neighbor_mld_mac} $CURRENT_NEIGHBORS"
					fi
				else
					CURRENT_NEIGHBORS="neighbor=${ap_new_neighbor_bssid},0,${ap_new_neighbor_op_class},${ap_new_neighbor_op_ch},9,${ap_neighbor_pref} $CURRENT_NEIGHBORS"
				fi
				neighbor_index=$((neighbor_index + 1))
			done
			echo $CURRENT_NEIGHBORS > /tmp/mbo_neighbors
			IFS=$old_IFS
		fi
	fi

	if [ "$global_ap_btwt" = "1" ]; then
		if [ "$ap_btwt_id" != "" ]; then
			debug_print "Advertise BTWT schedule id:$ap_btwt_id flowtype:$ap_btwt_flowtype trigger:$ap_btwt_trigger wakedur:$ap_btwt_nominalminwakedur wakeintmant:$ap_btwt_wakeintervalmantissa wakeintexp: $ap_btwt_wakeintervalexp"
			ap_tmp=`eval iw dev $CURRENT_WLAN_NAME.0 iwlwav sAdvertiseBcTwtSp 1 0 $ap_btwt_id $ap_btwt_flowtype $ap_btwt_trigger $ap_btwt_nominalminwakedur $ap_btwt_wakeintervalmantissa $ap_btwt_wakeintervalexp`
		fi
		if [ "$ucc_type" = "dut" ]; then
			info_print "Disabling TXOP for BTWT with 2-users"
			ap_tmp=`iw dev $CURRENT_WLAN_NAME iwlwav sTxopConfig 0x1FF 0 32767 4`
			ap_band=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.band`
			if [ "$ap_band" = "5GHz" ] || [ "$ap_band" = "6GHz" ]; then
				info_print "Use 1.5ms TXOP duration for BTWT with 2-users in 5GHz/6GHz for more efficient SP usage in DL"
				ap_tmp=`iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 96 1090 3`
			else
				info_print "Use 2ms TXOP duration for BTWT with 2-users in 2.4GHz for more efficient SP usage in DL"
				ap_tmp=`iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 96 1486 3`
			fi
		fi
	fi

	if [ "$ap_teardownalltwt" = "1" ]; then
		if [ "$ap_rxmac" != "" ]; then
			debug_print "Teardown all TWT schedules for station:$ap_rxmac"
			ap_sid=`cat /proc/net/mtlk/$CURRENT_WLAN_NAME.0/sta_list | grep "0" | grep -iF "$ap_rxmac" | awk '{print $3}'`
			if [ "$ap_sid" = "" ]; then
				error_print ""MAC not found: ap_rxmac:$ap_rxmac""
				send_error ",errorCode,204"
				return
			fi
			ap_tmp=`eval iw dev $CURRENT_WLAN_NAME.0 iwlwav sTxTwtTeardown $ap_sid 1`
		fi
	fi

	if [ "$ap_type" == "EHT" ]; then
		if [ "$ap_extraltfsymbols" == "1" ]; then
			ap_tmp=`eval iw dev $CURRENT_WLAN_NAME iwlwav sFixedLtfGi 0 2`
		elif [ "$ap_extraltfsymbols" == "2" ]; then
			ap_tmp=`eval iw dev $CURRENT_WLAN_NAME iwlwav sFixedLtfGi 0 4`
		fi
	fi

	if [ "$ap_twtelement" = "exclude" ]; then
		debug_print "Exclude BTWT schedules from the beacon"
		ap_tmp=`eval iw dev $CURRENT_WLAN_NAME.0 iwlwav sTerminateBcTwtSp 1`
		# turn static plan off
		info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
		send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
	fi

	if [ "$ap_nss_mcs_opt" != "" ]; then
		debug_print "ap_nss_mcs_opt:$ap_nss_mcs_opt"
		ap_nss_opt=${ap_nss_mcs_opt%%;*}
		ap_mcs_opt=${ap_nss_mcs_opt##*;}
		ap_mcs_opt_eht=$ap_mcs_opt
		debug_print "NSS Value : $ap_nss_opt"
		debug_print "MCS Value : $ap_mcs_opt"
		
		if [ "$ap_nss_opt" = "def" ]; then
			# change the NSS to the default value
			ap_nss_opt="$nss_def_val_dl"
			[ "$glob_ofdma_phase_format" = "1" ] && ap_nss_opt="$nss_def_val_ul"
			if [ "$ucc_type" = "testbed" ]; then
				ap_nss_opt="$nss_def_val_dl_testbed"
				[ "$glob_ofdma_phase_format" = "1" ] && ap_nss_opt="$nss_def_val_ul_testbed"
			fi
		fi

		if [ "$ap_mcs_opt" = "def" ]; then
			# change the MCS to the default value
			ap_mcs_opt="$mcs_def_val_dl"
			[ "$glob_ofdma_phase_format" = "1" ] && ap_mcs_opt="$mcs_def_val_ul"
			if [ "$ucc_type" = "testbed" ]; then
				ap_mcs_opt="$mcs_def_val_dl_testbed"
				[ "$glob_ofdma_phase_format" = "1" ] && ap_mcs_opt="$mcs_def_val_ul_testbed"
				if [ -n $glob_ap_forced_mcs ]; then
					ap_mcs_opt="$glob_ap_forced_mcs"
				fi
			fi
		fi

		# TODO: Handle for SU, when MU is not set

		# JIRA WLANRTSYS-9813: check whether the previously set value of nss is lower than the current one; if so, set the one we just got (the higher one)
		if [ -n "$ap_nss_opt" ] && [ -n "$global_nss_opt_ul" ] && [ -n "$global_nss_opt_dl" ]; then
			if [ $ap_nss_opt -gt $global_nss_opt_ul ] || [ $ap_nss_opt -gt $global_nss_opt_dl ]; then
				local nss_mcs_val=`get_nss_mcs_val $ap_nss_opt $ap_mcs_opt`

				if [ $ap_nss_opt -gt $global_nss_opt_ul ]; then
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_rx_he_mcs_map_less_than_or_equal_80_mhz=${nss_mcs_val}"
					# JIRA WLANRTSYS-11028: part0-Rx part1-Tx
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'vht_mcs_set_part0' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part0=${nss_mcs_val}"
					global_nss_opt_ul=${ap_nss_opt}
				fi

				if [ $ap_nss_opt -gt $global_nss_opt_dl ]; then
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="he_mcs_nss_tx_he_mcs_map_less_than_or_equal_80_mhz=${nss_mcs_val}"
					# JIRA WLANRTSYS-11028: part0-Rx part1-Tx
					ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'vht_mcs_set_part1' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
					$UCI_CMD set $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="vht_mcs_set_part1=${nss_mcs_val}"
					global_nss_opt_dl=${ap_nss_opt}
				fi
			fi

		elif [ -n "$ap_nss_opt" ]; then
			iw dev $CURRENT_WLAN_NAME iwlwav sFixedRateCfg 1023 0 $bw_converted 8 $ap_nss_opt $ap_mcs_opt 2 0 0 0 2
		fi

		# set for MU
		for usr_index in 1 2 3 4
		do
			# get MU DL MCS value
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'${usr_index} $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			current_ap_mcs=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x1`
			let current_ap_mcs="$current_ap_mcs%16"

			# calculate the OFDMA MU NSS-MCS value (NSS: bits 5-4, MCS: bits 3-0)
			if [ "$ap_type" = "EHT" -a "$ap_mcs_opt_eht" = "def" ]; then
				let ap_ofdma_mu_nss_mcs_val="($ap_nss_opt-1)*16+$current_ap_mcs"
			else
				let ap_ofdma_mu_nss_mcs_val="($ap_nss_opt-1)*16+$ap_mcs_opt"
			fi

			# set MU DL NSS MCS value
			if [ "$glob_ofdma_phase_format" = "0" ]; then
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x1=${ap_ofdma_mu_nss_mcs_val}
			elif [ "$glob_ofdma_phase_format" = "1" ]; then
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x3=${ap_ofdma_mu_nss_mcs_val}
			fi
		done

		if [ "$ap_type" != "EHT" ]; then
			ap_uci_commit_and_apply
			sleep 20
			if [ "$OS_NAME" = "UGW" ]; then
				check_and_update_dc_registration
			fi
		fi
	fi

		# for test HE-4.43.1
	if [ "$ap_disable_trigger_type" != "" ] && [ "$ap_disable_trigger_type" = "0" ]; then
		# turn static plan off
		info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
		send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
	fi

	# WLANRTSYS-11513 TC 5.61.1
	if [ "$ap_ppdutxtype" != "" ]; then
		if [ "$ap_ppdutxtype" = "HE-SU" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=0
			[ "$ap_type" != "EHT" ] && refresh_static_plan
		elif [ "$ap_ppdutxtype" = "legacy" ]; then
			if [ "$ap_trig_variant" = "EHT" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
				Dynamic_set_get_helper iw_off $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
				[ "$ML_VAP1" = "5G" ] && Dynamic_set_get_helper iw_off $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
				[ "$ML_VAP1" = "24G" ] && Dynamic_set_get_helper iw_off $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
				[ "$ML_VAP1" = "24G" ] && [ "$ML_VAP2" = "6G" ] && Dynamic_set_get_helper iw_off $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
			else
				[ "$ap_type" = "EHT" ] && iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 1 #Specific to send data using HE PPDU in EHT program(Like in TC EHT-4.11.2 )
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
				[ "$ap_type" != "EHT" ] && refresh_static_plan
			fi
		else
			error_print "!!! PPDUTXTYPE wrong value !!!"
		fi
	fi

	if [ "$ap_txbandwidth" != "" ]; then
		debug_print "ap_txbandwidth:$ap_txbandwidth"
		convert_Operation_ChWidth ${ap_txbandwidth}MHz
		current_ht_mode=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.htmode`
		[ "$current_ht_mode" = "VHT40+" -o "$current_ht_mode" = "VHT40-" ] && current_ht_mode="VHT40"

		# set for SU, only if not OFDMA MU TC
		if [ "$glob_ofdma_phase_format" = "" ]; then
			debug_print "if [ \"$glob_ofdma_phase_format\" = \"\" ]; then"
			# JIRA WLANRTSYS-9189: remove the call to 'is_test_case_permitted_to_set_channel' - always set the channel
			if [ "$current_ht_mode" != "VHT${ap_txbandwidth}" ]; then
				debug_print "vht_oper_chwidth_converted= $vht_oper_chwidth_converted"
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode=VHT${ap_txbandwidth}
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.vht_oper_chwidth=$vht_oper_chwidth_converted
				convert_fixed_rate ${ap_txbandwidth}MHz "ax"
				Dynamic_set_get_helper_none_debug $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.sFixedRateCfg sFixedRateCfg x1=0 x2=${bw_converted} x3=$phym_converted x6=5 #band_width
				ap_uci_commit_and_apply # commit and apply 
				sleep 20
			fi	
		else
			# JIRA WLANRTSYS-9189: remove the call to 'is_test_case_permitted_to_set_channel' - always set the channel
			if [ "$current_ht_mode" != "VHT${ap_txbandwidth}" ]; then
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.htmode=VHT${ap_txbandwidth}
				$UCI_CMD set $CURRENT_RADIO_UCI_PATH.vht_oper_chwidth=$vht_oper_chwidth_converted
				ap_uci_commit_and_apply
			fi
		fi
	
		# set for MU
		[ "$ap_txbandwidth" = "20" ] && ap_txbandwidth=0
		[ "$ap_txbandwidth" = "40" ] && ap_txbandwidth=1
		[ "$ap_txbandwidth" = "80" ] && ap_txbandwidth=2
		[ "$ap_txbandwidth" = "160" ] && ap_txbandwidth=3
		[ "$ap_txbandwidth" = "320" ] && ap_txbandwidth=4
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		info_print "Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${txop_com_start_bw_limit_idx}=${ap_txbandwidth}"
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${txop_com_start_bw_limit_idx}=${ap_txbandwidth}
		ap_num_participating_users=`iw dev $CURRENT_WLAN_NAME.0 station dump | grep -c Station` 
		info_print "ap_num_participating_users=$ap_num_participating_users"

		local dl_sub_band1 dl_start_ru1 dl_ru_size1
		local dl_sub_band2 dl_start_ru2 dl_ru_size2
		local dl_sub_band3 dl_start_ru3 dl_ru_size3
		local dl_sub_band4 dl_start_ru4 dl_ru_size4

		# update 4 user plan according to BW - W/A to be align to WFA UCC.
		# 0-20MHz, 1-40MHz, 2-80MHz, 3-160MHz
		case "$ap_txbandwidth" in
			"0")
				if [ $ap_num_participating_users -gt 2 ]; then
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=1
					#USER2
					dl_sub_band2=0;dl_start_ru2=2;dl_ru_size2=1
					#USER3
					dl_sub_band3=0;dl_start_ru3=5;dl_ru_size3=1
					#USER4
					dl_sub_band4=0;dl_start_ru4=7;dl_ru_size4=1
				else
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2
					#USER2
					dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=2
				fi
			;;
			"1")
				if [ $ap_num_participating_users -gt 2 ]; then
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2
					#USER2
					dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=2
					#USER3
					dl_sub_band3=1;dl_start_ru3=0;dl_ru_size3=2
					#USER4
					dl_sub_band4=1;dl_start_ru4=5;dl_ru_size4=2
				else
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3
					#USER2
					dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=3
				fi
			;;
			"2")
				if [ $ap_num_participating_users -gt 2 ]; then
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3
					#USER2
					dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=3
					#USER3
					dl_sub_band3=2;dl_start_ru3=0;dl_ru_size3=3
					#USER4
					dl_sub_band4=3;dl_start_ru4=0;dl_ru_size4=3
				else
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4;
					#USER2
					dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=4;
				fi
			;;
			"3")
				if [ $ap_num_participating_users -gt 2 ]; then
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4
					#USER2
					dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=4
					#USER3
					dl_sub_band3=4;dl_start_ru3=0;dl_ru_size3=4
					#USER4
					dl_sub_band4=6;dl_start_ru4=0;dl_ru_size4=4
				else
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5
					#USER2
					dl_sub_band2=4;dl_start_ru2=0;dl_ru_size2=5
				fi
			;;
		esac
		
		## WLANRTSYS-12035
		if [ $dl_ru_size1 -lt 2 ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2300
		else
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
		fi

	
		# update per-user params in DB
		for usr_index in 1 2 3 4
		do
			local tmp_param tmp_val
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			tmp_param="dl_sub_band$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x${dl_usr_sub_band_per_usp_idx}=${tmp_val}
	
			tmp_param="dl_start_ru$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x${dl_usr_start_ru_per_usp_idx}=${tmp_val}
			tmp_param="dl_ru_size$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x${dl_usr_ru_size_per_usp_idx}=${tmp_val}
		done

		if [ "$glob_ofdma_phase_format" != "" ]; then
			[ "$ap_type" != "EHT" ] && refresh_static_plan
		fi
	fi

	if [ "$ap_mrualloctones" != "" ]; then
		debug_print "ap_mrualloctones : $ap_mrualloctones"
		# replace all ':' with " "
		tmp_ap_mrualloctones=${ap_mrualloctones//:/ }

		MRU_ALLOC_CONF_FILE="/tmp/mru_conf"
		[ -e "$MRU_ALLOC_CONF_FILE" ] && rm -f $MRU_ALLOC_CONF_FILE
		echo $tmp_ap_mrualloctones | tr ' ' '\n' >> $MRU_ALLOC_CONF_FILE

		if [ "$ap_txbandwidth" != "" ]; then
			info_print "ap_txbandwidth :$ap_txbandwidth"
			# if exist, get the bw from previous parameter in this command
			start_bw_limit=$ap_txbandwidth
		else
			# else, get the bw from the SP
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			start_bw_limit=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx` #x3
		fi

		nof_users=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`
# MRU alloc conf file is sorted in the descending order => first user gets the MRU allocation, the rest would be the RU allocation
# Please note that the MRU pattern (ul_mru/dl_mru) are sorted in the right order of users starting from user #1
		usr_index=1
		#Note : Handles only MRU allocations used in Wi-Fi 7 certifcation. May fail for other possible valid combinations
		#Note : There needs to be atleast one MRU (Small/Large) configuration
		#May fail when more than 1 user is asssigned MRUs (not expected via this CAPI param)
		while [ "$usr_index" -le "$nof_users" ]; do
			eval mru_alloc=`sed -n ''${usr_index}'p' $MRU_ALLOC_CONF_FILE`

			case "$start_bw_limit" in
				"0") #20MHz - only small MRU - 2 user case only
					case "$usr_index" in
						"1") #user 1
							if [ "$mru_alloc" = "52+26" ]; then
								ul_sub_band1=0; ul_start_ru1=1; ul_ru_size1=8; ul_mru_size1=0; dl_sub_band1=0; dl_start_ru1=1; dl_ru_size1=8; dl_mru_size1=0
							elif [ "$mru_alloc" = "106+26" ]; then
								ul_sub_band1=0; ul_start_ru1=0; ul_ru_size1=9; ul_mru_size1=0; dl_sub_band1=0; dl_start_ru1=0; dl_ru_size1=9; dl_mru_size1=0
							else
								errCode=901
							fi
						;;
						"2") #user 2
							if [ "$mru_alloc" = "106" ]; then
								ul_sub_band2=0; ul_start_ru2=5; ul_ru_size2=2; ul_mru_size2=0; dl_sub_band2=0; dl_start_ru2=5; dl_ru_size2=2; dl_mru_size2=0
							elif [ "$mru_alloc" = "52" ]; then
								ul_sub_band2=0; ul_start_ru2=5; ul_ru_size2=1; ul_mru_size2=0; dl_sub_band2=0; dl_start_ru2=5; dl_ru_size2=1; dl_mru_size2=0
							elif [ "$mru_alloc" = "" ]; then
								ul_sub_band2=0; ul_start_ru2=5; ul_ru_size2=1; ul_mru_size2=0; dl_sub_band2=0; dl_start_ru2=5; dl_ru_size2=1; dl_mru_size2=0
							else
								errCode=902
							fi
						;;
						*)
							errCode=900
						;;
					esac
				;; #end of 20MHz case
				"1") #40MHz  - only small MRU
					if [ "$nof_users" != "4" ]; then #trigger a forced error
						usr_index=5
					fi
					case "$usr_index" in
						"1") #user 1
							if [ "$mru_alloc" = "52+26" ]; then
								ul_sub_band1=0; ul_start_ru1=1; ul_ru_size1=8; ul_mru_size1=0; dl_sub_band1=0; dl_start_ru1=1; dl_ru_size1=8; dl_mru_size1=0
							elif [ "$mru_alloc" = "106+26" ]; then
								ul_sub_band1=0; ul_start_ru1=0; ul_ru_size1=9; ul_mru_size1=0; dl_sub_band1=0; dl_start_ru1=0; dl_ru_size1=9; dl_mru_size1=0
							else
								errCode=911
							fi
						;;
						"2") #user 2
							if [ "$mru_alloc" = "52" ] || [ "$mru_alloc" = "" ] ; then
								ul_sub_band2=0; ul_start_ru2=5; ul_ru_size2=1; ul_mru_size2=0; dl_sub_band2=0; dl_start_ru2=5; dl_ru_size2=1; dl_mru_size2=0
							else
								errCode=912
							fi
						;;
						"3") #user 3
							if [ "$mru_alloc" = "52" ]; then
								ul_sub_band3=1; ul_start_ru3=0; ul_ru_size3=1; ul_mru_size3=0; dl_sub_band3=1; dl_start_ru3=0; dl_ru_size3=1; dl_mru_size3=0
							elif [ "$mru_alloc" = "" ]; then #106+26 for APUT test in order to achieve the required throughput
								ul_sub_band3=1; ul_start_ru3=0; ul_ru_size3=9; ul_mru_size3=0; dl_sub_band3=1; dl_start_ru3=0; dl_ru_size3=9; dl_mru_size3=0
							else
								errCode=913
							fi
						;;
						"4") #user 4
							if [ "$mru_alloc" = "52" ] || [ "$mru_alloc" = "" ] ; then
								ul_sub_band4=1; ul_start_ru4=5; ul_ru_size4=1; ul_mru_size4=0; dl_sub_band4=1; dl_start_ru4=5; dl_ru_size4=1; dl_mru_size4=0
							else
								errCode=914
							fi
						;;
						*)
							errCode=910
						;;
					esac
				;; #end of 40MHz case
				"2") #80MHz - Small MRU(4 user only) and Large MRU(2 user only) cases
					case "$usr_index" in
						"1") #user 1
							if [ "$mru_alloc" = "106+26" ]; then
								if [ "$nof_users" != "4" ]; then
									errCode=921
								else
									ul_sub_band1=0; ul_start_ru1=0; ul_ru_size1=9; ul_mru_size1=0; dl_sub_band1=0; dl_start_ru1=0; dl_ru_size1=9; dl_mru_size1=0
								fi
							elif [ "$mru_alloc" = "484+242" ]; then
								if [ "$nof_users" != "2" ]; then
									errCode=921
								else
									ul_sub_band1=0; ul_start_ru1=0; ul_ru_size1=10; ul_mru_size1=3; dl_sub_band1=0; dl_start_ru1=0; dl_ru_size1=10; dl_mru_size1=3
								fi
							else
								errCode=921
							fi
						;;
						"2") #user 2
							if [ "$mru_alloc" = "" ] || [ "$mru_alloc" = "242" ]; then
								if [ "$nof_users" = "2" ] ; then
									ul_sub_band2=3; ul_start_ru2=0; ul_ru_size2=3; ul_mru_size2=0; dl_sub_band2=3; dl_start_ru2=0; dl_ru_size2=3; dl_mru_size2=0
								elif [ "$nof_users" = "4" ]; then
									ul_sub_band2=1; ul_start_ru2=0; ul_ru_size2=3; ul_mru_size2=0; dl_sub_band2=1; dl_start_ru2=0; dl_ru_size2=3; dl_mru_size2=0
								else
									errCode=920
								fi
							else
								errCode=922
							fi
						;;
						"3") #user 3
							if [ "$mru_alloc" = "" ] || [ "$mru_alloc" = "242" ]; then
								ul_sub_band3=2; ul_start_ru3=0; ul_ru_size3=3; ul_mru_size3=0; dl_sub_band3=2; dl_start_ru3=0; dl_ru_size3=3; dl_mru_size3=0
							else
								errCode=923
							fi
						;;
						"4") #user 4
							if [ "$mru_alloc" = "" ] || [ "$mru_alloc" = "242" ]; then
								ul_sub_band4=3; ul_start_ru4=0; ul_ru_size4=3; ul_mru_size4=0; dl_sub_band4=3; dl_start_ru4=0; dl_ru_size4=3; dl_mru_size4=0
							else
								errCode=924
							fi
						;;
						*)
							errCode=920
						;;
					esac
				;; #end of 80MHz case
				"3") #160MHz - only Large MRU (2 user) case
					case "$usr_index" in
						"1") #user 1
							if [ "$mru_alloc" = "996+484" ]; then
								ul_sub_band1=0; ul_start_ru1=0; ul_ru_size1=11; ul_mru_size1=6; dl_sub_band1=0; dl_start_ru1=0; dl_ru_size1=11; dl_mru_size1=6
							else
								errCode=931
							fi
						;;
						"2") #user 2
							if [ "$mru_alloc" = "" ] || [ "$mru_alloc" = "484" ]; then
								ul_sub_band2=6; ul_start_ru2=0; ul_ru_size2=4; ul_mru_size2=0; dl_sub_band2=6; dl_start_ru2=0; dl_ru_size2=4; dl_mru_size2=0
							else
								errCode=932
							fi
						;;
						*)
							errCode=930
						;;
					esac
				;; #end of 160MHz case
				*)
					errCode=900
				;; #end of default case
			esac #end of start_bw_limit case

			if [ "$errCode" != "" ]; then
				error_print "Wrong MRU configuration received!"
				send_invalid ",errorCode, $errCode"
				return
			fi
			usr_index=$((usr_index+1))
		done
	fi

	if [ "$ap_rualloctones" != "" ]; then
		debug_print "ap_rualloctones:$ap_rualloctones"

		# replace all ':' with " "
		tmp_ap_rualloctones=${ap_rualloctones//:/ }
		ap_rualloctones=${tmp_ap_rualloctones%% *}
		# ap_rualloctones implicitly holds the number of users.

		local user_index user_list index user_value start_bw_limit
		local dl_sub_band1 dl_start_ru1 dl_ru_size1
		local dl_sub_band2 dl_start_ru2 dl_ru_size2
		local dl_sub_band3 dl_start_ru3 dl_ru_size3
		local dl_sub_band4 dl_start_ru4 dl_ru_size4

		if [ "$ap_txbandwidth" != "" ]; then
			info_print "ap_txbandwidth :$ap_txbandwidth"
			# if exist, get the bw from previous parameter in this command
			start_bw_limit=$ap_txbandwidth
		else
			# else, get the bw from the SP
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			start_bw_limit=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx` #x3
		fi

		user_index=0
		for user_value in $tmp_ap_rualloctones
		do
			let user_index=$user_index+1

			### BW=320MHz ###
			if [ "$start_bw_limit" = "4" ]; then
				if [ "$user_value" = "996" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5
						;;
						"2") #USER2
							dl_sub_band2=4;dl_start_ru2=0;dl_ru_size2=5
						;;
						"3") #USER3
							dl_sub_band3=8;dl_start_ru3=0;dl_ru_size3=5
						;;
						"4") #USER4
							dl_sub_band4=12;dl_start_ru4=0;dl_ru_size4=5
						;;
					esac
				elif [ "$user_value" = "1992" ] || [ "$user_value" = "2x996" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=6
						;;
						"2") #USER2
							dl_sub_band2=8;ud_start_ru2=0;dl_ru_size2=6
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,605"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,610"
							return
						;;
					esac
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,670"
					return
				fi

			### BW=160MHz ###
			elif [ "$start_bw_limit" = "3" ]; then
				if [ "$user_value" = "106" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2
						;;
						"2") #USER2
							dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=2
						;;
						"3") #USER3
							dl_sub_band3=4;dl_start_ru3=0;dl_ru_size3=2
						;;
						"4") #USER4
							dl_sub_band4=6;dl_start_ru4=0;dl_ru_size4=2
						;;
					esac
				elif [ "$user_value" = "242" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3
						;;
						"2") #USER2
							dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=3
						;;
						"3") #USER3
							dl_sub_band3=4;dl_start_ru3=0;dl_ru_size3=3
						;;
						"4") #USER4
							dl_sub_band4=6;dl_start_ru4=0;dl_ru_size4=3
						;;
					esac
				elif [ "$user_value" = "484" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4
						;;
						"2") #USER2
							dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=4
						;;
						"3") #USER3
							dl_sub_band3=4;dl_start_ru3=0;dl_ru_size3=4
						;;
						"4") #USER4
							dl_sub_band4=6;dl_start_ru4=0;dl_ru_size4=4
						;;
					esac
				elif [ "$user_value" = "996" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5
						;;
						"2") #USER2
							dl_sub_band2=4;dl_start_ru2=0;dl_ru_size2=5
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,640"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,645"
							return
						;;
					esac
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,650"
					return
				fi

			### BW=80MHz ###
			elif [ "$start_bw_limit" = "2" ]; then
				if [ "$user_value" = "26" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=0
						;;
						"2") #USER2
							dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=0
						;;
						"3") #USER3
							dl_sub_band3=2;dl_start_ru3=0;dl_ru_size3=0
						;;
						"4") #USER4
							dl_sub_band4=3;dl_start_ru4=0;dl_ru_size4=0
						;;
					esac
				elif [ "$user_value" = "52" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=1
						;;
						"2") #USER2
							dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=1
						;;
						"3") #USER3
							dl_sub_band3=2;dl_start_ru3=0;dl_ru_size3=1
						;;
						"4") #USER4
							dl_sub_band4=3;dl_start_ru4=0;dl_ru_size4=1
						;;
					esac
				elif [ "$user_value" = "106" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2
						;;
						"2") #USER2
							dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=2
						;;
						"3") #USER3
							dl_sub_band3=2;dl_start_ru3=0;dl_ru_size3=2
						;;
						"4") #USER4
							dl_sub_band4=3;dl_start_ru4=0;dl_ru_size4=2
						;;
					esac
				elif [ "$user_value" = "242" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3
						;;
						"2") #USER2
							dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=3
						;;
						"3") #USER3
							dl_sub_band3=2;dl_start_ru3=0;dl_ru_size3=3
						;;
						"4") #USER4
							dl_sub_band4=3;dl_start_ru4=0;dl_ru_size4=3
						;;
					esac
				elif [ "$user_value" = "484" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4
						;;
						"2") #USER2
							dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=4
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,440"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,441"
							return
						;;
					esac
				elif [ "$user_value" = "996" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5
						;;
						"2") #USER2
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,442"
							return
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,443"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,444"
							return
						;;
					esac
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,445"
					return
				fi

			### BW=40MHz ###
			elif [ "$start_bw_limit" = "1" ]; then
				if [ "$user_value" = "26" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=0
						;;
						"2") #USER2
							dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=0
						;;
						"3") #USER3
							dl_sub_band3=1;dl_start_ru3=0;dl_ru_size3=0
						;;
						"4") #USER4
							dl_sub_band4=1;dl_start_ru4=5;dl_ru_size4=0
						;;
					esac
				elif [ "$user_value" = "52" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=1
						;;
						"2") #USER2
							dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=1
						;;
						"3") #USER3
							dl_sub_band3=1;dl_start_ru3=0;dl_ru_size3=1
						;;
						"4") #USER4
							dl_sub_band4=1;dl_start_ru4=5;dl_ru_size4=1
						;;
					esac
				elif [ "$user_value" = "106" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2
						;;
						"2") #USER2
							dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=2
						;;
						"3") #USER3
							dl_sub_band3=1;dl_start_ru3=0;dl_ru_size3=2
						;;
						"4") #USER4
							dl_sub_band4=1;dl_start_ru4=5;dl_ru_size4=2
						;;
					esac
				elif [ "$user_value" = "242" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3
						;;
						"2") #USER2
							dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=3
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,446"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,447"
							return
						;;
					esac
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,448"
					return
				fi

			### BW=20MHz ###
			elif [ "$start_bw_limit" = "0" ]; then
				if [ "$user_value" = "26" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=0
						;;
						"2") #USER2
							dl_sub_band2=0;dl_start_ru2=2;dl_ru_size2=0
						;;
						"3") #USER3
							dl_sub_band3=0;dl_start_ru3=5;dl_ru_size3=0
						;;
						"4") #USER4
							dl_sub_band4=0;dl_start_ru4=7;dl_ru_size4=0
						;;
					esac
				elif [ "$user_value" = "52" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=1
						;;
						"2") #USER2
							dl_sub_band2=0;dl_start_ru2=2;dl_ru_size2=1
						;;
						"3") #USER3
							dl_sub_band3=0;dl_start_ru3=5;dl_ru_size3=1
						;;
						"4") #USER4
							dl_sub_band4=0;dl_start_ru4=7;dl_ru_size4=1
						;;
					esac
				elif [ "$user_value" = "106" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2
						;;
						"2") #USER2
							dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=2
						;;
						"3") #USER3
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,450"
							return
						;;
						"4") #USER4
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,451"
							return
						;;
					esac
				elif [ "$user_value" = "242" ]; then
					case "$user_index" in
						"1") #USER1
							dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3
						;;
						"2") #USER2
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,452"
							return
						;;
						"3") #USER3
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,453"
							return
						;;
						"4") #USER4
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,454"
							return
						;;
					esac
				elif [ "$user_value" = "484" ]; then
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,455"
					return
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,456"
					return
				fi
			else
				error_print "Unsupported value - start_bw_limit:$start_bw_limit"
				send_invalid ",errorCode,457"
				return
			fi
		done

		# user_index contains the number of users. set it to DB to be used by static plan.
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_num_of_participating_stations_idx}=${user_index}
	
		## WLANRTSYS-12035
		if [ $dl_ru_size1 -lt 2 ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2300
		else
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
		fi
	
	
		# update per-user params in DB, per number of users
		#for index in $user_index
		for index in 1 2 3 4 
		do
			local tmp_param tmp_val
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			
			tmp_param="dl_sub_band${index}";eval tmp_val=\$$tmp_param		
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${dl_usr_sub_band_per_usp_idx}=${tmp_val}
			
			tmp_param="dl_start_ru${index}";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${dl_usr_start_ru_per_usp_idx}=${tmp_val}
			
			tmp_param="dl_ru_size${index}";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${dl_usr_ru_size_per_usp_idx}=${tmp_val}
		done

		# dynamically update STA index in DB
		ap_aid_list=`cat /proc/net/mtlk/$ap_wlan_name/sta_list | awk '{print $5}' | tr  "\n" ","`
		ap_aid_list=${ap_aid_list##*AID}
		ap_aid_list="${ap_aid_list##,,}"
		ap_aid_list="${ap_aid_list%%,,}"

		index=0
		debug_print "ap_aid_list:$ap_aid_list"
		# assure that aid list is not empty (i.e. it contains one ',' when no sta connected)
		if [ "$ap_aid_list" != "," ]; then
			for ap_aid_index in $ap_aid_list
			do
				let index=index+1
				ap_aid_index=`convert_aid_for_wav700 $ap_aid_index`
				[ $ap_aid_index -gt 0 ] && let ap_sta_index=$ap_aid_index-1
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${dl_usr_usp_station_indexes_idx}=${ap_sta_index}
			done
		fi
		info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
		send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
		connected_stations=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`
		if [ "$connected_stations" != "0" ]; then
			[ "$ap_type" != "EHT" ] && send_plan_for_${connected_stations}_users ${CURRENT_WLAN_NAME} $connected_stations $CURRENT_RADIO_UCI_PATH $glob_ssid $CURRENT_WLAN_NAME.0
		else
			#Required for 5.34.5 Step 4, where the NSS is modified from 1 to 2 and RU Allocation is done prior to stations associating to the AP
			kill_sigmaManagerDaemon
			send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
			/lib/netifd/sigmaManagerDaemon.sh $CURRENT_WLAN_NAME.0 $user_index &
		fi
	fi

	if [ "$ap_ndp_ltf" != "" ] || [ "$ap_ndp_gi" != "" ]; then
		debug_print "ap_ndp_ltf:$ap_ndp_ltf ap_ndp_gi:$ap_ndp_gi"
		if [ "$ap_ndp_ltf" = "6.4" ] && [ "$ap_ndp_gi" = "0.8" ]; then
			ap_mu_dl_com_ndp_he_ltf=1
			ap_mu_dl_com_ndp_he_cp=0
		elif [ "$ap_ndp_ltf" = "6.4" ] && [ "$ap_ndp_gi" = "1.6" ]; then
			ap_mu_dl_com_ndp_he_ltf=1
			ap_mu_dl_com_ndp_he_cp=1
		elif [ "$ap_ndp_ltf" = "12.8" ] && [ "$ap_ndp_gi" = "3.2" ]; then
			ap_mu_dl_com_ndp_he_ltf=2
			ap_mu_dl_com_ndp_he_cp=2
		else
			# all other LTF and GI combinations are not required by WFA
			error_print "Unsupported value - ap_ndp_ltf:$ap_ndp_ltf ap_ndp_gi:$ap_ndp_gi"
			send_invalid ",errorCode,435"
			return
		fi

		if [ "$ap_type" = "EHT" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			ap_sp_config_ltf=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_he_ltf_idx`
			let ap_sp_ppdu_ltf=$ap_sp_config_ltf%4
			let ap_sp_config_ltf=$ap_mu_dl_com_ndp_he_ltf*4+$ap_sp_ppdu_ltf
			ap_mu_dl_com_he_ltf=${ap_sp_config_ltf}

			ap_sp_config_cp=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_he_cp_idx`
			let ap_sp_ppdu_cp=$ap_sp_config_cp%4
			let ap_sp_config_cp=$ap_mu_dl_com_ndp_he_cp*4+$ap_sp_ppdu_cp
			ap_mu_dl_com_he_cp=${ap_sp_config_cp}
		fi
		if [ "$ML_VAP1" = "24G" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_24G_RADIO_UCI_PATH`
			[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
			[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
			if [ "$ML_VAP2" = "6G" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_6G_RADIO_UCI_PATH`
				[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
				[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
			else
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_5G_RADIO_UCI_PATH`
				[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
				[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
			fi
		else
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_6G_RADIO_UCI_PATH`
			[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
			[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}

			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_5G_RADIO_UCI_PATH`
			[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
			[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
		fi
	fi

	if [ "$ap_ltf" != "" ] || [ "$ap_gi" != "" ]; then
		debug_print "ap_ltf:$ap_ltf ap_gi:$ap_gi"		
        	tc_name=`get_test_case_name $glob_ssid`
		if [ "$ap_type" = "EHT" ]; then
			kill_sigmaManagerDaemon
		else
			if [ "$tc_name" = "4.30.1" ]; then
				kill_sigmaManagerDaemon
			fi
		fi
		if [ "$ap_ltf" = "6.4" ] && [ "$ap_gi" = "0.8" ]; then
			ap_su_ltf_gi="He0p8usCP2xLTF"
			ap_mu_dl_com_he_cp=0
			ap_mu_dl_com_he_ltf=1
			if [ "$glob_ofdma_phase_format" = "1" ]; then
				# this LTF and GI combination is not supported in MU UL
				error_print "Unsupported value - glob_ofdma_phase_format:$glob_ofdma_phase_format ap_ltf:$ap_ltf ap_gi:$ap_gi"
				send_invalid ",errorCode,420"
				return
			fi
		elif [ "$ap_gi" = "1.6" ]; then
			# JIRA WLANRTSYS-9350: in this case, handle not getting "ap_ltf" as if it has the value of "6.4"
			if [ "$ap_ltf" = "" ] || [ "$ap_ltf" = "6.4" ]; then
				ap_su_ltf_gi="He1p6usCP2xLTF"
				ap_mu_dl_com_he_cp=1
				ap_mu_dl_com_he_ltf=1
				ap_mu_ul_com_he_cp=1
				ap_mu_ul_com_he_ltf=1
				ap_mu_ul_com_he_tf_cp_and_ltf=1
				ap_mu_tf_len=3094
			fi
		elif [ "$ap_ltf" = "12.8" ] && [ "$ap_gi" = "3.2" ]; then
			ap_su_ltf_gi="He3p2usCP4xLTF"
			ap_mu_dl_com_he_cp=2
			ap_mu_dl_com_he_ltf=2
			ap_mu_ul_com_he_cp=2
			ap_mu_ul_com_he_ltf=2
			ap_mu_ul_com_he_tf_cp_and_ltf=2
			ap_mu_tf_len=2914
		else
			# all other LTF and GI combinations are not required by WFA
			error_print "Unsupported value - ap_ltf:$ap_ltf ap_gi:$ap_gi"
			send_invalid ",errorCode,430"
			return
		fi

		debug_print "ap_su_ltf_gi:$ap_su_ltf_gi ap_mu_dl_com_he_cp:$ap_mu_dl_com_he_cp ap_mu_dl_com_he_ltf:$ap_mu_dl_com_he_ltf"
		debug_print "ap_mu_ul_com_he_cp:$ap_mu_ul_com_he_cp ap_mu_ul_com_he_ltf:$ap_mu_ul_com_he_ltf ap_mu_ul_com_he_tf_cp_and_ltf:$ap_mu_ul_com_he_tf_cp_and_ltf ap_mu_tf_len:$ap_mu_tf_len"

		if [ "$ap_type" = "EHT" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			ap_sp_config_ltf=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_he_ltf_idx`
			let ap_sp_ndp_ltf=$ap_sp_config_ltf/4
			let ap_sp_config_ltf=$ap_mu_dl_com_he_ltf+$ap_sp_ndp_ltf*4
			ap_mu_dl_com_he_ltf=${ap_sp_config_ltf}

			ap_sp_config_cp=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_he_cp_idx`
			let ap_sp_ndp_cp=$ap_sp_config_cp/4
			let ap_sp_config_cp=$ap_mu_dl_com_he_cp+$ap_sp_ndp_cp*4
			ap_mu_dl_com_he_cp=${ap_sp_config_cp}
		fi

		# set for SU, only if not in OFDMA MU SP			
		if [ "$glob_ofdma_phase_format" = "" ]; then
			convert_fixed_ltf_gi Fixed ${ap_su_ltf_gi} 
			tc_name=`get_test_case_name $glob_ssid`
			if [ "$ap_type" = "EHT" ]; then
				if [ "$ML_VAP2" = "6G" ]; then
					info_print "$CURRENT_6G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}"
					iw dev $CURRENT_6G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}
					if [ "$ML_VAP1" = "5G" ]; then
						info_print "$CURRENT_5G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}"
						iw dev $CURRENT_5G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}
					else
						info_print "$CURRENT_24G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}"
						iw dev $CURRENT_24G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}
					fi
				else
					info_print "$CURRENT_24G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}"
					iw dev $CURRENT_24G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}
					info_print "$CURRENT_5G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}"	
					iw dev $CURRENT_5G_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}
				fi
			else
				iw dev $CURRENT_WLAN_NAME iwlwav sFixedLtfGi ${is_auto_converted} ${ltf_and_gi_value_converted}
			fi
		else
		# set for MU
			if [ "$ap_type" != "EHT" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
				[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
				[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
				[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
				[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
				[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
				[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}
				if [ "$ap_type" != "EHT" ] && [ "$global_ap_preamblepunctmode" = "" -a "$global_ap_preamblepunctchannel" = "" ]; then
					refresh_static_plan
				fi
			else
				if [ "$ML_VAP1" = "24G" ]; then
					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_24G_RADIO_UCI_PATH`
					[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
					[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
					[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
					[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
					[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
					[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}

					if [ "$ML_VAP2" = "6G" ]; then # for 2.4Ghz + 6GHz AP-MLD
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_6G_RADIO_UCI_PATH`
						[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
						[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
						[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
						[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
						[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
						[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}
					else # for 2.4Ghz + 5GHz AP-MLD
						ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_5G_RADIO_UCI_PATH`
						[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
						[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
						[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
						[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
						[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
						[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}
					fi
				elif [ "$ML_VAP1" = "5G" ]; then # for 5Ghz + 6GHz AP-MLD
					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_5G_RADIO_UCI_PATH`	
					[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
        		    [ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
        			[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
        		    [ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
        		    [ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
					[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}
					ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_6G_RADIO_UCI_PATH`
					[ "$ap_mu_dl_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_cp_idx=${ap_mu_dl_com_he_cp}
					[ "$ap_mu_dl_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$dl_com_he_ltf_idx=${ap_mu_dl_com_he_ltf}
					[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
					[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
					[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
					[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}
				else
					error_print "The VAP configured in MLD is not correct"
					send_invalid "errorCode,421"
					return
				fi
			fi
		fi
	fi

	#Set the coding type dynamically,only in EHT
	if [ "$ap_type" = "EHT" ] && [ "$ap_coding" != "" ]; then

		local coding_type sta_index

		debug_print "Set parameter : ap_coding : $ap_coding"
		tc_name=`get_test_case_name $glob_ssid`

		#Set 3rd parameter for Coding (BCC=0/LDPC=1) in sDoSimpleCLI
		[ "$ap_coding" = "BCCCoding" ] && coding_type=0
		[ "$ap_coding" = "LDPCCoding" ] && coding_type=1

		# set for SU, only if not in OFDMA MU SP
		if [ "$glob_ofdma_phase_format" = "" ]; then
			wlanname=""
			sta_index=`get_sid_for_wav700 "64" $CURRENT_24G_WLAN_NAME`
			if [ "$sta_index" -ge "$SID_24G_MIN" ] && [ "$sta_index" -le "$SID_24G_MAX" ]; then
				wlanname=$CURRENT_24G_WLAN_NAME
			else
				sta_index=`get_sid_for_wav700 "64" $CURRENT_5G_WLAN_NAME`
				if [ "$sta_index" -ge "$SID_5G_MIN" ] && [ "$sta_index" -le "$SID_5G_MAX" ]; then
					wlanname=$CURRENT_5G_WLAN_NAME
				else
					sta_index=`get_sid_for_wav700 "64" $CURRENT_6G_WLAN_NAME`
					if [ "$sta_index" -ge "$SID_6G_MIN" ] && [ "$sta_index" -le "$SID_6G_MAX" ]; then
						wlanname=$CURRENT_6G_WLAN_NAME
					fi
				fi
			fi

			if [ "$sta_index" != "512" ] && [ "$wlanname" != "" ]; then
				info_print "$wlanname iwlwav sDoSimpleCLI 121 ${sta_index} ${coding_type} 1"
				iw dev $wlanname iwlwav sDoSimpleCLI 121 ${sta_index} ${coding_type} 1
			fi
		fi

		#Set for MU
		for index in 1 2 3 4
		do
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'${ap_usr_index} $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x$rcr_tf_usr_coding_type_bcc_or_lpdc_idx=${coding_type}
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x$rcr_tf_usr_ldpc_idx=${coding_type}
		done
	fi

	if [ "$ap_transmit_omi" != "" ] && [ "$ap_transmit_omi" = "1" ]; then
		info_print "Sending an IW command to transmit non-eht OMI frames"
		ap_eht_omi=0 #For FW use to understand that this is non-eht OMI transmission
		aid_index=`$HOSTAPD_CLI_CMD -i$CURRENT_6G_WLAN_NAME.0 all_sta $CURRENT_6G_WLAN_NAME.0 | grep aid=`
		aid_index=${aid_index##*=}
		if [ "$aid_index" != "" ]; then
			let sta_index=$aid_index-64+256
			$SEND_IW_WLAN4 sDoSimpleCLI 132 $sta_index $ap_omctrl_chwidth $ap_eht_omi
		fi
		info_print "iw dev $CURRENT_6G_WLAN_NAME iwlwav sDoSimpleCLI 132 $sta_index $ap_omctrl_chwidth $ap_eht_omi"
	fi

	if [ "$ap_transmit_eht_omi" != "" ] && [ "$ap_transmit_eht_omi" = "1" ]; then
		info_print "Sending an IW command to transmit eht OMI frames"

		[ "$ap_eht_omctrl_chwidth" = "1" ] && ap_omctrl_chwidth=4
		ap_eht_omi=1 #For FW use to understand that this is eht OMI transmission
		sta_index=`get_sid_for_wav700 "64" $CURRENT_6G_WLAN_NAME`
		if [ "$sta_index" -ge "$SID_6G_MIN" ] && [ "$sta_index" -le "$SID_6G_MAX" ]; then
			$SEND_IW_WLAN4 sDoSimpleCLI 132 $sta_index $ap_omctrl_chwidth $ap_eht_omi
		fi
		info_print "iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 132 $sta_index $ap_omctrl_chwidth $ap_eht_omi"
	fi

	local is_activate_sigmaManagerDaemon=0

	if [ "$ap_trigger_type" != "" ]; then
		if [ "$ap_type" = "EHT" ]; then
			if [ "$ap_trig_variant" = "HE" ]; then
				info_print "iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 1"
				iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 1
			elif [ "$ap_trig_variant" = "EHT" ]; then
				info_print "iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 0"
				iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 0
			fi
		else
			info_print "iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 70 1"
			iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 70 1
			info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
			## kill the daemon if active - we need it only with ap_ack_policy empty.
			kill_sigmaManagerDaemon
			send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
			# JIRA WLANRTSYS-9307: in case "TRIGGERTYPE" was set, activate the SMD
			is_activate_sigmaManagerDaemon=1
			sleep 1
			# WLANRTSYS-82338 : For all the HE TB PPDU test case we need to execute the cmd "iw dev wlan2 iwlwav sDoSimpleCLI 130 1" to send trigger frames in HE format.
			info_print "AP type : $ap_type" 
			info_print "trigger type : $ap_trigger_type"
			if [ "$ap_type" = "HE" ] && [ "$ap_trigger_type" = "0" ]; then
				info_print "iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 1"
				iw dev $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 130 1
			fi
		fi
	fi

	if [ "$ap_ack_policy" = "" ] && [ "$ap_trigger_type" != "" ]; then
		info_print "CURRENT_WLAN_NAME:$CURRENT_WLAN_NAME ap_trigger_type:$ap_trigger_type"
		case "$ap_trigger_type" in
		0)
			# BASIC - do nothing. We passed without configuring this.
		;;
		1)
			# BF_RPT_POLL (MU-BRP)
			ap_sequence_type=1  #HE_MU_SEQ_VHT_LIKE
			# Enable MIMO and set the phase format to DL to have DL traffic work. Using sounding phase format (=2) will not enable DL traffic phase as this is an unsupported config in FW.
			# MIMO will ensure to enable sounding implicitly.
			glob_ofdma_phase_format=0
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_phases_format_idx}=$glob_ofdma_phase_format
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_mu_type_idx}=1

			for ap_usr_index in 1 2
			do
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'${ap_usr_index} $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				if [ "$global_ap_mimo" != "ul" ]; then
					Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_usr_index} x${dl_usr_ul_psdu_rate_per_usp_idx}=4
				fi
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_usr_index} x${rcr_tf_usr_psdu_rate_idx}=4
			done
		;;
		3)
			# MU-RTS
			ap_sequence_type=4  #HE_MU_SEQ_VHT_LIKE_PROTECTION
		;;
		4)
			# BUFFER_STATUS_RPT (BSRP)
			if [ -n "$glob_ofdma_phase_format" ] && [ $glob_ofdma_phase_format -eq 0 ]; then
				ap_sequence_type=10 #HE_MU_BSRP_DL
			else
				ap_sequence_type=6  #HE_MU_BSRP
			fi
			if [ "$global_ap_mimo" = "dl" ]; then
				ap_tf_len=406
			else
				ap_tf_len=106
			fi
			if [ "$ap_type" != "EHT" ]; then
				# (was 109) UL_LEN = 109 (together with PE_dis=1) causes T_PE to exceed 16usec, which is not according to standard
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=$ap_tf_len
				ap_mu_tf_len=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$rcr_com_tf_length_idx`
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=0
			else
				Dynamic_set_get_helper iw_off $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=$ap_tf_len
				ap_mu_tf_len=`get_index_from_db $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$rcr_com_tf_length_idx`
				Dynamic_set_get_helper iw_off $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=0

				Dynamic_set_get_helper iw_off $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=$ap_tf_len
				ap_mu_tf_len=`get_index_from_db $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$rcr_com_tf_length_idx`
				Dynamic_set_get_helper iw_off $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=0

				Dynamic_set_get_helper iw_off $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=$ap_tf_len
				ap_mu_tf_len=`get_index_from_db $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$rcr_com_tf_length_idx`
				Dynamic_set_get_helper iw_off $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=0
			fi
		;;
		*)
			error_print "Unsupported value - ap_ack_policy empty and ap_trigger_type:$ap_trigger_type"
			send_invalid ",errorCode,461"
			return
		;;
		esac

	fi

	if [ "$ap_ack_policy" != "" ]; then
		debug_print "ap_ack_policy:$ap_ack_policy, ap_trigger_type:$ap_trigger_type"

		case "$ap_ack_policy" in
		0)
			# Ack Policy set to Normal Ack (internal name: immediate Ack)
			# we use the glob_ap_ack_policy_mac to set the requested user as primary.

			# Ack Policy MAC address handling
			if [ "$glob_ap_ack_policy_mac" != "" ]; then
				ap_aid=`cat /proc/net/mtlk/$CURRENT_WLAN_NAME.0/sta_list | grep "0" | grep -iF "$glob_ap_ack_policy_mac" | awk '{print $5}'`
				ap_aid=`convert_aid_for_wav700 $ap_aid`

				[ "$ap_aid" = "" ] && error_print ""MAC not found: glob_ap_ack_policy_mac:$glob_ap_ack_policy_mac""
			fi
			info_print "CURRENT_WLAN_NAME:$CURRENT_WLAN_NAME ap_ack_policy:$ap_ack_policy glob_ap_ack_policy_mac:$glob_ap_ack_policy_mac"
			ap_sequence_type=3  #HE_MU_SEQ_VHT_LIKE_IMM_ACK
			[ "$ap_type" = "EHT" ] && [ "$global_ap_mimo" != "" ] && ap_sequence_type=1 #HE_MU_SEQ_VHT_LIKE
		;;
		1)
			# Ack Policy set to No Ack
			# nothing to do. not supported yet.
			info_print "CURRENT_WLAN_NAME:$CURRENT_WLAN_NAME ap_ack_policy:$ap_ack_policy"
		;;
		2)
			# Ack Policy set to Implicit Ack (internal name: immediate Ack on Aggr., VHT-like)
			# nothing to do. not supported yet.
			info_print "CURRENT_WLAN_NAME:$CURRENT_WLAN_NAME ap_ack_policy:$ap_ack_policy"
		;;
		3)
			# Ack Policy set to Block Ack (internal name: sequential BAR, VHT-like)
			# this is the default value, but we anyway return it to default.
			info_print "CURRENT_WLAN_NAME:$CURRENT_WLAN_NAME ap_ack_policy:$ap_ack_policy"
			ap_sequence_type=1  #HE_MU_SEQ_VHT_LIKE

			# MU-BAR scenario TC 5.51 & 4.45
			if [ "$ap_trigger_type" = "2" ]; then
				ap_sequence_type=0  #HE_MU_SEQ_MU_BAR
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=310
				ap_mu_tf_len=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$rcr_com_tf_length_idx`
			fi
		;;
		4)
			# Ack Policy set to Unicast TF Basic
			if [ "$ap_trigger_type" = "0" ]; then
				ap_sequence_type=2  #HE_MU_SEQ_DL_BASIC_TF
			fi
		;;
		*)
			error_print "Unsupported value - ap_ack_policy:$ap_ack_policy"
			send_invalid ",errorCode,460"
			return
		;;
		esac
	fi

	# update the phase format, only if needed
	if [ "$ap_sequence_type" != "" ]; then
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		if [ "$ap_type" != "EHT" ]; then
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${sequence_type_idx}=${ap_sequence_type}
		else
			Dynamic_set_get_helper iw_off $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${sequence_type_idx}=${ap_sequence_type}
			Dynamic_set_get_helper iw_off $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${sequence_type_idx}=${ap_sequence_type}
			Dynamic_set_get_helper iw_off $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${sequence_type_idx}=${ap_sequence_type}
		fi

		ap_interface_index=${ap_wlan_name/wlan/}

		# update the primary sta, only if needed
		if [ "$ap_aid" != "" ]; then
			# convert aid=1,2,3,... to  sta_id=0,1,2,...
			let ap_sta_id=$ap_aid-1

			# find the user id of the requested primary sta
			for ap_user_id in 1 2 3 4
			do
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_user_id $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				ap_sta_index=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_usr_usp_station_indexes_idx`
				
				if [ "$ap_sta_index" = "$ap_sta_id" ]; then
					glob_ap_user_id_prim=$ap_user_id
					break
				fi 
			done

			# switch the OFDMA users, so the primary sta id will be at user 1 (first user). not needed if it is already in user 1.
			if [ "$glob_ap_user_id_prim" != "1" ]; then
				# 1. load the sta id of user1
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser1' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				ap_orig_sta_index=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_usr_usp_station_indexes_idx`

				# 2. store the primary sta id in user 1
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser1 x${dl_usr_usp_station_indexes_idx}=${ap_sta_id}
				# 3. store the original sta id from user 1 in the found user
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'${glob_ap_user_id_prim} $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${glob_ap_user_id_prim} x${dl_usr_usp_station_indexes_idx}=${ap_orig_sta_index}
			fi
		fi

		info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
		send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
		connected_stations=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`

		# JIRA WLANRTSYS-9307: in case the SMD needed to be activated, make sure the plan won't be set
		if [ "$is_activate_sigmaManagerDaemon" = "1" ]; then
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$operation_mode_idx=0
		fi

		[ "$ap_type" != "EHT" ] && send_plan_for_${connected_stations}_users ${CURRENT_WLAN_NAME} $connected_stations $CURRENT_RADIO_UCI_PATH $glob_ssid $CURRENT_WLAN_NAME.0
	fi
	# for test HE-5.64.1 & 5.61.1
	if [ "$ap_trig_interval" != "" ]; then
		# iw wlanX sDoSimpleCLI 3 13 <Trigger Interval> <Fixed Interval>
		# Trigger Interval field is in units of usecs
		# Fixed Interval is set to 1 to force no repetitions
		ap_trig_interval=$((ap_trig_interval * 1000 ))
		iw $CURRENT_WLAN_NAME iwlwav sDoSimpleCLI 3 13 $ap_trig_interval 1

		if [ "$ap_trig_interval" != "10000" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=0
		fi

		# for test 5.61.1_24G - Jira WLANRTSYS-80398
		if [ "$ap_trig_interval" = "10000" ] && [ "$MODEL" = "WAV700_AP" ] && [ "$tc_name" = "5.61.1" ] && [ "$CURRENT_WLAN_NAME" = "wlan0" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=0
		fi

		[ "$ap_type" != "EHT" ] && refresh_static_plan
	fi

	if [ "$ap_trig_cominfo_ullength" != "" ]
	then
		# for test HE-5.61.1
		if [ "$ap_trig_cominfo_ullength" = "601" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=610
		# for test HE-5.64.1
		elif [ "$ap_trig_cominfo_ullength" = "2251" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=2254
		else
			# regular case, not '601' nor '2251'
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=$ap_trig_cominfo_ullength
		fi
		ap_mu_tf_len=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$rcr_com_tf_length_idx`
		[ "$ap_type" != "EHT" ] && refresh_static_plan
	fi

	# for test HE-5.61.1
	if [ "$ap_mpdu_mu_spacingfactor" != "" ]
	then
		for usr_index in 1 2 3 4
		do
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x${tf_usr_tf_mpdu_mu_spacing_factor_idx}=${ap_mpdu_mu_spacingfactor}
		done
	fi
	
	# for tests HE-5.59.2 & HE-5.61.1
	if [ "$ap_trig_usrinfo_ul_mcs" != "" ]; then
		for usr_index in 1 2 3 4
		do
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			ap_mcs_nss=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x3`
			ap_nss=$(((ap_mcs_nss)/16+1))
			ap_trig_nss_mcs_val=$(((ap_trig_ul_nss*16)+ap_trig_usrinfo_ul_mcs))
			if [ "$global_ap_mimo" != "ul" ]; then
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ul_psdu_rate_per_usp_idx=${ap_trig_mu_nss_mcs_val}
			fi
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_psdu_rate_per_usp_idx==${ap_trig_mu_nss_mcs_val}
		done
		[ "$ap_type" != "EHT" ] && refresh_static_plan

	fi
#Note : This CAPI expects PUNCTCHANNEL only as a parameter
#If WFA started to give the CHNUM_BAND and PUNCTCHANNEL both in the same command then the behaviour is unexpected
#TODO : Handle the above scenario of receiving both the parameters in the same command
	if [ "$ap_dyn_punct_channel" != "" ]; then

		ap_phy=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.phy`
		ap_chan=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.channel`
		get_freq_from_chan $ap_phy $ap_chan
		ap_band=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.htmode`
		ap_band=`echo $ap_band | sed 's/[^0-9]*//g'`
		get_central_freq_vht $ap_chan $ap_band $ap_phy
		[ "$ap_band" = "3201" -o "$ap_band" = "3202" ] && ap_band=320

		DYN_PUNC_CHNL_FILE="/tmp/sigma_dynamic_punc_chnl"
		rm -f $DYN_PUNC_CHNL_FILE
		echo $ap_dyn_punct_channel | tr ' ' '\n' >> $DYN_PUNC_CHNL_FILE
		if [ "$ap_dyn_punct_channel" != "0" ]; then
			#Third argument provided to the subroutine
			#1-dynamic puncturing
			#0-static puncturing
			dis_subchnl_bitmap_val=`get_disabled_subchannel_bitmap_val $CURRENT_RADIO_UCI_PATH $nof_channels 1`
		else
			dis_subchnl_bitmap_val=0
		fi
		ap_cmd="$HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME chan_switch 10 $ap_freq center_freq1=$ap_centr_freq bandwidth=$ap_band blocktx=1 auto-ht punct_bitmap=$dis_subchnl_bitmap_val"
		if [ "$ap_centr_freq1" != "" ]; then
			ap_cmd="$HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME chan_switch 10 $ap_freq center_freq1=$ap_centr_freq1 center_freq2=$ap_centr_freq bandwidth=$ap_band blocktx=1 auto-ht punct_bitmap=$dis_subchnl_bitmap_val"
		fi
		debug_print "dis_subchannel_bitmap_value=$dis_subchnl_bitmap_val"
		ap_tmp=`eval $ap_cmd`
	fi

	#Preamble Puncturing
	if [ "$global_ap_preamblepunctmode" != "" ] && [ "$global_ap_preamblepunctchannel" != "" ]; then
		local dl_sub_band1 ul_sub_band1
		local dl_sub_band2 ul_sub_band2
		local dl_sub_band3 ul_sub_band3
		local ap_preamblepunc_sequence_type=1 #HE_MU_SEQ_VHT_LIKE
		if [ "$global_ap_preamblepunctmode" = "4" ] && ([ "$global_ap_preamblepunctchannel" = "40" ] || [ "$global_ap_preamblepunctchannel" = "33" ]); then
			debug_print "Set preamble puncture override for Mode 4"
			if [ "$global_ap_preamblepunctchannel" = "40" ]; then
				ap_tmp=`eval iw dev $CURRENT_WLAN_NAME iwlwav sPreamPunCcaOvr 1 2 1`
				dl_sub_band1=0;ul_sub_band1=0
				dl_sub_band2=2;ul_sub_band2=2
				dl_sub_band3=3;ul_sub_band3=3
			else
				#Puncture map TCRs and DL/UL sub-band are in the order of frequency
				#Channels:33-37(Beaconing)-41-45 in 6GHz would mean DL sub-band for Ch37 is 1 and not 0
				ap_tmp=`eval iw dev $CURRENT_WLAN_NAME iwlwav sPreamPunCcaOvr 1 1 1`
				dl_sub_band1=1;ul_sub_band1=1
				dl_sub_band2=2;ul_sub_band2=2
				dl_sub_band3=3;ul_sub_band3=3
			fi
		elif [ "$global_ap_preamblepunctmode" = "5" ] && ([ "$global_ap_preamblepunctchannel" = "44" ] || [ "$global_ap_preamblepunctchannel" = "41" ]); then
			debug_print "Set preamble puncture override for Mode 5"
			ap_tmp=`eval iw dev $CURRENT_WLAN_NAME iwlwav sPreamPunCcaOvr 1 4 1`
			dl_sub_band1=0;ul_sub_band1=0
			dl_sub_band2=1;ul_sub_band2=1
			dl_sub_band3=3;ul_sub_band3=3
		elif [ "$global_ap_preamblepunctmode" = "5" ] && ([ "$global_ap_preamblepunctchannel" = "48" ] || [ "$global_ap_preamblepunctchannel" = "45" ]); then
			debug_print "Set preamble puncture override for Mode 5"
			ap_tmp=`eval iw dev $CURRENT_WLAN_NAME iwlwav sPreamPunCcaOvr 1 8 1`
			dl_sub_band1=0;ul_sub_band1=0
			dl_sub_band2=1;ul_sub_band2=1
			dl_sub_band3=2;ul_sub_band3=2
		fi
		for usr_index in 1 2 3
		do
			local tmp_param tmp_val
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			tmp_param="dl_sub_band$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x${dl_usr_sub_band_per_usp_idx}=${tmp_val}
			tmp_param="ul_sub_band$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x${rcr_tf_usr_sub_band_idx}=${tmp_val}
		done
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${sequence_type_idx}=${ap_preamblepunc_sequence_type}
		[ "$ap_type" != "EHT" ] && refresh_static_plan
	fi

	# JIRA WLANRTSYS-9307: in case "TRIGGERTYPE" was set, activate the SMD ap_trigger_type
	if [ "$is_activate_sigmaManagerDaemon" = "1" ]; then
		if [ "$ap_type" != "EHT" ]; then
                        get_nof_sta_per_he_test_case $glob_ssid
                        connected_stations=$nof_sta
                        arguments_file_initializer $CURRENT_RADIO_UCI_PATH $glob_ssid
                        kill_sigmaManagerDaemon
                        if [ "$connected_stations" = "0" ]; then
                                connected_stations=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`
                        fi
                        /lib/netifd/sigmaManagerDaemon.sh $CURRENT_WLAN_NAME.0 $connected_stations &
                        is_activate_sigmaManagerDaemon=0
                else
                        tc_name=`get_test_case_name $glob_ssid`
                        [ -n "$global_ap_num_users_ofdma" ] && nof_sta=$global_ap_num_users_ofdma
                        connected_stations=$nof_sta
                        kill_sigmaManagerDaemon
                        if [ "$ML_VAP1" = "5G" ]; then
                                if [ "$connected_stations" = "0" ]; then
                                        connected_stations=`get_connected_stations ${CURRENT_6G_WLAN_NAME/.0}`
                                fi
                                /lib/netifd/sigmaManagerDaemon.sh $CURRENT_6G_WLAN_NAME.0 $connected_stations &
                        elif [ "$ML_VAP2" = "5G" ]; then
                                if [ "$connected_stations" = "0" ]; then
                                        connected_stations=`get_connected_stations ${CURRENT_5G_WLAN_NAME/.0}`
                                fi
				/lib/netifd/sigmaManagerDaemon.sh $CURRENT_5G_WLAN_NAME.0 $connected_stations &
				if [ "$connected_stations" = "0" ]; then
                                        connected_stations=`get_connected_stations ${CURRENT_24G_WLAN_NAME/.0}`
                                fi
				/lib/netifd/sigmaManagerDaemon.sh $CURRENT_24G_WLAN_NAME.0 $connected_stations &
                        else
                                debug_print "MLD not configured yet"
                        fi
                        is_activate_sigmaManagerDaemon=0
                fi
	fi
	
	# Set trigger coding (LDPC/BCC) for UL
	if [ "$glob_ap_trigger_coding" != "" ]; then
		debug_print "glob_ap_trigger_coding:$glob_ap_trigger_coding"
		
		info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
		if [ "$ap_type" = "EHT" ]; then
			send_plan_off ${CURRENT_24G_WLAN_NAME/.0} $CURRENT_24G_RADIO_UCI_PATH
			send_plan_off ${CURRENT_5G_WLAN_NAME/.0} $CURRENT_5G_RADIO_UCI_PATH
			send_plan_off ${CURRENT_6G_WLAN_NAME/.0} $CURRENT_6G_RADIO_UCI_PATH
		else
			send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
		fi
		info_print "ap_bcc_ldpc_int: BCC or LDPC"
		if [ "$glob_ap_trigger_coding" = "BCC" ]; then
			ap_bcc_ldpc_int=0
		elif [ "$glob_ap_trigger_coding" = "LDPC" ]; then
			ap_bcc_ldpc_int=1
		fi
		
		tc_name=`get_test_case_name $glob_ssid`
		for usr_index in 1 2 3 4
		do
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'${usr_index} $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			if [ "$ap_type" = "EHT" ]; then
				if [ "$ML_VAP1" = "24G" ] && [ "$ML_VAP2" = "5G" ]; then
					if [ "$ap_bcc_ldpc_int" = "0" ]; then
					    Dynamic_set_get_helper iw_off_helper $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int x18=$ap_bcc_ldpc_int
				    fi
                    Dynamic_set_get_helper iw_off_helper $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int x18=$ap_bcc_ldpc_int
                elif [ "$ML_VAP2" = "6G" ]; then
					Dynamic_set_get_helper iw_off_helper $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int x18=$ap_bcc_ldpc_int
					[ "$ML_VAP1" = "24G" ] && [ "$ML_VAP2" = "6G" ] && Dynamic_set_get_helper iw_off_helper $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int x18=$ap_bcc_ldpc_int
				else
					debug_print "MLD is not configured yet"
				fi
			else
				Dynamic_set_get_helper iw_off_helper $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${usr_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int
			fi
		done
		
		if [ "$ap_type" != "EHT" ]; then
			connected_stations=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`
			if [ "$connected_stations" = "1" ] || [ "$connected_stations" = "2" ] || [ "$connected_stations" = "4" ]; then
				send_plan_for_${connected_stations}_users ${CURRENT_WLAN_NAME} $connected_stations $CURRENT_RADIO_UCI_PATH $glob_ssid $CURRENT_WLAN_NAME.0
			fi
		fi
	fi

	if [ "$ap_cominfo_bw" != "" ]; then
		debug_print "ap_cominfo_bw:$ap_cominfo_bw"
		info_print "Plan OFF send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH"
		send_plan_off ${CURRENT_WLAN_NAME/.0} $CURRENT_RADIO_UCI_PATH
		if [ "$ap_type" = "EHT" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			start_bw_limit=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx`
			if [ "$ap_cominfo_bw" -le "$start_bw_limit" ]; then
				debug_print "Ignore this ComInfo BW"
			else
				ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${txop_com_start_bw_limit_idx}=${ap_cominfo_bw}
			fi
		else
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${txop_com_start_bw_limit_idx}=${ap_cominfo_bw}
		fi

		connected_stations=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`
		if [ "$connected_stations" = "1" ] || [ "$connected_stations" = "2" ] || [ "$connected_stations" = "4" ]; then
			[ "$ap_type" != "EHT" ] && send_plan_for_${connected_stations}_users ${CURRENT_WLAN_NAME} $connected_stations $CURRENT_RADIO_UCI_PATH $glob_ssid $CURRENT_WLAN_NAME.0
		fi
	fi
	
	if [ "$ap_usrinfo_ss_alloc_ra_ru" != "" ]; then
		local ap_sta_aid=$glob_ap_sta_aid
		debug_print "ap_sta_aid:$ap_sta_aid ap_usrinfo_ss_alloc_ra_ru:$ap_usrinfo_ss_alloc_ra_ru"
		local AID_SS_FILE="/tmp/sigma-aid-ss-conf"
		local AID_SS_FILE_SORTED="/tmp/sigma-aid-ss-conf-sort"
		[ -e $AID_SS_FILE ] && rm $AID_SS_FILE
		[ -e $AID_SS_FILE_SORTED ] && rm $AID_SS_FILE_SORTED
		local i=0 j=0
		if [ "$MODEL" = "WAV700_AP" ]; then
			file=$AID_SS_FILE_SORTED
		#Two digit aid for EHT cert on WAV700.
		#Three digit aid for legacy cert on WAV700.
			if [ "$ucc_program" = "eht" ]; then
				width=2
			else
				width=3
			fi
		else #One digit aid for legacy
			file=$AID_SS_FILE
			width=1
		fi
		while [ $i -lt 4 ]
		do
			echo ${ap_usrinfo_ss_alloc_ra_ru:i:1},${ap_sta_aid:j:width} >> $file
			i=$((i+1))
			j=$((j+width))
		done

		if [ "$MODEL" != "WAV700_AP" ]; then
			sort -r $AID_SS_FILE > $AID_SS_FILE_SORTED
		fi
		local line param index sta_aid_val
		# update all users according to the AID_SS_FILE_SORTED

		index=0
		while read -r line || [[ -n "$line" ]]
		do
			# 3 params per line: ss_alloc_ra_ru,sta_aid,ru_alloc
			let index=index+1
			info_print "line=$line"
			ap_usrinfo_ss_alloc_ra_ru=${line%%,*}
			line="${line//$ap_usrinfo_ss_alloc_ra_ru,/""}"
			# update the DB with ss_alloc_ra_ru
			# get MU UL MCS value
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			if [ "$ap_trig_usrinfo_ul_mcs" = "" ]; then
				ap_mcs=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x3`
				let ap_mcs="$ap_mcs%16"
			else
				ap_mcs=$ap_trig_usrinfo_ul_mcs
			fi
			# calculate the OFDMA MU NSS-MCS value (NSS: bits 6-4, MCS: bits 3-0)
			let ap_ofdma_mu_nss_mcs_val="($ap_usrinfo_ss_alloc_ra_ru)*16+$ap_mcs"
			# set MU UL NSS MCS value
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'${index} $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			if [ "$global_ap_mimo" != "ul" ]; then
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${dl_usr_ul_psdu_rate_per_usp_idx}=$ap_ofdma_mu_nss_mcs_val
			fi
			ap_sta_aid=`convert_aid_for_wav700 "${line}"`
			[ $ap_sta_aid -gt 0 ] && let sta_aid_val=$ap_sta_aid-1
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${dl_usr_usp_station_indexes_idx}=${sta_aid_val}

		done < $AID_SS_FILE_SORTED

		[ "$ap_type" != "EHT" ] && refresh_static_plan
	fi
	
	if [ "$ap_cominfo_gi_ltf" != "" ]; then
		debug_print "ap_cominfo_gi_ltf:$ap_cominfo_gi_ltf"
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		mu_type=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_mu_type_idx`
		nof_users=`get_connected_stations ${CURRENT_WLAN_NAME/.0}`
		if [ "$ap_cominfo_gi_ltf" = "1" ]; then
			ap_mu_ul_com_he_cp=1
			ap_mu_ul_com_he_ltf=1
			ap_mu_ul_com_he_tf_cp_and_ltf=1
			ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 3094`
			if [ "$ap_type" = "EHT" ] && [ "$start_bw_limit" = "4" ] && [ "$mu_type" = "0" ]; then
				ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 1591`
				if [ "$nof_users" = "2" ]; then
					ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 598`
					ap_num_rep=3
				fi
			fi
			if [ "$global_ap_mimo" = "ul" ]; then
				ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 208`
				[ "$ap_type" = "EHT" ] && ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 832`
				ap_num_rep=3
			fi
		elif [ "$ap_cominfo_gi_ltf" = "2" ]; then
			ap_mu_ul_com_he_cp=2
			ap_mu_ul_com_he_ltf=2
			ap_mu_ul_com_he_tf_cp_and_ltf=2
			ap_mu_tf_len=2914
			if [ "$ap_type" = "EHT" ] && [ "$start_bw_limit" = "4" ] && [ "$mu_type" = "0" ]; then
				ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 1594`
				if [ "$nof_users" = "2" ]; then
					ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 586`
					ap_num_rep=3
				fi
			fi
			if [ "$global_ap_mimo" = "ul" ]; then
				ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 202`
				[ "$ap_type" = "EHT" ] && ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 802`
				ap_num_rep=3
			fi
		elif [ "$ap_cominfo_gi_ltf" = "0" ]; then
			ap_mu_ul_com_he_cp=1
			ap_mu_ul_com_he_ltf=0
			ap_mu_ul_com_he_tf_cp_and_ltf=0
			ap_mu_tf_len=`sp_set_plan_tf_length $CURRENT_WLAN_NAME.0 2914`
		else
			# all other LTF and GI combinations are not required by WFA
			error_print "Unsupported value - ap_ltf:$ap_ltf ap_gi:$ap_gi"
			send_invalid ",errorCode,482"
			return
		fi
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		debug_print "ap_mu_ul_com_he_cp:$ap_mu_ul_com_he_cp ap_mu_ul_com_he_ltf:$ap_mu_ul_com_he_ltf ap_mu_ul_com_he_tf_cp_and_ltf:$ap_mu_ul_com_he_tf_cp_and_ltf ap_mu_tf_len:$ap_mu_tf_len"

		if [ "$ML_VAP1" != "" ] || [ "$ML_VAP2" != "" ]; then
			[ "$ap_num_rep" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=${ap_num_rep}
			[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
			[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
			[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
			[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}

			[ "$ap_num_rep" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=${ap_num_rep}
			[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
			[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
			[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
			[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}

			[ "$ap_num_rep" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=${ap_num_rep}
			[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
			[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
			[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
			[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}
		else
			[ "$ap_num_rep" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=${ap_num_rep}
			[ "$ap_mu_ul_com_he_cp" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_cp_idx=${ap_mu_ul_com_he_cp}
			[ "$ap_mu_ul_com_he_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$ul_com_he_ltf_idx=${ap_mu_ul_com_he_ltf}
			[ "$ap_mu_ul_com_he_tf_cp_and_ltf" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_hegi_and_ltf_idx=${ap_mu_ul_com_he_tf_cp_and_ltf}
			[ "$ap_mu_tf_len" != "" ] && Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}
		fi
		[ "$ap_type" != "EHT" ] && refresh_static_plan
	fi

	if [ "$global_ap_mimo" == "" ] && [ "$glob_ofdma_phase_format" = "1" ] &&  [ "$ap_type" = "EHT" ] && [ "$start_bw_limit" = "0" ]; then
		# in EHT OFDMA UL, 20 MHz, set UL Length to 3082
		ap_mu_tf_len=3082		
		Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common $rcr_com_tf_length_idx=${ap_mu_tf_len}
	fi
	
		# handle RU allocation for UL
	if [ "$glob_ap_usrinfo_ru_alloc" != "" ]; then
		debug_print "glob_ap_usrinfo_ru_alloc:$glob_ap_usrinfo_ru_alloc"
		# replace all ':' with " "
		tmp_ap_usrinfo_ru_alloc=${glob_ap_usrinfo_ru_alloc//:/ }

		local user_index user_list index user_value start_bw_limit
		local ul_sub_band1 ul_start_ru1 ul_ru_size1
		local ul_sub_band2 ul_start_ru2 ul_ru_size2
		local ul_sub_band3 ul_start_ru3 ul_ru_size3
		local ul_sub_band4 ul_start_ru4 ul_ru_size4

		if [ "$ap_type" != "EHT" ] && [ "$ap_cominfo_bw" != "" ]; then
			# if exist, get the bw from previous parameter in this command
			start_bw_limit=$ap_cominfo_bw
		else
			# else, get the bw from the SP
			ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
			start_bw_limit=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx` #x3
		fi

		user_index=0
		for user_value in $tmp_ap_usrinfo_ru_alloc
		do
			let user_index=user_index+1

			### BW=320MHz ###
			if [ "$start_bw_limit" = "4" ]; then
				info_print "RU allocation for 160MHz UL: currently values are same as DL need to be updated"
				if [ "$user_value" = "996" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=5
						;;
						"2") #USER2
							ul_sub_band2=4;ul_start_ru2=0;ul_ru_size2=5
						;;
						"3") #USER3
							ul_sub_band3=8;ul_start_ru3=0;ul_ru_size3=5
						;;
						"4") #USER4
							ul_sub_band4=12;ul_start_ru4=0;ul_ru_size4=5
						;;
					esac
				elif [ "$user_value" = "1992" ] || [ "$user_value" = "2x996" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=6
						;;
						"2") #USER2
							ul_sub_band2=8;ul_start_ru2=0;ul_ru_size2=6
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,605"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,610"
							return
						;;
					esac
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,670"
					return
				fi

			### BW=160MHz ###
			elif [ "$start_bw_limit" = "3" ]; then
				info_print "RU allocation for 160MHz UL: currently values are same as DL need to be updated"
				if [ "$user_value" = "106" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=2
						;;
						"2") #USER2
							ul_sub_band2=2;ul_start_ru2=0;ul_ru_size2=2
						;;
						"3") #USER3
							ul_sub_band3=4;ul_start_ru3=0;ul_ru_size3=2
						;;
						"4") #USER4
							ul_sub_band4=6;ul_start_ru4=0;ul_ru_size4=2
						;;
					esac
				elif [ "$user_value" = "242" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3
						;;
						"2") #USER2
							ul_sub_band2=2;ul_start_ru2=0;ul_ru_size2=3
						;;
						"3") #USER3
							ul_sub_band3=4;ul_start_ru3=0;ul_ru_size3=3
						;;
						"4") #USER4
							ul_sub_band4=6;ul_start_ru4=0;ul_ru_size4=3
						;;
					esac
				elif [ "$user_value" = "484" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=4
						;;
						"2") #USER2
							ul_sub_band2=2;ul_start_ru2=0;ul_ru_size2=4
						;;
						"3") #USER3 - not supported
							ul_sub_band3=4;ul_start_ru3=0;ul_ru_size3=4
						;;
						"4") #USER4 - not supported
							ul_sub_band4=6;ul_start_ru4=0;ul_ru_size4=4
						;;
					esac
				elif [ "$user_value" = "996" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=5
						;;
						"2") #USER2
							ul_sub_band2=4;ul_start_ru2=0;ul_ru_size2=5
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,655"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,660"
							return
						;;
					esac
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,665"
					return
				fi

			### BW=80MHz ###
			elif [ "$start_bw_limit" = "2" ]; then
				if [ "$user_value" = "26" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=0
						;;
						"2") #USER2
							ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=0
						;;
						"3") #USER3
							ul_sub_band3=2;ul_start_ru3=0;ul_ru_size3=0
						;;
						"4") #USER4
							ul_sub_band4=3;ul_start_ru4=0;ul_ru_size4=0
						;;
					esac
				elif [ "$user_value" = "52" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=1
						;;
						"2") #USER2
							ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=1
						;;
						"3") #USER3
							ul_sub_band3=2;ul_start_ru3=0;ul_ru_size3=1
						;;
						"4") #USER4
							ul_sub_band4=3;ul_start_ru4=0;ul_ru_size4=1
						;;
					esac
				elif [ "$user_value" = "106" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=2
						;;
						"2") #USER2
							ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=2
						;;
						"3") #USER3
							ul_sub_band3=2;ul_start_ru3=0;ul_ru_size3=2
						;;
						"4") #USER4
							ul_sub_band4=3;ul_start_ru4=0;ul_ru_size4=2
						;;
					esac
				elif [ "$user_value" = "242" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3
						;;
						"2") #USER2
							ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=3
						;;
						"3") #USER3
							ul_sub_band3=2;ul_start_ru3=0;ul_ru_size3=3
						;;
						"4") #USER4
							ul_sub_band4=3;ul_start_ru4=0;ul_ru_size4=3
						;;
					esac
				elif [ "$user_value" = "484" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=4
						;;
						"2") #USER2
							ul_sub_band2=2;ul_start_ru2=0;ul_ru_size2=4
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,481"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,482"
							return
						;;
					esac
				elif [ "$user_value" = "996" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=5
						;;
						"2") #USER2
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,483"
							return
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,484"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,485"
							return
						;;
					esac
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,486"
					return
				fi

			### BW=40MHz ###
			elif [ "$start_bw_limit" = "1" ]; then
				if [ "$user_value" = "26" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=0
						;;
						"2") #USER2
							ul_sub_band2=0;ul_start_ru2=5;ul_ru_size2=0
						;;
						"3") #USER3
							ul_sub_band3=1;ul_start_ru3=0;ul_ru_size3=0
						;;
						"4") #USER4
							ul_sub_band4=1;ul_start_ru4=5;ul_ru_size4=0
						;;
					esac
				elif [ "$user_value" = "52" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=1
						;;
						"2") #USER2
							ul_sub_band2=0;ul_start_ru2=5;ul_ru_size2=1
						;;
						"3") #USER3
							ul_sub_band3=1;ul_start_ru3=0;ul_ru_size3=1
						;;
						"4") #USER4
							ul_sub_band4=1;ul_start_ru4=5;ul_ru_size4=1
						;;
					esac
				elif [ "$user_value" = "106" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=2
						;;
						"2") #USER2
							ul_sub_band2=0;ul_start_ru2=5;ul_ru_size2=2
						;;
						"3") #USER3
							ul_sub_band3=1;ul_start_ru3=0;ul_ru_size3=2
						;;
						"4") #USER4
							ul_sub_band4=1;ul_start_ru4=5;ul_ru_size4=2
						;;
					esac
				elif [ "$user_value" = "242" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3
						;;
						"2") #USER2
							ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=3
						;;
						"3") #USER3 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,487"
							return
						;;
						"4") #USER4 - not supported
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,488"
							return
						;;
					esac
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,489"
					return
				fi

			### BW=20MHz ###
			elif [ "$start_bw_limit" = "0" ]; then
				if [ "$user_value" = "26" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=0
						;;
						"2") #USER2
							ul_sub_band2=0;ul_start_ru2=2;ul_ru_size2=0
						;;
						"3") #USER3
							ul_sub_band3=0;ul_start_ru3=5;ul_ru_size3=0
						;;
						"4") #USER4
							ul_sub_band4=0;ul_start_ru4=7;ul_ru_size4=0
						;;
					esac
				elif [ "$user_value" = "52" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=1
						;;
						"2") #USER2
							ul_sub_band2=0;ul_start_ru2=2;ul_ru_size2=1
						;;
						"3") #USER3
							ul_sub_band3=0;ul_start_ru3=5;ul_ru_size3=1
						;;
						"4") #USER4
							ul_sub_band4=0;ul_start_ru4=7;ul_ru_size4=1
						;;
					esac
				elif [ "$user_value" = "106" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=2
						;;
						"2") #USER2
							ul_sub_band2=0;ul_start_ru2=5;ul_ru_size2=2
						;;
						"3") #USER3
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,490"
							return
						;;
						"4") #USER4
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,491"
							return
						;;
					esac
				elif [ "$user_value" = "242" ]; then
					case "$user_index" in
						"1") #USER1
							ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3
						;;
						"2") #USER2
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,492"
							return
						;;
						"3") #USER3
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,493"
							return
						;;
						"4") #USER4
							error_print "cannot set user${user_index} with ru=${user_value}"
							send_invalid ",errorCode,494"
							return
						;;
					esac
				elif [ "$user_value" = "484" ]; then
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,495"
					return
				else
					error_print "cannot set user${user_index} with ru=${user_value}"
					send_invalid ",errorCode,496"
					return
				fi
			else
				error_print "Unsupported value - start_bw_limit:$start_bw_limit"
				send_invalid ",errorCode,497"
				return
			fi
		done

		# user_index contains the number of users. set it to DB to be used by static plan.
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_num_of_participating_stations_idx}=${user_index}

		# update per-user params in DB, per number of users
		#for index in $user_index
		for index in 1 2 3 4 
		do
			local tmp_param tmp_val
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			
			tmp_param="ul_sub_band${index}";eval tmp_val=\$$tmp_param		
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${rcr_tf_usr_sub_band_idx}=${tmp_val}
			
			tmp_param="ul_start_ru${index}";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${rcr_tf_usr_start_ru_idx}=${tmp_val}
			
			tmp_param="ul_ru_size${index}";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${index} x${rcr_tf_usr_ru_size_idx}=${tmp_val}
		done

		[ "$ap_type" != "EHT" ] && refresh_static_plan
	fi

	if [ "$ap_type" = "EHT" ] && [ -n "$ap_acpref" ]; then
		debug_print "Sending ML_BSS_CRITICAL_UPDATE in the hostapd_cli command"
		if [ "$ap_cohosted_bss_idx" = "2" ] || [ "$ap_non_tx_bss_idx" != "" ]; then
			ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.1 ML_BSS_CRITICAL_UPDATE`
		else
			ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_WLAN_NAME.0 ML_BSS_CRITICAL_UPDATE`
		fi
	fi

	if [ "$ap_type" = "EHT" ] && [ "$ap_num_ss" != "" -a "$ap_num_ss_mac" != "" ]; then
		nof_entries=`echo "$ap_num_ss" | awk -F" " '{print NF}'`
		ap_num_ss=`echo "$ap_num_ss" | tr -d ' '`
		count=1
		while [ "$count" -le "$nof_entries" ]
		do
			j=$((count-1))
			tmp_mac=`echo $ap_num_ss_mac | awk -v p="$count" '{ print $p }'`
			aid=`cat /proc/net/mtlk/$CURRENT_WLAN_NAME.0/sta_list | grep ":" | grep -iF "$tmp_mac" | awk '{print $5}'`
			tmp_sid=$((aid-64))
			eval ap_num_ss_${tmp_sid}="${ap_num_ss:j:1}"
			count=$((count+1))
		done
	fi

	if [ "$ap_type" = "EHT" ] && [ "$glob_ofdma_phase_format" != "" ]; then
		[ "$ML_VAP1" = "5G" ] && refresh_static_plan_for_eht $CURRENT_6G_WLAN_NAME $CURRENT_6G_RADIO_UCI_PATH
		refresh_static_plan_for_eht $CURRENT_5G_WLAN_NAME $CURRENT_5G_RADIO_UCI_PATH
		[ "$ML_VAP1" = "24G" ] && refresh_static_plan_for_eht $CURRENT_24G_WLAN_NAME $CURRENT_24G_RADIO_UCI_PATH

	if [ "$global_emlsr_tb_ul_ofdma" = "1" ]; then
		[ "$ML_VAP1" = "5G" ] && CURRENT_INTERFACE_1="$CURRENT_6G_WLAN_NAME.0"
		[ "$ML_VAP1" = "24G" ] && CURRENT_INTERFACE_1="$CURRENT_24G_WLAN_NAME.0"
		CURRENT_INTERFACE_2="$CURRENT_5G_WLAN_NAME.0"
		/lib/netifd/sigmaManagerDaemon.sh $CURRENT_INTERFACE_1 0 $global_emlsr_tb_ul_ofdma $CURRENT_INTERFACE_2 $CURRENT_5G_WLAN_NAME &
	fi

	fi

	#For WLANRTSYS-55649 TCs HE-4.40.4 and HE-4.64.1 this is a workaround where we introduce a delay after configuring he APUT to send trigger frame.
	#This is required Cypress and Broadcom clients as they are TXing only S-MPDU and not aggregating.
	#5 second delay is required as it is tried and tested
	if [ "$MODEL" = "WAV700_AP" ] && ([ "$glob_ssid" = "HE-4.40.4" ] || [ "$glob_ssid" = "HE-4.64.1" ]); then
		sleep 5
	fi

	send_complete
}

dev_send_frame()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				ap_name=$1
			;;
			INTERFACE)
				# skip as it is determined in get_interface_details
			;;
			WLAN_TAG)
				# skip as it is determined in get_interface_details
			;;
			DEST_MAC)
				ap_dest_mac=$1
			;;
			PROGRAM)
				# do nothing
			;;
			FRAMENAME)
				ap_frame_name=$1
			;;
			CAND_LIST)
				ap_cand_list=$1
			;;
			BTMQUERY_REASON_CODE)
				ap_btmquery_reason_code=$1
			;;
			DISASSOC_TIMER)
				ap_disassoc_timer=$1
			;;
			MEAMODE)
				lower $1 ap_meamode
			;;
			REGCLASS)
				ap_regclass=$1
			;;
			CHANNEL)
				ap_channel=$1
			;;
			RANDINT)
				ap_randint=$1
			;;
			MEADUR)
				ap_meadur=$1
			;;
			SSID)
				ap_ssid=$1
			;;
			RPTCOND)
				ap_rptcond=$1
			;;
			RPTDET)
				ap_rpt_det=$1
			;;
			MEADURMAND)
				ap_meadurmand=$1
			;;
			APCHANRPT)
				ap_apchanrpt=$1
			;;
			REQINFO)
				ap_reqinfo=$1
			;;
			REQUEST_MODE)
			lower "$1" ap_request_mode
			if [ "$ap_request_mode" = "disassoc" ] && [ "$ucc_program" != "eht" ]; then
				BTM_DISASSOC_IMMITIENT=1
			fi
			;;
			LASTBEACONRPTINDICATION)
				ap_lastbeaconrptindication=$1
			;;
			BSSID)
				ap_bssid=$1
			;;
			INTERVAL)
				frame_duration=$1
			;;
			PROTECTED)
				if [ "$1" = "Unprotected" ]; then
					frame_protected=0
				elif [ "$1" = "CorrectKey" ]; then
					frame_protected=1
					frame_key=1
				elif [ "$1" = "IncorrectKey" ]; then
					frame_protected=1
					frame_key=0
				fi
			;;
			STATIONID)
				station_id=$1
			;;
			STA_MLD)
				sta_mld=$1
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,500"
				return
			;;
		esac
		shift
	done

	case "$ap_frame_name" in
		BcnRptReq)
			ap_beacon_req_params=""

			# ap_dest_mac + num_of_repetitions + measurement_request_mode
			ap_beacon_req_params=$ap_beacon_req_params" $ap_dest_mac 0 0"

			if [ "$ap_regclass" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" $ap_regclass"
			else
				ap_curr_band=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.band`
				if [ "$ap_curr_band" = "5GHz" ]; then
					ap_beacon_req_params=$ap_beacon_req_params" 115"
				else
					ap_beacon_req_params=$ap_beacon_req_params" 81"
				fi
			fi

			if [ "$ap_channel" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" $ap_channel"
			else
				ap_beacon_req_params=$ap_beacon_req_params" 255"
			fi

			if [ "$ap_randint" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" $ap_randint"
			else
				ap_beacon_req_params=$ap_beacon_req_params" 0"
			fi

			if [ "$ap_meadur" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" $ap_meadur"
			else
				ap_beacon_req_params=$ap_beacon_req_params" 20"
			fi

			if [ "$ap_meamode" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" $ap_meamode"
			else
				ap_beacon_req_params=$ap_beacon_req_params" active"
			fi

			if [ "$ap_bssid" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" $ap_bssid"
			else
				ap_beacon_req_params=$ap_beacon_req_params" ff:ff:ff:ff:ff:ff"
			fi

			# the remaining parameters are optional
			if [ "$ap_ssid" != "" -a "$ap_ssid" != "ZeroLength" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" ssid='\"$ap_ssid\"'"
			fi

			if [ "$ap_rpt_det" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" rep_detail=$ap_rpt_det"
			fi

			if [ "$ap_rptcond" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" rep_cond=$ap_rptcond"
			fi

			if [ "$ap_lastbeaconrptindication" != "" ]; then
				ap_beacon_req_params=$ap_beacon_req_params" last_indication=$ap_lastbeaconrptindication"
			fi

			if [ "$ap_apchanrpt" != "" ]; then
				# replace all "_" with "," in received string
				ap_apchanrpt_param="${ap_apchanrpt//_/,}"
				ap_beacon_req_params=$ap_beacon_req_params" ap_ch_report=$ap_apchanrpt_param"
			fi

			if [ "$ap_reqinfo" != "" ]; then
				# replace all "_" with "," in received string
				ap_reqinfo_param="${ap_reqinfo//_/,}"
				ap_beacon_req_params=$ap_beacon_req_params" req_elements=$ap_reqinfo_param"
			fi

			ap_all_ifaces=`uci show wireless | grep ifname | awk -F"=" '{print $2}' | awk -v RS=  '{$1=$1}1' | tr -d "'"`
			IFS=$ORIG_IFS
			for ap_curr_iface in $ap_all_ifaces; do
				ap_res=`iw dev $ap_curr_iface station dump | grep $ap_dest_mac`
				if [ "$ap_res" != "" ]; then
					ap_send_iface=$ap_curr_iface
					break
				fi
			done

			if [ "$ap_send_iface" != "" ]; then
				CURRENT_IFACE_IFNAME=$ap_send_iface
			fi

			debug_print "$HOSTAPD_CLI_CMD -i$CURRENT_IFACE_IFNAME REQ_BEACON $ap_beacon_req_params"
			ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_IFACE_IFNAME REQ_BEACON "$ap_beacon_req_params"`
		;;
		BTMReq)
			debug_print BTMReq
			sleep 1 #WA if WNM notify received late
			ap_cmd="$HOSTAPD_CLI_CMD -i$CURRENT_IFACE_IFNAME BSS_TM_REQ $ap_dest_mac"

			if [ "$ap_cand_list" != "" ]; then
				ap_cmd="$ap_cmd pref=$ap_cand_list"
			fi

			CURRENT_NEIGHBORS=`cat /tmp/mbo_neighbors`
			if [ "$CURRENT_NEIGHBORS" != "" ]; then
				tc_id=`check_for_btm_test_cases`
				if [ "$ucc_type" = "testbed" ] && [ "$tc_id" = "556" ]; then
					remove_neighbor_for_channel $btm_other_channel
				fi
				ap_cmd="$ap_cmd $CURRENT_NEIGHBORS"
			elif [ "$ap_cand_list" != "" ]; then
				ap_self_mac=`$UCI_CMD get $CURRENT_IFACE_UCI_PATH.macaddr`
				ap_band=`$UCI_CMD get $CURRENT_RADIO_UCI_PATH.band`
				if [ "$ap_band" = "5GHz" ]; then
					ap_op_class=73
					ap_op_chan=36
				elif [ "$ap_band" = "2.4GHz" ]; then
					ap_op_class=51
					ap_op_chan=1
				elif [ "$ap_band" = "6GHz" ]; then
					ap_op_class=131
					ap_op_chan=37
				fi
				ap_cmd="$ap_cmd neighbor=${ap_self_mac},0,${ap_op_class},${ap_op_chan},9,0"
			fi

			if [ "${BTM_DISASSOC_IMMITIENT}" != "" ]; then
				ap_cmd="$ap_cmd disassoc_imminent=${BTM_DISASSOC_IMMITIENT}"
			fi

			if [ "${BTM_LINK_REMOVAL_IMMINENT}" != "" ]; then
				ap_cmd="$ap_cmd link_removal_imminent=${BTM_LINK_REMOVAL_IMMINENT}"
			fi

			if [ "$ap_disassoc_timer" != "" ]; then
				ap_cmd="$ap_cmd disassoc_timer=$ap_disassoc_timer"
			elif [ "$BTM_DISASSOC_IMMITIENT" = "1" ]; then
				ap_cmd="$ap_cmd disassoc_timer=5"
			fi

			if [ "$BTM_BSS_TERM_BIT" = "1" ]; then
				ap_cmd="$ap_cmd disassoc_timer=$BTM_BSS_TERM_TSF bss_term=${BTM_BSS_TERM_TSF},${BTM_BSS_TERM_DURATION}"
			fi

			if [ "$BTM_REASSOC_DELAY" = "" ]; then
				BTM_REASSOC_DELAY=0
			fi

			ap_cell=`$UCI_CMD get ${CURRENT_IFACE_UCI_PATH}.mbo_cell_aware`
			if [ "$ap_cell" = "1" ]; then
				ap_mbo_cell="1"
			else
				ap_mbo_cell="-1"
			fi

			if [ "$ucc_program" = "eht" ] && [ "$ap_btmquery_reason_code" = "0" ]; then
				ap_cmd="$ap_cmd mbo=0:${BTM_REASSOC_DELAY}:${ap_mbo_cell}"
			else
				ap_cmd="$ap_cmd mbo=4:${BTM_REASSOC_DELAY}:${ap_mbo_cell}"
			fi
			debug_print "$ap_cmd"

			if [ "$BTM_DISASSOC_IMMITIENT" = "1" ]; then
				ap_cmd=`echo $ap_cmd | sed 's/wlan[0-9].0/wlan0.0/'`
				ap_tmp=`eval "$ap_cmd"`
				ap_cmd=`echo $ap_cmd | sed 's/wlan[0-9].0/wlan2.0/'`
				ap_tmp=`eval "$ap_cmd"`
				ap_cmd=`echo $ap_cmd | sed 's/wlan[0-9].0/wlan4.0/'`
				ap_tmp=`eval "$ap_cmd"`
			else
				ap_tmp=`eval "$ap_cmd"`
			fi

			if [ "$BTM_BSS_TERM_DURATION" != "" ] && [ "$BTM_BSS_TERM_TSF" != "" ]
			then
				ap_filename="/lib/netifd/terminate_radio_after.sh"
				debug_print "$ap_filename $CURRENT_WLAN_NAME $BTM_BSS_TERM_TSF $BTM_BSS_TERM_DURATION"
				$ap_filename $CURRENT_WLAN_NAME $BTM_BSS_TERM_TSF $BTM_BSS_TERM_DURATION &
			fi

			BTM_REASSOC_DELAY=""

			if [ "$ucc_program" != "eht" ]; then
				ap_tmp_chan=`$UCI_CMD get ${CURRENT_RADIO_UCI_PATH}.channel`
				remove_neighbor_for_channel $ap_tmp_chan
			fi

		;;
		disassoc)
			debug_print $HOSTAPD_CLI_CMD -i$CURRENT_IFACE_IFNAME DISASSOCIATE $CURRENT_IFACE_IFNAME $ap_dest_mac
			ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_IFACE_IFNAME DISASSOCIATE $CURRENT_IFACE_IFNAME $ap_dest_mac`
		;;
		MsntPilot)
			local current_frame
			current_frame=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 get_unsolicited_frame_support`
			ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME set_unsolicited_frame_duration $frame_duration`
			if [ "$current_frame" = "0" ]; then
				ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME set_unsolicited_frame_support 2`
			fi
		;;
		deauth)
			if [ "$frame_protected" = "0" ]; then #unprotected deauth
				ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 set_unprotected_deauth 1`
				ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 DEAUTHENTICATE $ap_wlan_6g_name.0 $station_id test=0`
				ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 set_unprotected_deauth 0`
			else
				if [ "$frame_key" = "1" ]; then #protected with correct key deauth
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 deauthenticate $ap_wlan_6g_name.0 $station_id`
				else #protected with incorrect key deauth
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 set_pn_reset 0`
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 set_incorrect_pn $station_id`
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 deauthenticate $ap_wlan_6g_name.0 $station_id test=0`
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 set_correct_pn $station_id`
					ap_tmp=`eval $HOSTAPD_CLI_CMD -i $CURRENT_WLAN_NAME.0 set_pn_reset 1`
				fi
			fi
		;;
		T2LMTeardown)
			debug_print $HOSTAPD_CLI_CMD -i$CURRENT_IFACE_IFNAME SEND_T2LM_TEARDOWN_FRAME $CURRENT_IFACE_IFNAME $ap_dest_mac
			ap_tmp=`eval $HOSTAPD_CLI_CMD -i$CURRENT_IFACE_IFNAME SEND_T2LM_TEARDOWN_FRAME $CURRENT_IFACE_IFNAME $ap_dest_mac`
		;;
		*)
			error_print "not supported frame_name $ap_frame_name"
			send_invalid ",errorCode,500"
			return
		;;
	esac

	send_complete
}

ap_reboot()
{
	send_running
	reboot
	send_complete
}

check_and_update_dc_registration()
{
	local total_vaps=`cat /proc/ppa/api/netif | grep phys_netif_name | grep -c wlan`
	local dc_enabled=`cat /proc/ppa/api/netif | grep -c NETIF_DIRECTCONNECT`
	local vaps=`cat /proc/ppa/api/netif | grep phys_netif_name | grep  wlan | cut -d = -f2`
	if [ $total_vaps -ne $dc_enabled ]; then
		for vap in $vaps
		do
			local ap_tmp=`eval ppacmd dellan -i $vap`
			ap_tmp=`eval ppacmd addlan -i $vap`
		done
		debug_print "Applied WA for ARP issue"
	fi
}

check_bridge_status()
{
	local vap_count=`uci show wireless | grep ifname | grep -c wlan`
	local vaps=`uci show wireless | grep ifname | cut -d"=" -f2 | tr -d "'"`
	local num_vaps_in_bridge=`brctl show br-lan | grep -c wlan`
	if [ $num_vaps_in_bridge -ne $vap_count ]; then
		for vap in $vaps
		do
			local in_bridge=`brctl show br-lan | grep -c $vap$`
			if [ "$in_bridge" = "0" ]; then
				debug_print "$vap missing in bridge, adding it"
				ap_tmp=`eval brctl addif br-lan $vap`
			fi
		done
	fi
}

refresh_unsolicited_frame_support()
{
	interfaces=`ls /var/run/hostapd | cut -d"." -f1 | grep -v global-hostapd`
	interfaces=`echo $interfaces | awk '{for (i=1;i<=NF;i++) if (!a[$i]++) printf("%s%s",$i,FS)}{printf(" ")}'`
	for i in $interfaces
	do
	cf1=`eval $HOSTAPD_CLI_CMD -i$i radio | grep Cf1`
	cf1=`echo $cf1 | cut -d"=" -f2`
	if [ $cf1 -gt 5900 ]; then #center freq for 6Ghz must be above 59**
		interface_6g=$i
		break
	fi
	done
	cur_frame=`eval $HOSTAPD_CLI_CMD -i $interface_6g get_unsolicited_frame_support`
	ap_tmp=`eval $HOSTAPD_CLI_CMD -i $interface_6g set_unsolicited_frame_support $cur_frame`
}

uci_set_for_all_radio()
{
    config_list="$1"
    radio_ifaces=`uci show wireless | grep "wifi-device" | grep ".radio[0-4]" | cut -d '=' -f 1`
    for radios in $radio_ifaces; do
        for configs in $config_list; do
            $UCI_CMD set $radios.$configs
        done
    done
}

disable_dynamic_ofdma_all_radios()
{
    radio_list="sDynamicMuTypeDownLink=0 sDynamicMuTypeUpLink=0 sDynamicMuMinStationsInGroup=4 \
                      sDynamicMuMaxStationsInGroup=4 sDynamicMuCdbConfig=0"

    uci_set_for_all_radio "$radio_list"
}

ap_config_commit()
 {
	if [ "$ucc_program" = "eht" ] && [ "$global_ap_mbssid" != "" -o "$global_ap_cohosted_bss" != "" ]; then
		$UCI_CMD set wireless.default_radio10.dtim_period=1
		$UCI_CMD set wireless.default_radio42.dtim_period=1
		$UCI_CMD set wireless.default_radio74.dtim_period=1
		$UCI_CMD set wireless.default_radio11.dtim_period=1
		$UCI_CMD set wireless.default_radio43.dtim_period=1
		$UCI_CMD set wireless.default_radio75.dtim_period=1
	fi
	send_running

	#In case RADIO off received earlier and interfaces were removed from ifconfig, add it back
	if [ "$ucc_program" != "eht" ]; then
		ap_radio_ifaces=`uci show wireless | grep ifname | awk -F"=" '{print $2}'`
		for ap_radio_iface in $ap_radio_ifaces; do
			res=`eval ifconfig $ap_radio_iface up`
		done
	fi

	# Disable Dynamic OFDMA
	disable_dynamic_ofdma_all_radios

	ap_uci_commit_and_apply

	[ -e "/tmp/wlan_debug" ] && hostapd_cli -iwlan0 log_level DEBUG

	local verify_up=`verify_interfaces_up`
	if [ $verify_up -eq 1 ]
	then
		if [ -z "$radio_6ghz_disabled" ]; then #in case 6ghz disabled, proceed further
			error_print "Interfaces are not up after commit"
			send_invalid ",errorCode,220"
			return
		fi
		radio_6ghz_disabled=""
	fi
	if [ "$OS_NAME" = "UGW" ]; then
		check_and_update_dc_registration
		check_bridge_status
	fi
	
	if [ "$ucc_program" = "eht" ]; then
		#Fixing the frame retries limit
		debug_print "Setting the frame retry limit to 14 for all the VAPs"
		iw $CURRENT_24G_WLAN_NAME iwlwav sTxRetryLimit 14 14
		iw $CURRENT_5G_WLAN_NAME iwlwav sTxRetryLimit 14 14
		iw $CURRENT_6G_WLAN_NAME iwlwav sTxRetryLimit 14 14

		# To enable Group Addressed Data Frame, disable reliable multicast
		iw dev $CURRENT_24G_WLAN_NAME.0 iwlwav sReliableMcast 0
		iw dev $CURRENT_5G_WLAN_NAME.0 iwlwav sReliableMcast 0
		iw dev $CURRENT_6G_WLAN_NAME.0 iwlwav sReliableMcast 0
	fi

	#This is a workaround for WLANRTSYS-54149 where ager was flushing out PDs which dint get air time
	#hence disabling ager for 24G
	#Note: sleep is required for the cmd to get reflected
	if [ "$MODEL" = "WAV700_AP" ] && [ "$glob_ssid" = "HE-4.62.1_24G" ]; then
		iw dev wlan0 iwlwav sDoSimpleCLI 126 0
		sleep 2
	fi

	#This is a workaround for WLANRTSYS-54149 where BAs were not being sent out from AP and hence STA was deauthenticating
	#Hence disabling BA for wlan2 with cmd iw dev wlan2 iwlwav sAggrConfig 1 0 256
	#Note: We are giving the cmd 3 times for it to get reflected
	if [ "$MODEL" = "WAV700_AP" ] && [ "$glob_ssid" = "VHT-4.2.51" ]; then
			iw dev wlan2 iwlwav sAggrConfig 1 0 256
			sleep 1
			iw dev wlan2 iwlwav sAggrConfig 1 0 256
			sleep 1
			iw dev wlan2 iwlwav sAggrConfig 1 0 256
			sleep 1
	fi

	#This is a workaround for WLANRTSYS-59566 where in 4.28.1_RUN1 TC Intel-L is not acking the packets sent from the AP with NSS 2 and MCS 9 after exiting the EMLSR mode.
	#When enabling protection, Intel-L STA is acking the packets sent by the AP. Enabling protection as a workaround for 4.28.1_RUN1 TC.
	if [ "$ucc_program" = "eht" ] && [ "$ucc_type" = "dut" ] && [ "$global_ap_tx_omn_resp_disable" = "1" ] && [ "$global_ap_ul_ofdma" = "" ] && [ "$ML_VAP1" != "" ] && [ "$ML_VAP2" != "" ]; then
		if [ "$ML_VAP1" = "24G" ] && [ "$ML_VAP2" = "5G" ]; then
			iw dev $CURRENT_24G_WLAN_NAME.0 iwlwav s11nProtection 2
			iw dev $CURRENT_5G_WLAN_NAME.0 iwlwav s11nProtection 2
		fi
	fi

	#This is a workaround for WLANRTSYS-62397 where in HE-4.5.3_5G TC ping fails for Marvell station.
	#By disabling prplmesh, ping is successful for Marvell station, hence disabling prplmesh.
	/etc/init.d/prplmesh stop

	send_complete
}
ap_common_reset_default()
{
	if [ "$ucc_program" = "eht" ]; then
		if [ "$1" = "eht" ] && [ -f $DEFAULT_DB_PATH/$ucc_program/factory ]; then
    		debug_print "File:$DEFAULT_DB_PATH/$ucc_program/factory exist copy it"
			ap_tmp=`eval md5sum $UCI_DB_PATH/wireless`
			#Check the version of /etc/config/wireless in case of DUT/EHT
			if [ "$ap_tmp" != "c99c41209a65fc0edd42302f09f159d3" ]; then
		  		ap_tmp=`cp $DEFAULT_DB_PATH/$ucc_program/factory $UCI_DB_PATH/wireless`
			fi
		elif [ "$1" = "eht_testbed" ] && [ -f $DEFAULT_DB_PATH/eht_testbed/factory ]; then
			debug_print "File:$DEFAULT_DB_PATH/${ucc_program}_testbed/factory exist copy it"
			ap_tmp=`eval md5sum $UCI_DB_PATH/wireless`
			#Check the version of /etc/config/wireless in case of Testbed/EHT_Testbed
			if [ "$ap_tmp" != "e2ae5e31cb8fd71daeac559210921ee1" ]; then
				ap_tmp=`cp $DEFAULT_DB_PATH/eht_testbed/factory $UCI_DB_PATH/wireless`
			fi
		else
    		debug_print "File:$DEFAULT_DB_PATH/$ucc_program/factory not exist create it"
       		if [ "$OS_NAME" = "UGW" ]; then
        		ap_tmp=`eval /etc/init.d/servd stop`
           		ap_tmp=`eval /etc/init.d/servd disable`
       		fi
       		$FACTORY_CMD -p $1
       		[ "$1" = "eht" ] && ap_tmp=`cp $UCI_DB_PATH/wireless $DEFAULT_DB_PATH/$ucc_program/factory`
			[ "$1" = "eht_testbed" ] && ap_tmp=`cp $UCI_DB_PATH/wireless $DEFAULT_DB_PATH/eht_testbed/factory`
		fi	
   	fi
    
	[ "$ucc_program" != "eht" ] && $FACTORY_CMD -p $1
	#CGR interface doesnt restart, forceful restart
    if [ "$OS_NAME" = "RDKB" ]; then
    	ap_tmp=`systemctl restart systemd-netifd.service`
		sleep 15
    fi
	debug_print "clearing all global_ variables"
	local variables=`set | grep "^global_" | cut -d= -f1 | xargs echo `

	for var in $variables; do
		#debug_print "clearing globals $var"
		unset ${var}
	done

	if [ "$MODEL" != "AX11000" ] && [ "$MODEL" != "WAV700_AP" ] && [ "$OS_NAME" = "UGW" ]; then
		chown rpcd:rpcd $UCI_DB_PATH/wireless
		chmod +r $UCI_DB_PATH/wireless
	fi

	$UCI_CMD set wireless.default_radio$ap_uci_24g_idx.ssid="$1_ssid_24g"
	$UCI_CMD set wireless.default_radio$ap_uci_5g_idx.ssid="$1_ssid_5g"
	$UCI_CMD set wireless.default_radio$ap_uci_6g_idx.ssid="$1_ssid_6g"

	# Disable Dynamic EDCA for all radios, 6g is optional
	$UCI_CMD set $ap_radio_24g_uci_path.dynamic_edca='0'
	$UCI_CMD set $ap_radio_5g_uci_path.dynamic_edca='0'
	[ -n "$ap_radio_6g_uci_path" ] && $UCI_CMD set $ap_radio_6g_uci_path.dynamic_edca='0'

	# Disable AutoCoC for all radios, 6g is optional
	$UCI_CMD set $ap_radio_24g_uci_path.sCoCPower='0'
	$UCI_CMD set $ap_radio_5g_uci_path.sCoCPower='0'
	[ -n "$ap_radio_6g_uci_path" ] && $UCI_CMD set $ap_radio_6g_uci_path.sCoCPower='0'

	if [ "$ucc_program" = "he" ] || [ "$ucc_program" = "eht" ]; then
		randomize_macs
	fi

	BASE_TAG_6G=""
	BASE_TAG_5G=""
	BASE_TAG_24G=""
}

ap_mbo_reset_default_var()
{
	CURRENT_NEIGHBORS=""
	CURRENT_NON_PREF_NEIGHBORS=""
	BTM_DISASSOC_IMMITIENT=""
	BTM_REASSOC_DELAY=""
	BTM_BSS_TERM_BIT=""
	BTM_BSS_TERM_DURATION=""

	cat /dev/null > /tmp/mbo_neighbors
	cat /dev/null > /tmp/non_pref_mbo_neighbors
	kill_sigma_mbo_daemon
	/lib/netifd/sigma_mbo_daemon.sh &

}
ap_mbo_reset_default()
{
	ap_common_reset_default mbo
	ap_mbo_reset_default_var
}

ap_he_reset_default()
{
	# HE includes 6G
	ap_common_reset_default he
    ap_mbo_reset_default_var
}

ap_eht_reset_default()
{
	ap_common_reset_default eht
	ap_mbo_reset_default_var
}

ap_he_testbed_reset_default()
{
	# HE includes 6G
	ap_common_reset_default he_testbed
    ap_mbo_reset_default_var
}

ap_eht_testbed_reset_default()
{
        ap_common_reset_default eht_testbed
    	ap_mbo_reset_default_var
}


ap_11n_reset_default()
{
	ap_common_reset_default 11n
}

ap_vht_reset_default()
{
	ap_common_reset_default vht

	CONFIGURE_BOTH_BANDS=0
}

ap_wpa2_reset_default()
{
	ap_common_reset_default wpa2
}

ap_wpa3_reset_default()
{
	ap_common_reset_default wpa3
}

ap_pmf_reset_default()
{
	ap_common_reset_default pmf
}

ap_reset_default()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	ucc_program=""
	ucc_type=""

	kill_sigmaManagerDaemon

	while [ "$1" != "" ]; do
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				ap_name=$1
			;;
			PROGRAM)
				lower "$1" ucc_program
			;;
			PROG)
				lower "$1" ucc_program
			;;	
			TYPE)
				lower "$1" ucc_type
			;;
			RUNTIME_ID)
				ap_runtime_id=$1
			;;
			*)
			;;
		esac
		shift
	done

	info_print "##### PROGRAM:$ucc_program TYPE:$ucc_type AP_NAME:$ap_name #####"

	if [ "$ucc_type" != "" ] && [ "$ucc_type" != "dut" ] && [ "$ucc_type" != "testbed" ]; then
		error_print "Unsupported ucc type - $ucc_type"
		send_invalid ",errorCode,610"
		return
	fi

	if [ "$MODEL" = "RDKB" ]; then
		if [ $nof_interfaces -ge 3 ]; then
			echo "y" > /tmp/y
			ap_tmp=`overlay.sh create < /tmp/y`
			# TODO: check if raio_map_file need to be copied
			ap_tmp=`cp -u $DEFAULT_DB_PATH/cgr/radio_map_file $DEFAULT_DB_PATH/$ucc_program/`
			ap_tmp=`cp -u $DEFAULT_DB_PATH/he/wireless_def_radio_6g $DEFAULT_DB_PATH/$ucc_program/`
			ap_tmp=`cp -u $DEFAULT_DB_PATH/he/wireless_def_vap_db_6g $DEFAULT_DB_PATH/$ucc_program/`
			ap_tmp=`cp $DEFAULT_DB_PATH/he/defaults $DEFAULT_DB_PATH/$ucc_program/`
		fi
	fi
	if [ "$ucc_program" = "mbo" ]; then
		ap_mbo_reset_default
	elif [ "$ucc_program" = "he" ]; then
		if [ "$ucc_type" = "testbed" ]; then
			ap_he_testbed_reset_default
		else
			ap_he_reset_default
		fi
	elif [ "$ucc_program" = "11n" ] || [ "$ucc_program" = "ffd" ]; then
		ap_11n_reset_default
	elif [ "$ucc_program" = "vht" ]; then
		ap_vht_reset_default
	elif [ "$ucc_program" = "wpa2" ]; then
		ap_wpa2_reset_default
	elif [ "$ucc_program" = "wpa3" ]; then
		ap_wpa3_reset_default
	elif [ "$ucc_program" = "pmf" ]; then
		ap_pmf_reset_default
	elif [ "$ucc_program" = "eht" ]; then
		[ "$ap_runtime_id" = "" ] && force_ap_cleanup
		if [ "$ucc_type" = "dut" ]; then
			ap_eht_reset_default
		else
			ap_eht_testbed_reset_default
		fi
		if [ "$ap_runtime_id" != "" ]; then
			if [ -e "/tmp/wlan_debug" ]; then
				echo 8 cdebug=1 > /proc/net/mtlk_log/debug
			fi
			rm -rf ${TMP_PATH}/logread_logs.txt
			logread -f > ${TMP_PATH}/logread_logs.txt &
			killall hostapd
			sleep 10
			iw dev wlan0 iwlwav sFWRecovery 1 0 25 1 300
		fi
		rm -f $FORCE_EHT_FIXED_RATE_CFG_FILE_PATH
	else
		error_print "Unsupported ucc program - $ucc_program"
		send_invalid ",errorCode,610"
		return
	fi

	debug_print "Clearing CURRENT_WLAN_TAG variables"
	unset CURRENT_WLAN_TAG1
	unset CURRENT_WLAN_TAG2

	#NO need to wait for the interfaces to be up on Factory Reset
	if [ "$ucc_program" != "eht" ]; then
		local verify_up=`verify_interfaces_up`
		if [ $verify_up -eq 1 ]
		then
			error_print "Interfaces are not up after reset_default"
			#Won't harm if we continue
		fi
	fi	

	#make sure re-enable tx
	iw wlan0 iwlwav sEnableRadio 1
	iw wlan2 iwlwav sEnableRadio 1
	if [ "1" = `is_6g_supported` ]; then
		iw wlan4 iwlwav sEnableRadio 1
	fi

	#Sending the Operation type either APUT or TB to the FW
	if [ "$ucc_program" = "eht" ]; then
		kill_sigmaManagerDaemon_static
		kill_sigmaManagerDaemon
		if [ "$ucc_type" = "dut" ]; then
			ap_oper_type=1
		elif [ "$ucc_type" = "testbed" ]; then
			ap_oper_type=2
		else
			ap_oper_type=0
		fi
		iw dev wlan0 iwlwav sDoSimpleCLI 129 $ap_oper_type
		iw dev wlan2 iwlwav sDoSimpleCLI 129 $ap_oper_type
		iw dev wlan4 iwlwav sDoSimpleCLI 129 $ap_oper_type

		#Disable synchronous link switch config in FW
		iw dev wlan0 iwlwav sDoSimpleCLI 151 0
	fi

	send_complete
}

ap_get_info()
{
	send_running
	#answer=need to see what info need to be returned
	send_complete "$answer"
}

ap_deauth_sta()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	get_common_uci_path
	get_interface_details $@

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "deauthenticate ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			STA_MAC_ADDRESS)
				debug_print "deauthenticate ap_sta_mac_address=$1"
			;;
			MINORCODE)
				debug_print "deauthenticate ap_minorcode=$1"
			;;
			*)
				error_print "while loop error $1"
				send_invalid ",errorCode,44"
				return
			;;
		esac
		shift
	done

	send_complete
}

ap_get_mac_address()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	ap_non_tx_index=0
	get_common_uci_path
	get_interface_details $@

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
			NAME)
				debug_print "set debug ap_name=$1"
			;;
			INTERFACE)
				# skip since it was read in loop before
			;;
			MLD_ID)
				debug_print "set parameter ap_mld_id=$1"
				ap_mld_id=$1
				[ "$ap_mld_id" = "2" ] && CURRENT_6G_IFACE_UCI_PATH=$CURRENT_6G_IFACE_UCI_PATH_2
			;;
			COHOSTEDBSSINDEX)
				debug_print "set parameter ap_cohosted_bss_index=$1"
				ap_cohosted_bss_index=$1
				[ "$ap_cohosted_bss_index" = "2" ] && CURRENT_IFACE_UCI_PATH=$CURRENT_IFACE_UCI_PATH_2
			;;
			esac
			shift
		done

	if [ "$ap_interface" = "mld" ]; then
		if [ "$ap_mld_id" = "" ]; then
			ap_get_debug_hostap_conf=`grep 'ap_mld_mac' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			ap_mld_mac_address=`$UCI_CMD get $CURRENT_5G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
			ap_mld_mac_address=${ap_mld_mac_address##*=}
			if [ "$ap_mld_mac_address" = "0" ] || [ "$ap_mld_mac_address" = "" ]; then
				ap_mld_mac_address=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
				ap_mld_mac_address=${ap_mld_mac_address##*=}
			fi
		else
			ap_get_debug_hostap_conf=`uci show wireless | grep debug_hostap | grep $CURRENT_6G_IFACE_UCI_PATH | grep ap_mld_mac | cut -d"." -f3 | cut -d"=" -f1`
			ap_mld_mac_address=`$UCI_CMD get $CURRENT_6G_IFACE_UCI_PATH.$ap_get_debug_hostap_conf`
			ap_mld_mac_address=${ap_mld_mac_address##*=}
		fi
		send_complete ",AP-MLD mac,$ap_mld_mac_address"
	else
		if [ "$ap_cohosted_bss_index" = "" ]; then
			ap_mac_index="${CURRENT_IFACE_UCI_PATH/wireless.default_radio}"
			ap_mac_index=$((ap_mac_index+ap_non_tx_index))

			ap_mac=`$UCI_CMD get wireless.default_radio$ap_mac_index.macaddr`
		else
			ap_mac=`$UCI_CMD get $CURRENT_IFACE_UCI_PATH.macaddr`
		fi
		send_complete ",mac,$ap_mac"
	fi
}

ap_get_parameter()
{
        ap_name="Maxlinear"
        IFS=$ORIG_IFS
        send_running
        get_common_uci_path
        while [ "$1" != "" ]; do
			# for upper case only
			upper "$1" token
			shift
			debug_print "while loop $1 - token:$token"
			case "$token" in
			NAME)
				debug_print "set parameter ap_name=$1"
			;;
			STA_MAC_ADDRESS)
				local sta_mac_addr=$1
				debug_print "set parameter sta_mac_addr=$1"
				lower "$1" sta_mac_addr
			;;
			PARAMETER)
				local param=$1
				debug_print "set parameter param=$1"
				lower "$1" param

				if [ "$param" = "pmk" ]; then
					if [ "$ucc_program" = "eht" ]; then
						local vaps=`uci show wireless | grep ifname | grep ${CURRENT_5G_WLAN_NAME/.0} | cut -d"=" -f2 |grep "\." | tr -d "'"`
						for interface_name in $vaps; do
							pmk=`eval $HOSTAPD_CLI_CMD -i$interface_name pmk | grep $sta_mac_addr | cut -d" " -f3`
							debug_print $pmk
							[ -n "$pmk" ] && break
						done
						if [ -z "$pmk" ]; then
							local vaps=`uci show wireless | grep ifname | grep ${CURRENT_6G_WLAN_NAME/.0} | cut -d"=" -f2 |grep "\." | tr -d "'"`
							for interface_name in $vaps; do
								pmk=`eval $HOSTAPD_CLI_CMD -i$interface_name pmk | grep $sta_mac_addr | cut -d" " -f3`
								debug_print $pmk
								[ -n "$pmk" ] && break
							done
							if [ -z "$pmk" ]; then
								vaps=`uci show wireless | grep ifname | grep ${CURRENT_24G_WLAN_NAME/.0} | cut -d"=" -f2 |grep "\." | tr -d "'"`
								for interface_name in $vaps; do
									pmk=`eval $HOSTAPD_CLI_CMD -i$interface_name pmk | grep $sta_mac_addr | cut -d" " -f3`
									debug_print $pmk
									[ -n "$pmk" ] && break
								done
							fi
						fi
					else
						count=0
						i=0
						debug_print "Number of non-tx VAP : $global_num_non_tx_bss"
						if [ $global_num_non_tx_bss ] && [ -n $global_num_non_tx_bss ]; then
							count=$global_num_non_tx_bss
						fi
						while [ $i -le $count ]
						do
							wlan_interface_name=$CURRENT_WLAN_NAME.$i
							local vaps=`uci show wireless | grep ifname | grep $wlan_interface_name | cut -d"=" -f2 |grep "\." | tr -d "'"`
							for interface_name in $vaps; do
								upper "$sta_mac_addr" sta_mac_addr_upper
								is_sta_connected=`dwpal_cli $wlan_interface_name peerlist | grep $sta_mac_addr_upper`
								if [ $is_sta_connected ]; then
									pmk=`eval $HOSTAPD_CLI_CMD -i$interface_name pmk | grep $sta_mac_addr | cut -d" " -f3`
									debug_print $pmk
									[ -n "$pmk" ] && break
								fi
							done
							i=$((i+1))
						done
					fi
				fi
            ;;
            esac
            shift
        done
        if [ -n "$pmk" ]; then
            send_complete ",pmk,$pmk"
        else
            send_error ",errorCode,120"
        fi
}

dev_configure_ie()
{
        ap_name="Maxlinear"
        IFS=$ORIG_IFS
        send_running
        get_common_uci_path
        while [ "$1" != "" ]; do
                # for upper case only
                upper "$1" token
                shift
                debug_print "while loop $1 - token:$token"
                case "$token" in
                INTERFACE)
                        debug_print "interface:$1"
                ;;
                IE_NAME)
                        debug_print "IE_name:$1"
                ;;
                CONTENTS)
                        debug_print "content:$1"
                        #get debug max index, then create next debug_hostapd_conf_index
                        wpa_idx=`uci show wireless | grep debug_hostap_conf | cut -d"=" -f 1 | cut -d"_" -f4 | tail -1`
                        let "wpa_idx=wpa_idx+1"
                        eval uci set wireless.default_radio$ap_uci_6g_idx.debug_hostap_conf_$wpa_idx='wpa_hex_buf=$1'

                ;;
                esac
                shift
        done
        send_complete
}

dev_upload_log()
{
	send_running

	while [ "$1" != "" ]; do
		# for upper case only
		upper "$1" token
		shift
		debug_print "while loop $1 - token:$token"
		case "$token" in
		FTP_UNAME)
			ap_ftp_uname=$1
		;;
		FTP_PWD)
			ap_ftp_pwd=$1
		;;
		FTP_PORT)
			ap_ftp_port=$1
		;;
		RUNTIME_ID)
			ap_run_id=$1
		;;
		esac
		shift
    done

	killall logread

	$LOG_CMD -cert
	ap_created_filename=${VENDOR}_AP_${WAVE_VERSION}_${ap_run_id}
	tar -czf $ap_created_filename.bin $TMP_LOGS_PATH

	ucc_ip=`netstat | grep 9000 | cut -d":" -f2 | awk '{print$2}' | tr -d ' '`
	#sleep to let the sigma fetch the Master PC IP using the netstat command
	sleep 5
	if [ "$ucc_ip" != "" ]; then
		ftpput $ucc_ip -P $ap_ftp_port $ap_created_filename.bin

		rm -f $ap_created_filename.bin
	else
		debug_print "Unable to find the UCC IP, hence storing the logs File in $TMP_PATH"
	fi
	if [ $glob_ap_driver_reload = 1 ]; then
		debug_print "Driver was reloaded..."
		debug_print "Restart dump and whm handlers..."
		/opt/intel/bin/dump_handler -i 0 -f /opt/intel/wave &
		sleep 2
		/opt/intel/bin/whm_handler -f /opt/intel/wave &
		sleep 2
	fi
	send_complete
}

device_get_info()
{
	ap_name="Maxlinear"
	IFS=$ORIG_IFS
	send_running

	# configure following values: vendor, model name, FW version
	send_complete ",vendor,$VENDOR,model,$MODEL,version,$WAVE_VERSION"
}

##### Parser #####

parse_command()
{
	#echo parsing,`eval $TIMESTAMP`
	lower "$1" cmd
	shift

	debug_print "running command: >>>$cmd<<<"
	$cmd "$@"
	local res=$?
	debug_print "result: $res"
	if [ $res != "0" ]; then
		send_invalid ",errorCode,46"
		error_print "Unknown command: >>>$cmd<<<"
		error_print "Supported commands:dev_upload_log"
		error_print "ap_ca_version, ca_get_version, ap_set_wireless, ap_set_11n_wireless, ap_set_security"
		error_print "ap_set_pmf, ap_set_statqos, ap_set_radius, ap_set_hs2, ap_reboot, ap_config_commit,"
		error_print "ap_reset_default, ap_get_info, ap_deauth_sta, ap_get_mac_address, ap_set_rfeature"
		error_print "ap_send_addba_req, dev_send_frame, device_get_info, ap_get_parameter, dev_exec_action"
	fi
	cmd=""
	return
}

############################################################## Planner and its functions ##############################################################
# Info is saved to a file and the file is sourced to be used.
sp_check_ldpc_support()
{
	local interface_name HOSTAPD_CLI_ALL_STA_FILE LDPC_SUPPORT_FILE \
	current_aid line ldpc

	interface_name=$1

	# Check for each STA if it supports LDPC or not and save to a file
	HOSTAPD_CLI_ALL_STA_FILE="/tmp/sigma-hostapd-cli-all-sta-conf"
	LDPC_SUPPORT_FILE="/tmp/sigma-ldpc-support-conf"
	rm -f $HOSTAPD_CLI_ALL_STA_FILE $LDPC_SUPPORT_FILE
	eval $HOSTAPD_CLI_CMD -i${interface_name} all_sta $interface_name > $HOSTAPD_CLI_ALL_STA_FILE
	while [ $? -ne 0 ]; do
		sleep 3
		eval $HOSTAPD_CLI_CMD -i${interface_name} all_sta $interface_name > $HOSTAPD_CLI_ALL_STA_FILE
	done 
	current_aid=0
	while read -r line || [[ -n "$line" ]]
	do
		# Find the aid of the current block
		if [ "${line##aid=}" != "$line" ]; then
			current_aid=${line##aid=}
			# The LDPC support bit appears in he_phy line
		elif [ "${line##he_phy=}" != "$line" ]; then
			ldpc=`echo $line | awk '{print $2}'`
			# bit#6 0x20 means STA supports LDPC
			ldpc="0x$ldpc"
			if [ "$((ldpc & 0x20))" != "0" ]; then
				ldpc=1
			else
				ldpc=0
			fi
			echo "ldpc_${current_aid}=${ldpc}" >> $LDPC_SUPPORT_FILE
		fi
	done < $HOSTAPD_CLI_ALL_STA_FILE

	# Save ldpc support information to be set
	[ -e $LDPC_SUPPORT_FILE ] && source $LDPC_SUPPORT_FILE
	[ "$DEBUGGING" = "1" ] && [ -e $LDPC_SUPPORT_FILE ] && cat $LDPC_SUPPORT_FILE > /dev/console
}

get_max_nss()
{
	local interface_name MAX_NSS_FILE max_nss nss

	interface_name=$1

	MAX_NSS_FILE="/tmp/sigma-max-nss-file"
	rm -f $MAX_NSS_FILE
	max_nss=-1

	cat /proc/net/mtlk/$interface_name/sta_list | awk '{print $13}' > $MAX_NSS_FILE
	sed -i 's/|//' $MAX_NSS_FILE
	while read -r line || [[ -n "$line" ]]
	do
		[ -z "$line" ] && continue
		[ $line -gt $max_nss ] && max_nss=$line
	done < $MAX_NSS_FILE

	echo "$max_nss"
}

sp_set_plan_tf_length()
{
	local interface_name ap_mu_tf_len current_tf_length max_nss

	interface_name=$1
	ap_mu_tf_len=$2

	if [ -z $ap_mu_tf_len ]; then
		ap_mu_tf_len=2914
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		current_tf_length=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$rcr_com_tf_length_idx`
#		current_tf_length=`get_plan_tf_length $interface_name` #WaveSPRcrComTfLength ==> rcr_com_tf_length
	else
		current_tf_length=$ap_mu_tf_len
	fi

	if [ "$ucc_program" != "eht" ]; then
		if [ $current_tf_length -eq 3094 ]; then
			max_nss=`get_max_nss $interface_name`
			case $max_nss in
				1) ap_mu_tf_len=3076 ;;
				2) ap_mu_tf_len=3082 ;;
			esac
		fi
	else
		[ "$ap_mu_tf_len" = "3094" ] && ap_mu_tf_len=3082
	fi
	echo "$ap_mu_tf_len"
}

# get the radio's band
get_radio_band()
{
	local interface_name

	[ -z "$1" ] && error_print "get_sta_highest_bw: ERROR: Missing ifname" && echo -1 && return

	interface_name=$1

	tmp_channel=`cat /proc/net/mtlk/$interface_name/channel | grep primary_channel | awk '{print $2}'`
	if [ $tmp_channel -eq 37 ] || [ $tmp_channel -eq 33 ] || [ $tmp_channel -eq 53 ]; then
		echo "6GHz"
	elif [ $tmp_channel -ge 36 ]; then
		echo "5GHz"
	else
		echo "2.4GHz"

	fi
}

# get the highest (last) station's BW
get_sta_highest_bw()
{
	local interface_name ap_client_mac sta_bw list_of_sta_bw

	[ -z "$1" ] && error_print "get_sta_highest_bw: ERROR: Missing ifname and sta mac address" && echo -1 && return
	[ -z "$2" ] && error_print "get_sta_highest_bw: ERROR: Missing sta mac address" && echo -1 && return

	interface_name=$1
	ap_client_mac=$2

	list_of_sta_bw=`eval $HOSTAPD_CLI_CMD -i${interface_name} get_he_phy_channel_width_set $ap_client_mac`
	# "he_phy_chanwidth_set=20MHz,40MHz,80MHz,160MHz" or only part of these rates will the answer.
	# in case of a non-HE station, the response will be: "CTRL: GET_HE_PHY_CHANNEL_WIDTH_SET - STA doesn't have HE elements in assoc req"

	if [ "${list_of_sta_bw/,}" != "${list_of_sta_bw}" ]; then
		sta_bw=${list_of_sta_bw##*,}
	else
		sta_bw=${list_of_sta_bw##*=}
	fi

	echo $sta_bw
}

# get the indication whether to lower ru-size or not - WLANRTSYS-9745
is_set_low_ru_size_get()
{
	local interface_name ru_size aid_index band ap_client_mac sta_aid sta_bw field

	[ -z "$1" ] && error_print "is_set_low_ru_size_get: ERROR: Missing ifname, ru_size and aid_index" && echo -1 && return
	[ -z "$2" ] && error_print "is_set_low_ru_size_get: ERROR: Missing ru_size and aid_index" && echo -1 && return
	[ -z "$3" ] && error_print "is_set_low_ru_size_get: ERROR: Missing aid_index" && echo -1 && return

	interface_name=$1
	ru_size=$2
	aid_index=$3

	if [ "$ru_size" != "3" ]; then
		echo "0"
		return
	fi

	band=`get_radio_band $interface_name`

	while read -r line || [[ -n "$line" ]]
	do
		# display $line or do something with $line
		field=`echo $line | awk '{print $1}' | tr  "\n"`
		ap_client_mac=`echo $field | grep ":"`
		if [ -n "$ap_client_mac" ]; then

		local ORIG_IFS=$IFS
		IFS="'|'"
		sta_aid=${line//"'"/}
		sta_aid=`echo $sta_aid | awk '{print $3}'`
		sta_aid=`convert_aid_for_wav700 $sta_aid`
		IFS=$ORIG_IFS
		if [ "$MODEL" != "WAV700_AP" ]; then #Only for W600 ;not for W700
			if [ "$sta_aid" -ge "128" ]; then
				let sta_aid=sta_aid-128
			fi
		fi

			if [ "$sta_aid" != "" ] && [ $sta_aid -gt 0 ]; then
				if [ "$sta_aid" = "$aid_index" ]; then
					sta_bw=`get_sta_highest_bw $interface_name $ap_client_mac`
					if [ "$sta_bw" = "20MHz" ]; then
						# set the nss with the highest value; this way it will be the first one after sorting all stations
						echo "'$ap_client_mac' is a 20MHz station" > /dev/console

						sta_he_caps=`$HOSTAPD_CLI_CMD -i $interface_name get_sta_he_caps $ap_client_mac`

						if [ "$band" = "2.4GHz" ]; then
							if [ "${sta_he_caps//B4/}" = "$sta_he_caps" ]; then  # 'B4' is NOT present
								echo "1"
								return
							else
								# 'B4' is present - check if he_phy_20_mhz_in_160_slash_80_plus_80_mhz_he_ppdu != 1
								sta_he_caps=${sta_he_caps##*he_phy_20_mhz_in_40_mhz_he_ppdu_in_24_ghz_band=}
								sta_he_caps=${sta_he_caps%%he*}
								sta_he_caps=`echo $sta_he_caps`
								if [ "$sta_he_caps" != "1" ]; then
									echo "1"
									return
								fi
							fi
						elif [ "$band" = "5GHz" ]; then
							if [ "${sta_he_caps//B5/}" = "$sta_he_caps" ]; then  # 'B5' is NOT present
								echo "1"
								return
							else
								# 'B5' is present - check if he_phy_20_mhz_in_160_slash_80_plus_80_mhz_he_ppdu != 1
								sta_he_caps=${sta_he_caps##*he_phy_20_mhz_in_160_slash_80_plus_80_mhz_he_ppdu=}
								sta_he_caps=`echo $sta_he_caps`
								if [ "$sta_he_caps" != "1" ]; then
									echo "0"
									return
								fi
							fi
						fi
					fi
				fi
			fi
		fi
	done < /proc/net/mtlk/$interface_name/sta_list

	echo "0"
}

# get the sorted station AID index according to nss descending order (high to low)
get_sta_aid_idx_sorted_list()
{
	local interface_name field sta_bw radio vaps
	local ap_client_mac aid_index sta_nss sta_index_sorted_list
	local SMD_AID_SS_FILE="/tmp/sigma-smd-aid-ss-conf"
	local SMD_AID_SS_FILE_SORTED="/tmp/sigma-smd-aid-ss-conf-sorted"

	[ -z "$1" ] && error_print "get_sta_aid_idx_sorted_list: ERROR: Missing interface_name" && echo -1 && return
        radio=`echo "$1" | cut -d"." -f1`
        vaps=`uci show wireless | grep ifname | grep $radio | cut -d"=" -f2 |grep "\." | tr -d "'"`

	rm -f $SMD_AID_SS_FILE $SMD_AID_SS_FILE_SORTED

	for interface_name in $vaps; do
		while read -r line || [[ -n "$line" ]]
		do
			# display $line or do something with $line
			field=`echo $line | awk '{print $1}' | tr  "\n"`
			ap_client_mac=`echo $field | grep ":"`
			if [ -n "$ap_client_mac" ]; then
				aid_index=`echo $line | cut -d'|' -f 3`
				aid_index="$(echo -e "${aid_index}" | tr -d '[:space:]')"
				aid_index=`convert_aid_for_wav700 $aid_index`
				sta_nss=`echo $line | cut -d'|' -f 7`

				# remove all blanks (before and after the digits)
				sta_nss="$(echo -e "${sta_nss}" | tr -d '[:space:]')"

				# add 100 just for the sort to work fine
				sta_nss=$((sta_nss+100))

				# here check the station's maximum band width, and mark it to be the 1st one at the sorted list 
				sta_bw=`get_sta_highest_bw $interface_name $ap_client_mac`

				if [ "$sta_bw" = "20MHz" ]; then
					# set the nss with the highest value; this way it will be the first one after sorting all stations
					sta_nss=$((sta_nss+100))
					echo "'$ap_client_mac' is a 20MHz station" > /dev/console
				fi

				echo "$sta_nss,$aid_index,$ap_client_mac" >> $SMD_AID_SS_FILE
			fi
		done < /proc/net/mtlk/$interface_name/sta_list
	done

	sort -r $SMD_AID_SS_FILE > $SMD_AID_SS_FILE_SORTED

	## update all users according to the AID_SS_FILE_SORTED higher to lower ss.
	sta_index_sorted_list=""
	while read -r line || [[ -n "$line" ]]
	do
		## 2 params in line : nss,aid_index
		aid_index=`echo "${line}" | cut -d',' -f 2`

		if [ -z "$sta_index_sorted_list" ]; then
			sta_index_sorted_list="$aid_index"
		else
			sta_index_sorted_list="$sta_index_sorted_list,$aid_index"
		fi
	done <  $SMD_AID_SS_FILE_SORTED

	echo "$sta_index_sorted_list"
}

aid_idx_out_of_list_get()
{
	local count=0 aid_idx

	[ -z "$1" ] && error_print "aid_idx_out_of_list_get: ERROR: Missing station sorted AID list" && echo -1 && return
	[ -z "$2" ] && error_print "aid_idx_out_of_list_get: ERROR: Missing number of parameter to get" && echo -1 && return

	sta_index_sorted_list="$1,"  # add , at the end for the parsing
	field_location=$2

	while [ $count -lt $field_location ]; do
		aid_idx=${sta_index_sorted_list%%,*}
		sta_index_sorted_list="${sta_index_sorted_list/$aid_idx,/""}"

		count=$((count+1))
	done

	echo "$aid_idx"
}

#This subroutine extracts the SID from the sta_list for a given AID
get_sid_for_wav700()
{
	debug_print "$@"
	local aid_in=$1
	local sid_out=512

	vaps=`uci show wireless | grep ifname | grep $2 | cut -d"=" -f2 |grep "\." | tr -d "'"`
	for interface_name in $vaps
	do
		while read -r line || [[ -n "$line" ]]
		do
			# display $line or do something with $line
			field=`echo $line | awk '{print $1}' | tr  "\n"`
			ap_client_mac=`echo $field | grep ":"`
			if [ -n "$ap_client_mac" ]; then
				tmp_aid=`echo $line | cut -d'|' -f 3` #64,65,66,67
				tmp_aid="$(echo -e "${tmp_aid}" | tr -d '[:space:]')"
				tmp_sid_out=`echo $line | cut -d'|' -f 2`
				tmp_sid_out="$(echo -e "${tmp_sid_out}" | tr -d '[:space:]')"
				if [ "$tmp_aid" -eq "$aid_in" ]; then
					sid_out=$((tmp_sid_out))
					echo "$sid_out"
					return
				fi
			fi
		done < /proc/net/mtlk/$interface_name/sta_list
	done

	echo "$sid_out"
}

#Just before the static plan is sent out ,the SIDs of all the users are updated
#based on corresponding AIDs starting from either 64 or 192 from the sta_list
#The assumption is the first user has the lowest AID.
update_sid_in_static_plan()
{
	local num_stas=$3
	local offset=19
	local pos=23
	local aid=64
	local count=0
	local static_plan_config=$1
	local final_plan=""
	local interface_name=$2

	[ "$ucc_program" != "eht" ] && aid=192

	i=1
	for val in $1
	do
		if [ "$i" = "$pos" ]; then
			if [ "$count" -lt "$num_stas" ]; then
				val=`get_sid_for_wav700 $aid $interface_name`
				pos=$((pos+offset))
			fi
			count=$((count+1))
			aid=$((aid+1))
		fi
		final_plan="$final_plan $val"
		i=$((i+1))
	done

	debug_print "final_plan : $final_plan"
	echo "$final_plan"
}

update_nss_in_plan()
{
	local usr_index=$1
	local sid=$2

	eval ap_nss=\${ap_num_ss_${sid}}
	if [ "$ap_nss" -lt "1" ]; then
		error_print "NSS configurations not found for the User"
		send_invalid ",errorCode,49"
		return
	fi	
	ap_nss=$((ap_nss-1))
	ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
	ap_sp_rate=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_usr_ul_psdu_rate_per_usp_idx`
	ap_sp_rate_mcs=$((ap_sp_rate%16))
	ap_nss=$((ap_nss*16))
	let ap_nss_mcs_val=$ap_nss+$ap_sp_rate_mcs
	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ul_psdu_rate_per_usp_idx=${ap_nss_mcs_val} x$dl_usr_psdu_rate_per_usp_idx=${ap_nss_mcs_val} x$rcr_tf_usr_psdu_rate_idx=${ap_nss_mcs_val}
}

send_plan_for_1_users(){

	local interface_name start_bw_limit aid_list aid_index sta_index index usr_index \
	dl_sub_band1 dl_start_ru1 dl_ru_size1 ul_sub_band1 ul_start_ru1 ul_ru_size1 \
	dl_sub_band2 dl_start_ru2 dl_ru_size2 ul_sub_band2 ul_start_ru2 ul_ru_size2 \
	mu_type sp_enable_value tc_name CURRENT_RADIO_UCI_PATH CURRENT_WLAN_NAME glob_ssid ldpc_tmp_1
	
	CURRENT_RADIO_UCI_PATH=$3
	CURRENT_WLAN_NAME=$1
	glob_ssid=$4
	debug_print "send_plan_for_1_users ---> get_index_from_db CURRENT_RADIO_UCI_PATH=$CURRENT_RADIO_UCI_PATH"
	
	interface_name=$1
	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	start_bw_limit=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx` #x3
	mu_type=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_mu_type_idx`

	info_print "SMD: send_plan_for_1_user on $interface_name" 
	
	# update common part (WaveHeMuOperationEnable is on by default)
	tc_name=`get_test_case_name $glob_ssid`
	if [ "$tc_name" = "5.64.1" ]; then
		sp_enable_value=0
	else
		sp_enable_value=1
	fi
	#set operation_mode and dl_com_num_of_participating_stations into sMuStaticPlann_common
	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$operation_mode_idx=$sp_enable_value x$dl_com_num_of_participating_stations_idx=1
	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$txop_com_start_bw_limit_idx=$start_bw_limit
	
	# update 1 user plan according to BW.
	# 0-20MHz, 1-40MHz, 2-80MHz, 3-160MHz 4-320MHz(both 320_1MHz and 320_2MHz)
	case "$start_bw_limit" in
		"0")
			#USER1
			dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3
		;;
		"1")
			#USER1
			dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=4
		;;
		"2")
			#USER1
			dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=5
		;;
		"3")
			#USER1
			dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=6;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=6
		;;
		"4")
			#USER1
			dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=7;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=7
		;;
	esac
	
	# update 1 user params in DB
	usr_index=1
	local tmp_param tmp_val
	tmp_param="dl_sub_band$usr_index";eval tmp_val=\$$tmp_param
	ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`	
	[ -n "$tmp_val" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_sub_band_per_usp_idx=$tmp_val
	tmp_param="dl_start_ru$usr_index";eval tmp_val=\$$tmp_param
	[ -n "$tmp_val" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_start_ru_per_usp_idx=$tmp_val
	tmp_param="dl_ru_size$usr_index";eval tmp_val=\$$tmp_param
	[ -n "$tmp_val" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ru_size_per_usp_idx=$tmp_val
	tmp_param="ul_sub_band$usr_index";eval tmp_val=\$$tmp_param
	[ -n "$tmp_val" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_sub_band_idx=$tmp_val
	tmp_param="ul_start_ru$usr_index";eval tmp_val=\$$tmp_param	
	[ -n "$tmp_val" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_start_ru_idx=$tmp_val
	tmp_param="ul_ru_size$usr_index";eval tmp_val=\$$tmp_param
	[ -n "$tmp_val" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_ru_size_idx=$tmp_val
	
	## update ldpc according to STA ##
	sp_check_ldpc_support $5

	local static_plan_config=""
	sortFile="/tmp/sigma-sort-sta-file"
	sortedFile="/tmp/sigma-sorted-sta-file"
	rm -f $sortFile $sortedFile

	aid_index=`$HOSTAPD_CLI_CMD -i$5 all_sta $5 | grep aid=`
	aid_index=${aid_index##*=}
	aid_index=`convert_aid_for_wav700 $aid_index`
	# Incase multibss is enabled on the interface (for e.g. 6GHz), AID offset needs to be accounted before deriving SID
	if [ "$MODEL" != "WAV700_AP" ]; then
		local band=`uci show $CURRENT_RADIO_UCI_PATH | grep band | head -n 1 | cut -d "=" -f2 | tr -d "'"`
		if [ "$band" = "6GHz" ]; then
			[ $aid_index -gt 64 ] && aid_index=$((aid_index-64))
		fi
	fi
	if [ "$ap_type" != "EHT" ]; then
		ldpc_tmp_1="ldpc_${aid_index}"
		ldpc_support=`eval 'echo $'$ldpc_tmp_1`
		[ "$ldpc_support" != "" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_ldpc_idx=$ldpc_support
	fi	
	[ $aid_index -gt 0 ] && let sta_index=$aid_index-1

	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_usp_station_indexes_idx=$sta_index
	$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $sortFile
		
	sort -n $sortFile > $sortedFile

	while read -r line; do
		static_plan_config="$(echo $line | sed "s/sMuStaticPlannUser[0-9]//g") ${static_plan_config}"
	done < $sortedFile

	# Change the length according to maximum NSS value of the connected STAs.
	[ "$mu_type" = "0" ] && ap_mu_tf_len=`sp_set_plan_tf_length $interface_name $ap_mu_tf_len`
	
	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	dl_com_number_of_phase_repetitions=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x7`
	# if dl_com_number_of_phase_repetitions is configured -> twt_respsupport is enabled and ap_mu_tf_len="1486
	if [ "$dl_com_number_of_phase_repetitions" = "2" ]; then
		ap_mu_tf_len="1486"
	fi

	# test for 5.61.1 - Jira WLANRTSYS-80398
	tc_name=`get_test_case_name $glob_ssid`
	if [ "$MODEL" = "WAV700_AP" ] && [ "$tc_name" = "5.61.1" ]; then
		ap_mu_tf_len="610"
	fi

	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_length_idx=$ap_mu_tf_len

	uci_commit_wireless
	static_plan_config="$($UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' | sed 's/sMuStaticPlann_common//g' | sed 's/false/0/g') ${static_plan_config}"

	[ "$MODEL" = "WAV700_AP" ] && static_plan_config=`update_sid_in_static_plan "${static_plan_config}" $CURRENT_WLAN_NAME 1`

	debug_print "CREATE COMMAND: Args $static_plan_config"
	eval iw dev $interface_name iwlwav sMuStatPlanCfg $static_plan_config
	local res=$?
	info_print "plan for 1 user: iw dev $interface_name iwlwav sMuStatPlanCfg $static_plan_config"
	if [ $res != "0" ]; then
		error_print "$res in iw dev applying static plan"
		error_print ",errorCode,700"
		return
	fi
}

# send plan for 2 users.
send_plan_for_2_users()
{
	if [ "$ap_mrualloctones" = "" ]; then
		local interface_name start_bw_limit aid_list aid_index sta_index usr_index \
		dl_sub_band1 dl_start_ru1 dl_ru_size1 ul_sub_band1 ul_start_ru1 ul_ru_size1 \
		dl_sub_band2 dl_start_ru2 dl_ru_size2 ul_sub_band2 ul_start_ru2 ul_ru_size2 \
		mu_type sp_enable_value aid_idx_sorted_list tmp_param tmp_val ap_aid_index \
		is_set_low_ru_size CURRENT_RADIO_UCI_PATH CURRENT_WLAN_NAME glob_ssid ldpc_tmp_1 \
		splanconfigRUsorted
	fi

	CURRENT_RADIO_UCI_PATH=$3
	CURRENT_WLAN_NAME=$1
	glob_ssid=$4
	debug_print "send_plan_for_2_users ---> get_index_from_db CURRENT_RADIO_UCI_PATH=$CURRENT_RADIO_UCI_PATH"

	interface_name=$1
	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	start_bw_limit=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx` #x3
	mu_type=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_mu_type_idx`

	info_print "SMD: send_plan_for_2_user on $interface_name" #info_print

	# update common part (WaveHeMuOperationEnable is on by default)
	tc_name=`get_test_case_name $glob_ssid`
	if [ "$tc_name" = "5.64.1" ]; then
		sp_enable_value=0
	else
		sp_enable_value=1
	fi
	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$operation_mode_idx=$sp_enable_value x$dl_com_num_of_participating_stations_idx=2

	# update 2 user plan according to BW, If the MRU Alloctones are not provided in the CAPI.
	if [ "$ap_mrualloctones" = "" ]; then
		# 0-20MHz, 1-40MHz, 2-80MHz, 3-160MHz 4-320MHz(both 320_1MHz and 320_2MHz)
		case "$start_bw_limit" in
			"0")
				if [ "$mu_type" = "0" ]; then
					## OFDMA ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=2
					#USER2
					dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=2;ul_sub_band2=0;ul_start_ru2=5;ul_ru_size2=2
				else
					## MIMO ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=2;ul_psdu_rate_per_usp1=4;spr_cr_tf_usr_psdu_rate1=4
					#USER2
					dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=3;ul_sub_band2=0;ul_start_ru2=5;ul_ru_size2=2;ul_psdu_rate_per_usp2=4;spr_cr_tf_usr_psdu_rate2=4
				fi
			;;
			"1")
				if [ "$mu_type" = "0" ]; then
					## OFDMA ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3
					#USER2
					dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=3;ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=3
				else
					## MIMO ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3;ul_psdu_rate_per_usp1=4;spr_cr_tf_usr_psdu_rate1=4
					#USER2
					dl_sub_band2=0;dl_start_ru2=0;dl_ru_size2=4;ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=3;ul_psdu_rate_per_usp2=4;spr_cr_tf_usr_psdu_rate2=4
				fi
			;;
			"2")
				if [ "$mu_type" = "0" ]; then
					## OFDMA ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=4
					#USER2
					dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=4;ul_sub_band2=2;ul_start_ru2=0;ul_ru_size2=4
				else
					## MIMO ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=4;ul_psdu_rate_per_usp1=4;spr_cr_tf_usr_psdu_rate1=4
					#USER2
					dl_sub_band2=0;dl_start_ru2=0;dl_ru_size2=5;ul_sub_band2=2;ul_start_ru2=0;ul_ru_size2=4;ul_psdu_rate_per_usp2=4;spr_cr_tf_usr_psdu_rate2=4
				fi
			;;
			"3")
				if [ "$mu_type" = "0" ]; then
					## OFDMA ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=5
					#USER2
					dl_sub_band2=4;dl_start_ru2=0;dl_ru_size2=5;ul_sub_band2=4;ul_start_ru2=0;ul_ru_size2=5
				else
					## MIMO ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=6;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=5;ul_psdu_rate_per_usp1=4;spr_cr_tf_usr_psdu_rate1=4
					#USER2
					dl_sub_band2=0;dl_start_ru2=0;dl_ru_size2=6;ul_sub_band2=4;ul_start_ru2=0;ul_ru_size2=5;ul_psdu_rate_per_usp2=4;spr_cr_tf_usr_psdu_rate2=4
				fi
			;;
			"4")
				if [ "$mu_type" = "0" ]; then
					## OFDMA ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=6;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=6
					#USER2
					dl_sub_band2=8;dl_start_ru2=0;dl_ru_size2=6;ul_sub_band2=8;ul_start_ru2=0;ul_ru_size2=6
				else
					## MIMO ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=7;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=7;ul_psdu_rate_per_usp1=4;spr_cr_tf_usr_psdu_rate1=4
					#USER2
					dl_sub_band2=0;dl_start_ru2=0;dl_ru_size2=7;ul_sub_band2=0;ul_start_ru2=0;ul_ru_size2=7;ul_psdu_rate_per_usp2=4;spr_cr_tf_usr_psdu_rate2=4
				fi
			;;
		esac

		is_set_low_ru_size="0"

		for ap_aid_index in 1 2
		do
			tmp_param="dl_ru_size$ap_aid_index"
			eval tmp_val=\${$tmp_param}

			# WLANRTSYS-9745: check if lower value is needed only if it is still not needed
			if [ $is_set_low_ru_size = "0" ]; then
				is_set_low_ru_size=`is_set_low_ru_size_get $5 $tmp_val $ap_aid_index`
			fi
		done
	fi
	# update per-user params in DB
	for usr_index in 1 2
	do
		ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`	
		tmp_param="dl_sub_band$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_sub_band_per_usp_idx=$tmp_val

		tmp_param="dl_start_ru$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_start_ru_per_usp_idx=$tmp_val

		tmp_param="ul_sub_band$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_sub_band_idx=$tmp_val

		tmp_param="ul_start_ru$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_start_ru_idx=$tmp_val

		tmp_param="ul_ru_size$usr_index";eval tmp_val=\$$tmp_param
		[ -z "$glob_ap_usrinfo_ru_alloc" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_ru_size_idx=$tmp_val

		if [ "$global_ap_mimo" != "ul" ]; then
			tmp_param="ul_psdu_rate_per_usp$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ul_psdu_rate_per_usp_idx=$tmp_val
		elif [ "$global_ap_mimo" = "ul" ] && [ "$ucc_type" = "testbed" ]; then
			# Hard-code MCS to 5 for STAUT UL MIMO data traffic phase. This is a system limitation until the feature will be stabilized for higher performance
			debug_print "Setting UL MIMO MCS to 5"
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ul_psdu_rate_per_usp_idx=5
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_target_rssi_idx=60
		fi

		if [ "$ucc_program" = "eht" ] && [ "$mu_type" = "1" ]; then
			# Hard-code MCS to 6 for MU-MIMO data traffic phase. This is a system limitation until the feature will be stabilized for higher performance
			if [ "$ap_sequence_type" -eq 4 -o "$ap_sequence_type" -eq 10 ]; then #Hardcode MCS to 6 and NSS to 2 for MU-RTS and BSRP frame transmission
				spr_cr_tf_usr_psdu_rate1=22
				spr_cr_tf_usr_psdu_rate2=22
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ul_psdu_rate_per_usp_idx=22
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_psdu_rate_per_usp_idx=22
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_target_rssi_idx=64
			else
				spr_cr_tf_usr_psdu_rate1=6
				spr_cr_tf_usr_psdu_rate2=6
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ul_psdu_rate_per_usp_idx=6
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_psdu_rate_per_usp_idx=6
				Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_target_rssi_idx=64
			fi
		fi

		tmp_param="spr_cr_tf_usr_psdu_rate$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_psdu_rate_idx=$tmp_val

		if [ $is_set_low_ru_size = "1" ] && [ "$ap_mrualloctones" = "" ]; then
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ru_size_per_usp_idx=2
		else
			debug_print "ru_size_static-plan_for2"
			tmp_param="dl_ru_size$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ru_size_per_usp_idx=$tmp_val
		fi
		if [ "$ap_mrualloctones" != "" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannMRUUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			tmp_param="dl_mru_size$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannMRUUser${usr_index} x$dl_mru_perusp_idx=$tmp_val

			tmp_param="ul_mru_size$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannMRUUser${usr_index} x$ul_mru_idx=$tmp_val
		fi
	done

	sp_check_ldpc_support $5
	# dynamically update STA index in DB according to: 20 MHz STA first, then NSS (higher to lower NSS)
	aid_idx_sorted_list=`get_sta_aid_idx_sorted_list $5`
	local static_plan_config=""
	sortFile="/tmp/sigma-sort-sta-file"
	sortedFile="/tmp/sigma-sorted-sta-file"
	MRUFile="/tmp/sigma-MRU-file"
	rm -f $sortFile $sortedFile $MRUFile
	for ap_aid_index in 1 2
	do
		debug_print "glob_ap_ack_policy_mac=$glob_ap_ack_policy_mac ap_sta_id=$ap_sta_id"
		if [ "$ap_mrualloctones" != "" ]; then
			aid_index=$((ap_aid_index))
		else
			aid_index=`aid_idx_out_of_list_get "${aid_idx_sorted_list}" "${ap_aid_index}"`
			aid_index=`echo ${aid_index//[!0-9]/}`
		fi
		[ $aid_index -gt 0 ] && let sta_index=$((aid_index-1))
		# switch the OFDMA users, so the primary sta id will be at user 1 (first user). not needed if it is already in user 1.
		if [ "$glob_ap_ack_policy_mac" != "" ] && [ $ap_sta_id -gt 0 ]; then
			#store the primary sta id in user 1
			debug_print "store the primary sta id in user 1"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser1' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser1 x${dl_usr_usp_station_indexes_idx}=${ap_sta_id}
			$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $sortFile

			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser2' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $sortFile
			if [ "$ap_mrualloctones" != "" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannMRUUser1' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $MRUFile

				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannMRUUser2' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $MRUFile
			fi
			break
		else
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u` 
			[ -z "$glob_ap_sta_aid" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$dl_usr_usp_station_indexes_idx=$sta_index
			[ "$ap_type" = "EHT" ] && [ "$ap_num_ss" != "" -a "$ap_num_ss_mac" != "" ] && update_nss_in_plan $ap_aid_index $sta_index
			$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $sortFile

			if [ "$ap_mrualloctones" != "" ]; then
				ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannMRUUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
				$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $MRUFile
			fi
		fi
		ldpc_tmp_1="ldpc_${aid_index}"
		ldpc_support=`eval 'echo $'$ldpc_tmp_1`
		ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u` 
		[ "$ldpc_support" != "" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$rcr_tf_usr_ldpc_idx=$ldpc_support
		
		if [ "$glob_ap_trigger_coding" = "BCC" ]; then
			ap_bcc_ldpc_int=0
		elif [ "$glob_ap_trigger_coding" = "LDPC" ]; then
			ap_bcc_ldpc_int=1
		fi
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int
	done

	# re-update user config in-case both users ended up with same dl_usr_usp_station_indexes_idx
	ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser1' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
	user1_sid=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x0`
	ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser2' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
	user2_sid=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x0`

	if [ "$user1_sid" = "$user2_sid" ]; then
		debug_print "same sid detected for users, fixing it"
		tmp_sid=$((user1_sid%2))
		if [ "$tmp_sid" = "0" ]; then
			user2_sid=$((user1_sid+1))
		else
			user2_sid=$((user1_sid-1))
		fi
		# User2 config already fetched before the if block
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser2 x$dl_usr_usp_station_indexes_idx=$user2_sid
		rm -f $sortFile $sortedFile $MRUFile
		for ap_aid_index in 1 2
		do
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannMRUUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $MRUFile

			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $sortFile
		done
	fi

	debug_print "remove sMuStaticPlannUser from sortPlan"
	sed -i 's/sMuStaticPlannUser[0-9]//g' $sortFile
	if [ "$MODEL" = "WAV700_AP" ]; then
		sort -n $sortFile > $sortedFile
	else
		if [ "$glob_ap_ack_policy_mac" != "" ] && [ $ap_sta_id -gt 0 ]; then
			sort -nr $sortFile > $sortedFile
		else
			sort -n $sortFile > $sortedFile
		fi
	fi
	while read -r line; do
		debug_print "static_plan_config"
		static_plan_config="${static_plan_config} ${line}"
	done < $sortedFile

	if [ "$ap_mrualloctones" != "" ]; then
		debug_print "remove sMuStaticPlannMRUUser from sortPlan"
		sed -i 's/sMuStaticPlannMRUUser[0-9]//g' $MRUFile

		while read -r line; do
			debug_print "static_plan_config"
			static_plan_config="${static_plan_config} ${line}"
		done < $MRUFile
	fi
	
	# Change the length according to maximum NSS value of the connected STAs.
	[ "$mu_type" = "0" ] && ap_mu_tf_len=`sp_set_plan_tf_length $5 $ap_mu_tf_len`

	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	# TWT test
	band=`get_radio_band $interface_name`
	if [ "$tc_name" = "4.56.1" ]; then
		## WLANRTSYS-18156 set dl_com_number_of_phase_repetitions=3 and from PF8 Sigma: rcr_com_tf_length=1486
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${rcr_com_tf_length_idx}=1486
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=3
		ap_mu_tf_len=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$rcr_com_tf_length_idx`
	fi

	uci_commit_wireless
	static_plan_config="$($UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' | sed 's/sMuStaticPlann_common//g' | sed 's/false/0/g') ${static_plan_config}"
	debug_print "CREATE COMMAND: Args $static_plan_config"
	
	info_print "plan for 2 user Ru not sorted: iw dev $interface_name iwlwav sMuStatPlanCfg $static_plan_config"
	splanconfigRUsorted=`sortPlan "$static_plan_config" 28 2`
	splanconfigDlUlRUsorted=`sortPlan "$splanconfigRUsorted" 37 2`

	if [ "$sortedList_28" != "$sortedList_37" ]
	then
		error_print "DL_RU and UP_RU not equal $sortedList_28"
		error_print "DL_RU and UP_RU not equal $sortedList_37"
		exit -1
	fi

	[ "$MODEL" = "WAV700_AP" ] && splanconfigDlUlRUsorted=`update_sid_in_static_plan "${splanconfigDlUlRUsorted}" $CURRENT_WLAN_NAME 2`

	if [ -e "/tmp/${glob_ssid}_tmp" ]; then
		static_plan_send_debug_infra 2
	else
		eval iw dev $interface_name iwlwav sMuStatPlanCfg $splanconfigDlUlRUsorted
		local res=$?
		info_print "plan for 2 user: iw dev $interface_name iwlwav sMuStatPlanCfg $splanconfigDlUlRUsorted"
		if [ $res != "0" ]; then
			error_print "$res in iw dev applying static plan"
			error_print ",errorCode,700"
			return
		fi
	fi
}

# send plan for 3 users.
send_plan_for_3_users()
{
	local interface_name start_bw_limit aid_list aid_index sta_index usr_index \
	dl_sub_band1 dl_start_ru1 dl_ru_size1 ul_sub_band1 ul_start_ru1 ul_ru_size1 \
	dl_sub_band2 dl_start_ru2 dl_ru_size2 ul_sub_band2 ul_start_ru2 ul_ru_size2 \
	dl_sub_band3 dl_start_ru3 dl_ru_size3 ul_sub_band3 ul_start_ru3 ul_ru_size3 \
	mu_type tmp_param tmp_val aid_idx_sorted_list \
	ap_aid_index is_set_low_ru_size CURRENT_RADIO_UCI_PATH CURRENT_WLAN_NAME glob_ssid ldpc_tmp_1 \
	splanconfigRUsorted


	CURRENT_RADIO_UCI_PATH=$3
	CURRENT_WLAN_NAME=$1
	glob_ssid=$4
	debug_print "send_plan_for_3_users ---> get_index_from_db CURRENT_RADIO_UCI_PATH=$CURRENT_RADIO_UCI_PATH"

	interface_name=$1
	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	start_bw_limit=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx` #x3
	mu_type=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_mu_type_idx`

	info_print "SMD: send_plan_for_3_user on $interface_name" #info_print

	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$operation_mode_idx=1 x$dl_com_num_of_participating_stations_idx=3

	# update 3 user plan according to BW.
	# 0-20MHz, 1-40MHz, 2-80MHz, 3-160MHz 4-320MHz(both 320_1MHz and 320_2MHz)
	case "$start_bw_limit" in
		"0")
			if [ "$mu_type" = "0" ]; then
				## OFDMA ##
				#USER1
				dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=1;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=1
				#USER2
				dl_sub_band2=0;dl_start_ru2=2;dl_ru_size2=1;ul_sub_band2=0;ul_start_ru2=2;ul_ru_size2=1
				#USER3
				dl_sub_band3=0;dl_start_ru3=5;dl_ru_size3=1;ul_sub_band3=0;ul_start_ru3=5;ul_ru_size3=1
			else
				## MIMO ##
				info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_3_users: MIMO not supported"
			fi
		;;
		"1")
			if [ "$mu_type" = "0" ]; then
				#USER1
				dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=2
				#USER2
				dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=2;ul_sub_band2=0;ul_start_ru2=5;ul_ru_size2=2
				#USER3
				dl_sub_band3=1;dl_start_ru3=0;dl_ru_size3=2;ul_sub_band3=1;ul_start_ru3=0;ul_ru_size3=2
			else
				## MIMO ##
				info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_3_users: MIMO not supported"
			fi
		;;
		"2")
			if [ "$mu_type" = "0" ]; then
				#USER1
				dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3
				#USER2
				dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=3;ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=3
				#USER3
				dl_sub_band3=2;dl_start_ru3=0;dl_ru_size3=3;ul_sub_band3=2;ul_start_ru3=0;ul_ru_size3=3
			else
				## MIMO ##
				info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_3_users: MIMO not supported"
			fi
		;;
		"3")
			if [ "$mu_type" = "0" ]; then
				#USER1
				dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=4
				#USER2
				dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=4;ul_sub_band2=2;ul_start_ru2=0;ul_ru_size2=4
				#USER3
				dl_sub_band3=4;dl_start_ru3=0;dl_ru_size3=4;ul_sub_band3=4;ul_start_ru3=0;ul_ru_size3=4
			else
				## MIMO ##
				info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_3_users: MIMO not supported"
			fi
		;;
		"4")
			if [ "$mu_type" = "0" ]; then
				#USER1
				dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=5
				#USER2
				dl_sub_band2=4;dl_start_ru2=0;dl_ru_size2=5;ul_sub_band2=4;ul_start_ru2=0;ul_ru_size2=5
				#USER3
				dl_sub_band3=8;dl_start_ru3=0;dl_ru_size3=5;ul_sub_band3=8;ul_start_ru3=0;ul_ru_size3=5
			else
				## MIMO ##
				info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_3_users: MIMO not supported"
			fi
		;;
	esac

	is_set_low_ru_size="0"

	for ap_aid_index in 1 2 3
	do
		tmp_param="dl_ru_size$ap_aid_index"
		eval tmp_val=\${$tmp_param}

		# WLANRTSYS-9745: check if lower value is needed only if it is still not needed
		if [ $is_set_low_ru_size = "0" ]; then
			is_set_low_ru_size=`is_set_low_ru_size_get $5 $tmp_val $ap_aid_index`
		fi
	done

	## WLANRTSYS-12035
	if [ $dl_ru_size1 -lt 2 ]; then
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2300
	else
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
	fi

	# update per-user params in DB
	aid_idx_sorted_list=`get_sta_aid_idx_sorted_list $5`
	for usr_index in 1 2 3
	do
		ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
		#Do not update DL/UL sub-band in-case puncture configuration was done prior to final call to configure plan
		if [ "$global_ap_preamblepunctmode" = "" ] && [ "$global_ap_preamblepunctchannel" = "" ]; then
			tmp_param="dl_sub_band$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_sub_band_per_usp_idx=$tmp_val
			tmp_param="ul_sub_band$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_sub_band_idx=$tmp_val
		fi
		tmp_param="dl_start_ru$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_start_ru_per_usp_idx=$tmp_val
		tmp_param="ul_start_ru$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_start_ru_idx=$tmp_val
		debug_print "glob_ap_usrinfo_ru_alloc_SP=$glob_ap_usrinfo_ru_alloc"
		tmp_param="ul_ru_size$usr_index";eval tmp_val=\$$tmp_param
		[ -z "$glob_ap_usrinfo_ru_alloc" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_ru_size_idx=$tmp_val

		debug_print "ap_rualloctones_plan2=$ap_rualloctones ap_txbandwidth=$ap_txbandwidth"
		if [ $is_set_low_ru_size = "1" ]; then
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index  x$dl_usr_ru_size_per_usp_idx=2
		elif [ "$glob_ap_rualloctones" = "" ] || [ "$glob_ap_txbandwidth" = "" ]; then
			tmp_param="dl_ru_size$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ru_size_per_usp_idx=$tmp_val
		fi

		if [ "$global_emlsr_tb_ul_ofdma" = "1" ] && [ "$mu_type" = "0" ]; then
			#update tf_padding=6 (829 Bytes)
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$tf_usr_tf_padding_idx=6
			#update UL NSS=1 and MCS=9
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ul_psdu_rate_per_usp_idx=9
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_psdu_rate_idx=9
		fi
	done

	sp_check_ldpc_support $5
	local static_plan_config=""
	# dynamically update STA index in DB according to: 20 MHz STA first, then NSS (higher to lower NSS)
	aid_idx_sorted_list=`get_sta_aid_idx_sorted_list $5`
	sortFile="/tmp/sigma-sort-sta-file"
	sortedFile="/tmp/sigma-sorted-sta-file"
	rm -f $sortFile $sortedFile
	for ap_aid_index in 1 2 3
	do
		aid_index=`aid_idx_out_of_list_get "${aid_idx_sorted_list}" "${ap_aid_index}"`
		aid_index=`echo ${aid_index//[!0-9]/}`
		[ $aid_index -gt 0 ] && sta_index=$((aid_index-1))
		ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
		[ -z "$glob_ap_sta_aid" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$dl_usr_usp_station_indexes_idx=$sta_index
		$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $sortFile
		ldpc_tmp_1="ldpc_${aid_index}"
		ldpc_support=`eval 'echo $'$ldpc_tmp_1`
		[ "$ldpc_support" != "" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int

		if [ "$glob_ap_trigger_coding" = "BCC" ]; then
			ap_bcc_ldpc_int=0
		elif [ "$glob_ap_trigger_coding" = "LDPC" ]; then
			ap_bcc_ldpc_int=1
		fi
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int

	done

	if [ "$MODEL" = "WAV700_AP" ]; then
		#TODO : Check for no regression in legacy through thorough testing
		#sort -k option is not supported !!!
		sed -i 's/sMuStaticPlannUser[0-9]//g' $sortFile
		sort -n $sortFile > $sortedFile
		while read -r line; do
			static_plan_config="${static_plan_config} ${line}"
		done < $sortedFile
		rm -f $sortFile $sortedFile
	else
		sort -k2 -n $sortFile > $sortedFile
		while read -r line; do
			static_plan_config="$(echo $line | sed "s/sMuStaticPlannUser[0-9]//g") ${static_plan_config}"
		done < $sortedFile
		rm -f $sortFile $sortedFile
	fi

	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	if [ "$global_emlsr_tb_ul_ofdma" = "1" ] && [ "$mu_type" = "0" ]; then
		#update PhaseRepetion=0 & muSequenceType=7
		Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=0
		set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=7
	fi

	uci_commit_wireless
	static_plan_config="$($UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' | sed 's/sMuStaticPlann_common//g' | sed 's/false/0/g') ${static_plan_config}"
	debug_print "CREATE COMMAND: Args $static_plan_config"

	info_print "plan for 3 user Ru not sorted: iw dev $interface_name iwlwav sMuStatPlanCfg $static_plan_config"
	splanconfigRUsorted=`sortPlan "$static_plan_config" 28 3`
	splanconfigDlUlRUsorted=`sortPlan "$splanconfigRUsorted" 37 3`

	if [ "$sortedList_28" != "$sortedList_37" ]
	then
		error_print "DL_RU and UP_RU not equal $sortedList_28"
		error_print "DL_RU and UP_RU not equal $sortedList_37"
		exit -1
	fi

	[ "$MODEL" = "WAV700_AP" ] && splanconfigDlUlRUsorted=`update_sid_in_static_plan "${splanconfigDlUlRUsorted}" $CURRENT_WLAN_NAME 3`

	if [ -e "/tmp/${glob_ssid}_tmp" ]; then
		static_plan_send_debug_infra 3
	else
		eval iw dev $interface_name iwlwav sMuStatPlanCfg $splanconfigDlUlRUsorted
		local res=$?
		info_print "plan for 3 user: iw dev $interface_name iwlwav sMuStatPlanCfg $splanconfigDlUlRUsorted"
		if [ $res != "0" ]; then
			error_print "$res in iw dev applying static plan"
			error_print ",errorCode,700"
			return
		fi
	fi
}

send_plan_for_4_users()
{
	if [ "$ap_mrualloctones" = "" ]; then
		local interface_name start_bw_limit aid_list aid_index sta_index usr_index \
		dl_sub_band1 dl_start_ru1 dl_ru_size1 ul_sub_band1 ul_start_ru1 ul_ru_size1 \
		dl_sub_band2 dl_start_ru2 dl_ru_size2 ul_sub_band2 ul_start_ru2 ul_ru_size2 \
		dl_sub_band3 dl_start_ru3 dl_ru_size3 ul_sub_band3 ul_start_ru3 ul_ru_size3 \
		dl_sub_band4 dl_start_ru4 dl_ru_size4 ul_sub_band4 ul_start_ru4 ul_ru_size4 \
		mu_type sp_enable_value tc_name tmp_param tmp_val aid_idx_sorted_list \
		ap_aid_index is_set_low_ru_size CURRENT_RADIO_UCI_PATH CURRENT_WLAN_NAME glob_ssid ldpc_tmp_1 \
		usr cnt splanconfigRUsorted
	fi

	CURRENT_RADIO_UCI_PATH=$3
	CURRENT_WLAN_NAME=$1
	glob_ssid=$4
	debug_print "send_plan_for_4_users ---> get_index_from_db CURRENT_RADIO_UCI_PATH=$CURRENT_RADIO_UCI_PATH"
	
	interface_name=$1
	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	start_bw_limit=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$txop_com_start_bw_limit_idx` #x3
	mu_type=`get_index_from_db $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx x$dl_com_mu_type_idx`

	info_print "SMD: send_plan_for_4_user on $interface_name" #info_print

	# update common part (WaveHeMuOperationEnable is on by default)
	tc_name=`get_test_case_name $glob_ssid`
	if [ "$tc_name" = "5.64.1" ]; then
		sp_enable_value=0
	else
		sp_enable_value=1
	fi
	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$operation_mode_idx=$sp_enable_value x$dl_com_num_of_participating_stations_idx=4
	
	# update 4 user plan according to BW, if the RU Alloctones are not configured from the CAPI.
	if [ "$ap_mrualloctones" = "" ]; then
		# 0-20MHz, 1-40MHz, 2-80MHz, 3-160MHz 4-320MHz(both 320_1MHz and 320_2MHz)
		case "$start_bw_limit" in
			"0")
				if [ "$mu_type" = "0" ]; then
					## OFDMA ##
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=1;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=1
					#USER2
					dl_sub_band2=0;dl_start_ru2=2;dl_ru_size2=1;ul_sub_band2=0;ul_start_ru2=2;ul_ru_size2=1
					#USER3
					dl_sub_band3=0;dl_start_ru3=5;dl_ru_size3=1;ul_sub_band3=0;ul_start_ru3=5;ul_ru_size3=1
					#USER4
					dl_sub_band4=0;dl_start_ru4=7;dl_ru_size4=1;ul_sub_band4=0;ul_start_ru4=7;ul_ru_size4=1
				else
					## MIMO ##
					info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_4_users: MIMO not supported"
				fi
			;;
			"1")
				if [ "$mu_type" = "0" ]; then
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=2;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=2
					#USER2
					dl_sub_band2=0;dl_start_ru2=5;dl_ru_size2=2;ul_sub_band2=0;ul_start_ru2=5;ul_ru_size2=2
					#USER3
					dl_sub_band3=1;dl_start_ru3=0;dl_ru_size3=2;ul_sub_band3=1;ul_start_ru3=0;ul_ru_size3=2
					#USER4
					dl_sub_band4=1;dl_start_ru4=5;dl_ru_size4=2;ul_sub_band4=1;ul_start_ru4=5;ul_ru_size4=2
				else
					## MIMO ##
					info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_4_users: MIMO not supported"
				fi
			;;
			"2")
				if [ "$mu_type" = "0" ]; then
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=3;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=3
					#USER2
					dl_sub_band2=1;dl_start_ru2=0;dl_ru_size2=3;ul_sub_band2=1;ul_start_ru2=0;ul_ru_size2=3
					#USER3
					dl_sub_band3=2;dl_start_ru3=0;dl_ru_size3=3;ul_sub_band3=2;ul_start_ru3=0;ul_ru_size3=3
					#USER4
					dl_sub_band4=3;dl_start_ru4=0;dl_ru_size4=3;ul_sub_band4=3;ul_start_ru4=0;ul_ru_size4=3
				else
					## MIMO ##
					info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_4_users: MIMO not supported"
				fi
			;;
			"3")
				if [ "$mu_type" = "0" ]; then
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=4;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=4
					#USER2
					dl_sub_band2=2;dl_start_ru2=0;dl_ru_size2=4;ul_sub_band2=2;ul_start_ru2=0;ul_ru_size2=4
					#USER3
					dl_sub_band3=4;dl_start_ru3=0;dl_ru_size3=4;ul_sub_band3=4;ul_start_ru3=0;ul_ru_size3=4
					#USER4
					dl_sub_band4=6;dl_start_ru4=0;dl_ru_size4=4;ul_sub_band4=6;ul_start_ru4=0;ul_ru_size4=4
				else
					## MIMO ##
					info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_4_users: MIMO not supported"
				fi
			;;
			"4")
				if [ "$mu_type" = "0" ]; then
					#USER1
					dl_sub_band1=0;dl_start_ru1=0;dl_ru_size1=5;ul_sub_band1=0;ul_start_ru1=0;ul_ru_size1=5
					#USER2
					dl_sub_band2=4;dl_start_ru2=0;dl_ru_size2=5;ul_sub_band2=4;ul_start_ru2=0;ul_ru_size2=5
					#USER3
					dl_sub_band3=8;dl_start_ru3=0;dl_ru_size3=5;ul_sub_band3=8;ul_start_ru3=0;ul_ru_size3=5
					#USER4
					dl_sub_band4=12;dl_start_ru4=0;dl_ru_size4=5;ul_sub_band4=12;ul_start_ru4=0;ul_ru_size4=5
				else
					## MIMO ##
					info_print "SMD:start_bw_limit=$start_bw_limit:send_plan_for_4_users: MIMO not supported"
				fi
			;;
		esac

		is_set_low_ru_size="0"

		for ap_aid_index in 1 2 3 4
		do
			tmp_param="dl_ru_size$ap_aid_index"
			eval tmp_val=\${$tmp_param}

			# WLANRTSYS-9745: check if lower value is needed only if it is still not needed
			if [ $is_set_low_ru_size = "0" ]; then
				is_set_low_ru_size=`is_set_low_ru_size_get $5 $tmp_val $ap_aid_index`
			fi
		done
	fi
	
	## WLANRTSYS-12035
	if [ $dl_ru_size1 -lt 2 ]; then
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2300
	else
		ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_maximum_ppdu_transmission_time_limit_idx}=2700
	fi

	# update per-user params in DB
	aid_idx_sorted_list=`get_sta_aid_idx_sorted_list $5`
	for usr_index in 1 2 3 4
	do
		ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
		tmp_param="dl_sub_band$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_sub_band_per_usp_idx=$tmp_val
		tmp_param="dl_start_ru$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_start_ru_per_usp_idx=$tmp_val
		tmp_param="ul_sub_band$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_sub_band_idx=$tmp_val
		tmp_param="ul_start_ru$usr_index";eval tmp_val=\$$tmp_param
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_start_ru_idx=$tmp_val
		debug_print "glob_ap_usrinfo_ru_alloc_SP=$glob_ap_usrinfo_ru_alloc"
		tmp_param="ul_ru_size$usr_index";eval tmp_val=\$$tmp_param
		[ -z "$glob_ap_usrinfo_ru_alloc" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_ru_size_idx=$tmp_val
		
		debug_print "ap_rualloctones_plan2=$ap_rualloctones ap_txbandwidth=$ap_txbandwidth"
		if [ $is_set_low_ru_size = "1" ] && [ "$ap_mrualloctones" = "" ]; then
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index  x$dl_usr_ru_size_per_usp_idx=2
		elif [ "$glob_ap_rualloctones" = "" ] || [ "$glob_ap_txbandwidth" = "" ]; then
			tmp_param="dl_ru_size$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ru_size_per_usp_idx=$tmp_val
		fi

		if [ "$global_emlsr_tb_ul_ofdma" = "1" ] && [ "$mu_type" = "0" ]; then
			#update tf_padding=6 (829 Bytes)
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$tf_usr_tf_padding_idx=6
			#update UL NSS=1 and MCS=9
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$dl_usr_ul_psdu_rate_per_usp_idx=9
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser$usr_index x$rcr_tf_usr_psdu_rate_idx=9
		fi

		if [ "$ap_mrualloctones" != "" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannMRUUser'$usr_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			tmp_param="dl_mru_size$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannMRUUser${usr_index} x$dl_mru_perusp_idx=$tmp_val

			tmp_param="ul_mru_size$usr_index";eval tmp_val=\$$tmp_param
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannMRUUser${usr_index} x$ul_mru_idx=$tmp_val
		fi
	done

	sp_check_ldpc_support $5
	local static_plan_config=""
	# dynamically update STA index in DB according to: 20 MHz STA first, then NSS (higher to lower NSS)
	aid_idx_sorted_list=`get_sta_aid_idx_sorted_list $5`
	sortFile="/tmp/sigma-sort-sta-file"
	sortedFile="/tmp/sigma-sorted-sta-file"
	MRUFile="/tmp/sigma-sort-MRU-file"
	rm -f $sortFile $sortedFile $MRUFile
	for ap_aid_index in 1 2 3 4
	do
		if [ "$ap_mrualloctones" != "" ]; then
			aid_index=$((ap_aid_index))
		else
			aid_index=`aid_idx_out_of_list_get "${aid_idx_sorted_list}" "${ap_aid_index}"`
			aid_index=`echo ${aid_index//[!0-9]/}`
		fi
		[ $aid_index -gt 0 ] && sta_index=$((aid_index-1))
		ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
		[ -z "$glob_ap_sta_aid" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$dl_usr_usp_station_indexes_idx=$sta_index
		[ "$ap_type" = "EHT" ] && [ "$ap_num_ss" != "" -a "$ap_num_ss_mac" != "" ] && update_nss_in_plan $ap_aid_index $sta_index
		$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $sortFile
		if [ "$ap_mrualloctones" != "" ]; then
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannMRUUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $MRUFile
		fi
		ldpc_tmp_1="ldpc_${aid_index}"
		ldpc_support=`eval 'echo $'$ldpc_tmp_1`
		ap_get_debug_hostap_conf_or_Post_Up_idx=`grep 'sMuStaticPlannUser'$ap_aid_index $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
		[ "$ldpc_support" != "" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int
		
		if [ "$glob_ap_trigger_coding" = "BCC" ]; then
			ap_bcc_ldpc_int=0
		elif [ "$glob_ap_trigger_coding" = "LDPC" ]; then
			ap_bcc_ldpc_int=1
		fi
		Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlannUser${ap_aid_index} x$rcr_tf_usr_ldpc_idx=$ap_bcc_ldpc_int

	done
	
	tc_name=`get_test_case_name $glob_ssid`
	if [ "$tc_name" = "4.69.1" ]; then
		usersFile="/tmp/sigma-usrs-file"
		usr=""
		cnt=0
		while read -r line_1; do
			usr="$(echo "${line_1}" | cut -d' ' -f1)"
			ap_get_debug_hostap_conf_or_Post_Up_idx=`grep $usr $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx ${usr} x$dl_usr_sub_band_per_usp_idx=$cnt
			Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx ${usr} x$rcr_tf_usr_sub_band_idx=$cnt
			cnt=$((cnt+1))
			$UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' >> $usersFile
		done < $sortFile

		while read -r line; do
			static_plan_config="${static_plan_config} $(echo $line | sed "s/sMuStaticPlannUser[0-9]//g")"
		done < $usersFile

		rm -f $sortFile $sortedFile $usersFile
	else
		#TODO : Check for no regression in legacy through thorough testing
		#sort -k option is not supported !!!
		if [ "$MODEL" = "WAV700_AP" ]; then
			sed -i 's/sMuStaticPlannUser[0-9]//g' $sortFile
			sort -n $sortFile > $sortedFile
			while read -r line; do
				static_plan_config="${static_plan_config} ${line}"
			done < $sortedFile
		else
			sort -k2 -n $sortFile > $sortedFile
			while read -r line; do
				static_plan_config="$(echo $line | sed "s/sMuStaticPlannUser[0-9]//g") ${static_plan_config}"
			done < $sortedFile
		fi
		rm -f $sortFile $sortedFile
	fi

	if [ "$ap_mrualloctones" != "" ]; then
		debug_print "remove sMuStaticPlannUserMRU from sortPlan"
		sed -i 's/sMuStaticPlannMRUUser[0-9]//g' $MRUFile

		while read -r line; do
			debug_print "static_plan_config"
			static_plan_config="${static_plan_config} ${line}"
		done < $MRUFile
	fi

	# Change the length according to maximum NSS value of the connected STAs.
	[ "$mu_type" = "0" ] && ap_mu_tf_len=`sp_set_plan_tf_length $5 $ap_mu_tf_len`
	tc_name=`get_test_case_name $glob_ssid`
	if [ "$tc_name" = "4.45.1" ]; then
		ap_mu_tf_len="310"
	fi


	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	[ -n "$ap_mu_tf_len" ] && Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$rcr_com_tf_length_idx=$ap_mu_tf_len

	if [ "$global_emlsr_tb_ul_ofdma" = "1" ] && [ "$mu_type" = "0" ]; then
		#update PhaseRepetion=0 & muSequenceType=7
		Dynamic_set_get_helper "iw_off" $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x${dl_com_number_of_phase_repetitions_idx}=0
		set_get_helper $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx="sMuStaticPlann_common" x2=7
	fi

	uci_commit_wireless
	static_plan_config="$($UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' | sed 's/sMuStaticPlann_common//g' | sed 's/false/0/g') ${static_plan_config}"
	debug_print "CREATE COMMAND: Args $static_plan_config"
	
	info_print "plan for 4 user Ru not sorted: iw dev $interface_name iwlwav sMuStatPlanCfg $static_plan_config"
	splanconfigRUsorted=`sortPlan "$static_plan_config" 28 4`
	splanconfigDlUlRUsorted=`sortPlan "$splanconfigRUsorted" 37 4`

	if [ "$sortedList_28" != "$sortedList_37" ]
	then
		error_print "DL_RU and UP_RU not equal $sortedList_28"
		error_print "DL_RU and UP_RU not equal $sortedList_37"
		exit -1
	fi

	[ "$MODEL" = "WAV700_AP" ] && splanconfigDlUlRUsorted=`update_sid_in_static_plan "${splanconfigDlUlRUsorted}" $CURRENT_WLAN_NAME 4`

	if [ -e "/tmp/${glob_ssid}_tmp" ]; then
		static_plan_send_debug_infra 4
	else
		eval iw dev $interface_name iwlwav sMuStatPlanCfg $splanconfigDlUlRUsorted
		local res=$?
		info_print "plan for 4 user: iw dev $interface_name iwlwav sMuStatPlanCfg $splanconfigDlUlRUsorted"
		if [ $res != "0" ]; then
			error_print "$res in iw dev applying static plan"
			error_print ",errorCode,700"
			return
		fi
	fi
}

send_plan_off()
{
	#local interface_name sp_enable static_plan_config CURRENT_WLAN_NAME CURRENT_RADIO_UCI_PATH
	local interface_name=$1
	local CURRENT_WLAN_NAME=$1
	local CURRENT_RADIO_UCI_PATH=$2
	ap_get_debug_hostap_conf_or_Post_Up_idx=`get_sMuStaticPlann_common_idx_from_db $CURRENT_RADIO_UCI_PATH`
	info_print "send_plan_off $interface_name"
	Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$operation_mode_idx=0
	info_print "Dynamic_set_get_helper iw_off $CURRENT_WLAN_NAME $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx sMuStaticPlann_common x$operation_mode_idx=0"
	static_plan_config="$($UCI_CMD get $CURRENT_RADIO_UCI_PATH.$ap_get_debug_hostap_conf_or_Post_Up_idx | sed 's/=/ /g' | sed 's/sMuStaticPlann_common//g' | sed 's/false/0/g')"
	static_plan_config=`echo $static_plan_config`
	info_print "static_plan_config=$static_plan_config"
	if [ -n "$static_plan_config" ]
	then
		eval iw dev $interface_name iwlwav sMuStatPlanCfg $static_plan_config
		debug_print "iw plan off : iw dev $interface_name iwlwav sMuStatPlanCfg $static_plan_config"
	fi
}

# usage: handler_func <status: plan off/on> <interface> <number-of-users>
handler_func(){
	debug_print "handler_func $@"
	. /tmp/sigma_hf_arguments
	local plan_type current_wlan station_number curr_radio
	plan_type=$1
	current_wlan=$2
	station_number=$3
	glob_ofdma=$4

	if [ "$ucc_program" = "eht" ]; then
		debug_print "Set the RADIO_UCI_PATH correctly depending on the wlan name"
		[ "$current_wlan" = "wlan0.0" ] && curr_radio="wireless.radio0"
		[ "$current_wlan" = "wlan2.0" ] && curr_radio="wireless.radio2"
		[ "$current_wlan" = "wlan4.0" ] && curr_radio="wireless.radio4"
	fi

	#Skip sending 1-user plan for MIMO
	if ([ "$global_ap_mimo" == "dl" ] || [ "$global_ap_mimo" == "ul" ] || [ "$global_mu_txbf" == "enable" ]) && [ "$station_number" = "1" ]; then
		plan_type="plan_off"
	fi
	#Skip sending 3-user plan if Preamble Puncturing was not enabled
	if [ "$global_ap_preamble_puncture" != "enable" ] && [ "$station_number" = "3" ]; then
		plan_type="plan_off"
	fi
	ap_get_debug_hostap_conf_or_Post_Up_idx=`grep  -w 'twt_responder_support' $ETC_CONFIG_WIRELESS_PATH | awk '{print $2}' | sort -u`
	glob_twt_respsupport=`$UCI_CMD get $current_radio.$ap_get_debug_hostap_conf_or_Post_Up_idx`
	glob_twt_respsupport="${glob_twt_respsupport#*=}"
	case "$plan_type" in
		"plan_off")
			if [ "$ucc_program" != "eht" ]; then
				send_plan_off ${current_wlan/.0} $current_radio
			else
				send_plan_off ${current_wlan/.0} $curr_radio
			fi
		;;
		"plan_on")
			if [ "$ucc_program" != "eht" ]; then
				send_plan_for_${3}_users ${current_wlan/.0} $station_number $current_radio $glob_ssid $current_wlan
			else
				send_plan_for_${3}_users ${current_wlan/.0} $station_number $curr_radio $glob_ssid $current_wlan
			fi
		;;
		*)
			error_print "Error: wrong plan type." #error_print
		;;
	esac

}

send_fixed_rate_cfg() {
#Sending Fixed Rate with NSS=1 , MCS=9 for a specific set of test cases
    if [ -e $FORCE_EHT_FIXED_RATE_CFG_FILE_PATH ]; then
		#This is required for the cases where there are 2 associations simultaneously on 2 different interfaces
		#This is the logic used to fetch the interfaces received in the dwpal event "AP_STA_CONNECTED" by mbo daemon
		if1=`echo $@ | awk -F"<3>AP-STA-CONNECTED" '{print $2}' | awk '{print $1}'`
		if2=`echo $@ | awk -F"<3>AP-STA-CONNECTED" '{print $3}' | awk '{print $1}'`
		[ -n "$if1" ] && radio_ifaces="$if1"
		[ -n "$if1" && -n "$if2" ] && radio_ifaces="$if1 $if2"
		for interface in $radio_ifaces; do
			local master_iface=`echo $interface | awk -F"." '{print $1}'`
			local default_radio=`uci show wireless | grep $interface | cut -d"." -f2`
			local radio=`$UCI_CMD get wireless.$default_radio.device`
			ch_bw=`$UCI_CMD get wireless.$radio.htmode | sed 's/[^0-9]*//g'`
			convert_fixed_rate ${ch_bw}MHz
			if [ "$bw_converted" != "" ]; then
				local ap_cmd="iw dev $master_iface iwlwav sFixedRateCfg 1023 0 $bw_converted 8 1 9 2 0 0 0 2"
				local ap_res=`eval $ap_cmd`
				if [ "$?" = "0" ]; then
					debug_print "FixedRateCfg command sent : $ap_cmd"
				else
					debug_print "FixedRateCfg command has FAILED!"
				fi
			else
				debug_print "FixedRateCfg command is NOT sent due to incorrect BW ($bw_converted)!"
			fi
		done
    else
        debug_print "FixedRateCfg command is NOT required for the TC"
    fi
}

mbo_handler() {
	debug_print "mbo_handler $@"
	local ap_sta_connected=`echo $@ | grep AP-STA-CONNECTED`
	local rrm_beacon_rep=`echo $@ | grep RRM-BEACON-REP-RECEIVED`
	local wnm_notification=`echo $@ | grep AP-STA-WNM-NOTIF`
	#temporary place holder for scs handling tc:4.47.1
	local scs_add_notification=`echo $@ | grep AP-STA-SCS-ADD`
	local scs_rem_notification=`echo $@ | grep AP-STA-SCS-REM`

	if [ "$scs_add_notification" != "" ] || [ "$scs_rem_notification" != "" ] ; then
		get_common_uci_path
		get_interface_details $@
		curr_ifname=$CURRENT_IFACE_IFNAME
	fi

	if [ "$ucc_program" = "vht" ]; then
		if [ "$ap_sta_connected" != "" ]; then
			local radio=`uci show wireless | grep 5GHz | cut -d"." -f2`
			local default_radio=`uci show wireless | grep $radio | grep default_radio | head -n 1 | cut -d"." -f1-2`
			local interface=`uci show $default_radio.ifname | cut -d"=" -f2 | tr -d "'"`
			local num_sta=`run_dwpal_cli_cmd $interface.0 peerlist | grep "peer(s) connected" | awk '{print $1}'`
			if [ "2" = "$num_sta" ]; then
				ap_tmp=`iw dev $interface iwlwav sDoSimpleCLI 50 0x00010000 0x01ff01ff 0x00000101`
			fi
		fi
		#mbo_handler should be called in mbo TC only, for vht this is workaround to run 4.2.56 TC 
		return 
	fi
	if [ "$ucc_program" = "he" ] && [ "$ap_sta_connected" != "" ]; then
		local he_su_2ss_bf_war=`uci show wireless | grep ssid | grep -E "4.31.1|4.52.1"`
		if [ -n "$he_su_2ss_bf_war" ]; then
			local uci_vap=`echo $he_su_2ss_bf_war | awk -F"." '{print $1 "." $2}'`
			local ifname=`$UCI_CMD get $uci_vap.ifname | cut -d'.' -f1`
			debug_print "Disable BF for $ifname mode after STA connect to fix 2SS HE SU"
			ap_tmp=`iw dev $ifname iwlwav sBfMode 4`
		fi
	fi
	if [ "$ap_sta_connected" != "" ]; then
		debug_print "ap_sta_connected received"
		[ "$ucc_program" = "eht" ] && send_fixed_rate_cfg $ap_sta_connected
		local non_pref_chan=`echo $ap_sta_connected | sed -n 's/.*non_pref_chan=//p' | awk '{print $1}'`
		local channel=`echo $non_pref_chan | cut -d':' -f2`
		if [ "$channel" != "" ]; then
			if [ "$ucc_program" = "eht" ]; then
				update_neighbor_pref $channel
			else
				remove_neighbor_for_channel $channel
			fi
		fi
	elif [ "$rrm_beacon_rep" != "" ]; then
		debug_print "rrm_beacon_rep received"
		local op_class=`echo $rrm_beacon_rep | sed -n 's/.*op_class=//p' | awk '{print $1}'`
		local channel=`echo $rrm_beacon_rep | sed -n 's/.*channel=//p' | awk '{print $1}'`
		local bssid=`echo $rrm_beacon_rep | sed -n 's/.*bssid=//p' | awk '{print $1}'`
		is_channel_non_pref=""
		for single_neighbor in $CURRENT_NON_PREF_NEIGHBORS
		do
			curr_chan=`echo "$single_neighbor" | awk -F"," '{print $4}'`
			if [ "$curr_chan" = "$channel" ]; then
				is_channel_non_pref="1"
			fi
		done
		if [ "$bssid" != "" -a "$op_class" != "" -a "$channel" != "" -a "$channel" != "44" -a $is_channel_non_pref = "" ]; then
			CURRENT_NEIGHBORS=`cat /tmp/mbo_neighbors`
			CURRENT_NEIGHBORS="neighbor=${bssid},0,${op_class},${channel},9,253 $CURRENT_NEIGHBORS"
			echo $CURRENT_NEIGHBORS > /tmp/mbo_neighbors
		fi
	elif [ "$wnm_notification" != "" ]; then
		debug_print "wnm_notification received"
		merge_pref_non_pref_mbo_neighbors
		local non_pref_chan=`echo $wnm_notification | grep -oE "non_pref_chan=[0-9]*:[0-9]*:[0-9]*:[0-9]*"`
		while [ "$non_pref_chan" != "" ]; do
			non_pref_chan=`echo $non_pref_chan | awk '{print $1}'`
			local channel=`echo $non_pref_chan | cut -d':' -f2`
			local pref=`echo $non_pref_chan | cut -d':' -f3`
			if [ "$channel" != ""  ]; then
				if [ "$ucc_program" = "eht" ]; then
					add_neighbor_for_channel $channel
					[ "$pref" == "0" ] && update_neighbor_pref $channel
				else
					if [ "$pref" == "0" ]; then
						remove_neighbor_for_channel $channel
					else
						add_neighbor_for_channel $channel
					fi
				fi
			fi
			wnm_notification=`echo $wnm_notification | sed -n "s/$non_pref_chan//p"`
			non_pref_chan=`echo $wnm_notification | grep -oE "non_pref_chan=[0-9]*:[0-9]*:[0-9]*:[0-9]*"`
		done
	elif [ "$scs_add_notification" != "" ]; then
	    debug_print "scs_add received"	    
		curr_ifname=$(echo "$@" | grep -o wlan.\* | sed 's/.$//')
		handler_func "plan_on" $curr_ifname 1 &
	elif [ "$scs_rem_notification" != "" ]; then
	    debug_print "scs_rem received"
		curr_ifname=$(echo "$@" | grep -o wlan.\* | sed 's/.$//')
		handler_func "plan_off" $curr_ifname 1 &
	fi
}

get_sMuStaticPlann_common_idx_from_db()
{
	local CURRENT_RADIO_UCI_PATH=$1
	local db_idx=`uci show wireless | grep ${CURRENT_RADIO_UCI_PATH}.*sMuStaticPlann_common`
	db_idx=${db_idx##$CURRENT_RADIO_UCI_PATH.}
	echo ${db_idx%%=*}
}

randomize_macs()
{
	local radio 
        local radio_list="radio0 radio2"
        if [ `is_6g_supported` = "1" ]; then
        	radio_list="radio0 radio2 radio4"
        fi

	time_now=`date +%s`
	randd_1="${time_now:0:2}"
	randd_2="${time_now:(-2)}"
	
	#Incase we dont get 2 chars from date then,
	#add 11(0x10) to make sure we have 2 chars
	if [ "${#randd_1}" != "2" ]; then
		randd_1=$((randd_1+11))
	fi
	if [ "${#randd_2}" != "2" ]; then
		randd_2=$((randd_2+11))
	fi

	# If the first digit in randd_2 is 0 (eg. 05, 08)
	# removing the zero from the randd_2
	[ "${randd_2:0:1}" = "0" ] && randd_2=${randd_2:1:2}

	for radio in $radio_list
	do
		randd_2=$((randd_2+1))
		randd_2="${randd_2:0:2}"
		if [ "${#randd_2}" != "2" ]; then
			randd_2=$((randd_2+11))
		fi
		rand_mac="00:09:86:$randd_1:$randd_2:00"
		rand_mac_vap="00:09:86:$randd_1:$randd_2:01"
		debug_print $rand_mac $rand_mac_vap 
		radio_name=`uci show wireless | grep device=\'${radio}\' | head -n 1`
		radio_name=${radio_name%.*}
		radio_vap_name=`uci show wireless | grep device=\'${radio}\' | tail -1`
		radio_vap_name=${radio_vap_name%.*}
		
		$UCI_CMD set wireless.${radio}.macaddr=$rand_mac
		$UCI_CMD set ${radio_name}.macaddr=$rand_mac
		$UCI_CMD set ${radio_vap_name}.macaddr=$rand_mac_vap
	done
	
}

############################################################## End of planner ##############################################################

if [ "$source_flag" = "sigma-start.sh" ]; then

	info_print "Sigma-AP Agent version $CA_VERSION is running ..."

	debug_print "HW_MODEL:$MODEL"

	#important, set field separator properly
	IFS=$ORIG_IFS

	let ap_line_count=0

	while read line; do
	debug_print "read: >>>$line<<<"
	let ap_line_count+=1
	# remove special characters except comma, underscore, exclamation mark
	#tline=`echo $line | tr -dc '[:alnum:],_!\n'`
	#debug_print "tline: >>>$tline<<<"
	# For Windows hosts we need to remove carriage returns from the line
	tline=`echo $line | tr -d '\r'`
	# Delete trailing spaces
	tline=`echo $tline | sed 's/ *$//g'`
	debug_print "tline: >>>$tline<<<"
	IFS=,
	parse_command $tline
	IFS=$ORIG_IFS

	debug_print "lines parsed: $ap_line_count"
	debug_print "clearing all temp ap_ variables"

	variables=`set | grep "^ap_" | cut -d= -f1 | xargs echo `
	for var in $variables; do
		#debug_print "clearing $var"
		unset ${var}
	done

	unset variables
	unset token
	unset line
	unset tline
	done
	if [ "$tc_name" = "4.44.1" ] && [ "$OS_NAME" = "RDKB" ]
	then
		cli sys/pp/setDefensiveMode 0
	fi
	#if [ "$tc_name" = "4.2.30" ] && [ "$OS_NAME" = "RDKB" ]
	#then
		#cli sys/pp/setBridgeMode 0
	#fi
fi
