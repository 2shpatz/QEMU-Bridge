#!/usr/bin/env bash

# saner programming env: these switches turn some bugs into errors
set -o pipefail -o nounset

###
# Set default color codes for colorful prints.
###
RED_COLOR="\033[0;31m"
GREEN_COLOR="\033[0;32m"
YELLOW_COLOR="\033[1;33m"
BLUE_COLOR="\033[0;34m"
NEUTRAL_COLOR="\033[0m"

###
# Prints all given strings with the given color, appending a newline in the end.
# One should not use this function directly, but rather use "log-level" functions
# such as "info", "error", "success", etc.
# Arguments:
#       $1: Color to print in. Expected to be bash-supported color code
#       $2..N: Strings to print.
###
function cecho {
    local string_placeholders=""
    for ((i = 1; i < $#; i++)); do
        string_placeholders+="%s"
    done

    # shellcheck disable=SC2059
    printf "${1}${string_placeholders}${NEUTRAL_COLOR}\n" "${@:2}"
}

function error {
    cecho "$RED_COLOR" "$@" >&2
}

function warning {
    cecho "$YELLOW_COLOR" "$@"
}

function success {
    cecho "$GREEN_COLOR" "$@"
}

function info {
    cecho "$BLUE_COLOR" "$@"
}

function msg {
    cecho "$NEUTRAL_COLOR" "$@"
}


function show_usage {
    cat <<TEMPLATE_USAGE
Usage: ${PROGRAM_NAME} --image <qemu_image_path> [OPTIONS]

   Description: This program runs BalenaOS QEMU images with options

   Example: 
    ${PROGRAM_NAME} --image <path_to_image> --bridge

Options:
    -h, --help        	Show this message and exit
	-i, --image		  	Path to the qemu image [Mandatory]
    -B, --bridge        Creates bridge network between host and qemu (allows full communication)
	-P, --port_forward	(TBD) Port to forward from the guest qemu to the host 
							Usage: --port_forward <host_port> <qemu_port> (exp. --port_forward 8080 80)
    -R, --ram           Set the initial amount of guest memory
    -- max_ram          Set the maximum amount of guest memory (default: none)
    -C, --cpu           Set the number of CPUs

-----------------------------------------------------
TEMPLATE_USAGE
    exit 1
}
###
# Parse arguments/options using getopt, the almighty C-based parser.
###


###
# Set default values to be used throughout the script (global variables).
###
function set_defaults {
    PROGRAM_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
    PROGRAM_NAME="$(basename "$PROGRAM_PATH")"
    PROGRAM_DIR="$(dirname "$PROGRAM_PATH")"
    QEMU_IMAGE=""
    BRIDGE_NET_DEVICE=""
    BRIDGE_IP=""
    DEVICE_IP=""
    START_SSH_PORT=22400
    END_SSH_PORT=22500
    INIT_RAM=512
    NUM_OF_CPU=4
    NET_BRIDGE=0
    return 0
}

function parse_arguments {
	getopt --test >/dev/null
    	if (($? != 4)); then
        	error "I'm sorry, 'getopt --test' failed in this environment."
        	return 1
    	fi
	local short_options=i:B:P:h
    local long_options=image:,port_forward:,bridge,help
	if ! PARSED=$(
        getopt --options="$short_options" --longoptions="$long_options" \
            --name "$PROGRAM_PATH" -- "$@"
    ); then
        # getopt has complained about wrong arguments to stdout
        error "Wrong arguments to $PROGRAM_NAME" && return 2
    fi

	# read getopt’s output this way to handle the quoting right:
    eval set -- "$PARSED"

	while true; do
        case $1 in
        --)
            shift
            break
            ;;
        -h | --help)
            show_usage
            exit 0
            ;;
		-B | --bridge)
			NET_BRIDGE=1
			shift 1
			;;
        -i | --image)
            QEMU_IMAGE=$2
            shift 2
            ;;
		-P | --port_forward)
            shift 2
            ;;
        -R | --ram)
            INIT_RAM=$2
            shift 2
            ;;
        --max_ram)
            MAX_RAM=$2
            shift 2
            ;;
		-C | --cpu)
            NUM_OF_CPU=$2
            shift 2
            ;;
		*)
            error "Programming error"
            return 3
            ;;
        esac
    done
    if [[ -z "${QEMU_IMAGE}" ]]; then
        error "Providing a QEMU image is mandatory use the --image flag, you can download a new image from your Balena cloud"
        return 4
    fi
    return 0

}

# function port_forward
# {

# }

function set_virtual_bridge
{
    if [ ${NET_BRIDGE} -eq 0 ]; then
        return 0
    fi
    warning "set_virtual_bridge"
    # check if virbr0 exists and IP allocated 
    if ! ip -f inet addr show virbr0 | sed -En -e 's/.*inet ([0-9.]+).*/\1/p'; then
        warning "Setting up virtual bridge"
        # enable port forwarding
        sudo sysctl net.ipv4.ip_forward=1
        # start libvirtd service
        sudo systemctl enable libvirtd.service
        sudo systemctl start libvirtd.service
        # start the default network bridge
        sudo virsh net-autostart --network default
        sudo virsh net-start --network default
    fi
    # set up the qemu bridge helper
    if [[ $(sudo cat /etc/qemu/bridge.conf) != "allow virbr0*" ]]; then
        warning "Setting up qemu bridge helper"
        sudo touch /etc/qemu/bridge.conf
        sudo chown root:root /etc/qemu/bridge.conf
        sudo chmod 0777 /etc/qemu/bridge.conf
        sudo echo "allow virbr0" > /etc/qemu/bridge.conf
        sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper
    fi
    BRIDGE_NET_DEVICE="-netdev bridge,id=hn0,br=virbr0 -device virtio-net-pci,netdev=hn0,id=nic1"
    BRIDGE_IP=$(ip -f inet addr show virbr0 | sed -En -e 's/.*inet ([0-9.]+).*/\1/p')
}

# Function to find a free port in a range
function assign_free_ssh_port
{
    warning "Searching free port in range ${START_SSH_PORT} to ${END_SSH_PORT}"
    for (( port=${START_SSH_PORT}; port <= ${END_SSH_PORT}; port++ )); do
        (echo >/dev/tcp/localhost/$port) >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            info "Free port found: $port"
            SSH_PORT=$port
            return
        fi
    done
    
    echo "No free port found in the specified range."
}

function find_device_ip
{
    interface=$(ssh -p ${SSH_PORT} root@localhost ip route | awk -v gateway=${BRIDGE_IP} '$3 == gateway { sub(/.* dev /, ""); print $1 }')
    DEVICE_IP=$(ssh -p ${SSH_PORT} root@localhost ip -4 address show dev "$interface" | awk '/inet/ {print $2}' | cut -d '/' -f1)
}

function wait_for_ssh_connection
{
    timeout=60  # Maximum time to wait in seconds
    delay=5  # Delay between connection attempts in seconds

    # Wait for successful SSH connection
    elapsed_time=0
    while [[ $elapsed_time -lt $timeout ]]; do
        ssh -q -o ConnectTimeout=5 -p ${SSH_PORT} root@localhost exit >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            info "SSH connection successful"
            break
        fi
        sleep $delay
        elapsed_time=$((elapsed_time + delay))
    done

    if [[ $elapsed_time -ge $timeout ]]; then
        warning "Timed out waiting for SSH connection to $remote_host on port ${SSH_PORT}"
        return 1
    fi
}

function start_qemu
{   
    if ! assign_free_ssh_port; then
        return 1
    fi
    warning "Trying to start QEMU device"
	if sudo qemu-system-x86_64 \
		-device ahci,id=ahci \
		-drive file=${QEMU_IMAGE},media=disk,cache=none,format=raw,if=none,id=disk \
		-device ide-hd,drive=disk,bus=ahci.0 \
		-net nic,model=virtio -net user,hostfwd=tcp::${SSH_PORT}-:22222,${PORT_FORWARD:-} ${BRIDGE_NET_DEVICE:-} \
		-m ${INIT_RAM},${MAX_RAM:-} -display none -daemonize \
        -machine type=pc -smp ${NUM_OF_CPU} ; then 

        info "Starting QEMU device on background, please wait... (around one minute)"
        while :; do
            # Check if SSH port is open on the remote host
            if wait_for_ssh_connection; then
                success "QEMU device is up"
                if [ ${NET_BRIDGE} -eq 1 ]; then
                    find_device_ip  
                    if [[ -z "${DEVICE_IP}" ]]; then
                        error "Can't find device IP address"
                    else 
                        success "Device IP is: ${DEVICE_IP}"
                    fi
                fi
                info "Use port ${SSH_PORT} to ssh the device"
                return 0
            fi
        done
    fi
    error "Failed to start qemu device"
    return 2
}


function main
{

    if ! set_defaults; then
        error "Failed setting default values, aborting"
        return 1
    fi

    if ! parse_arguments "$@"; then
        return 2
    fi

    if ! set_virtual_bridge; then
        return 3
    fi

    if ! start_qemu; then
        return 4
    fi 
    
    return 0
}

main "$@"