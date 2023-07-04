#!/usr/bin/env bash

# saner programming env: these switches turn some bugs into errors
set -o pipefail -o nounset



PROGRAM_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
PROGRAM_NAME="$(basename "$PROGRAM_PATH")"
PROGRAM_DIR="$(dirname "$PROGRAM_PATH")"

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
	-P, --port_forward	Port to forward from the guest qemu to the host 
							Usage: --port_forward <host_port> <qemu_port> (exp. --port_forward 8080 80)
    
-----------------------------------------------------
TEMPLATE_USAGE
    exit 1
}
###
# Parse arguments/options using getopt, the almighty C-based parser.
###

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
		-S | --ssh)
			SSH=1
			shift 1
			;;
		-P | --port_forward)
			host
		
		*)
            error "Programming error"
            return 3
            ;;
        esac
    done




}

function port_forward
{

}

function set_virtual_bridge
{
    # check if virbr0 exists and IP allocated 
    if ! ip -f inet addr show virbr0 | sed -En -e 's/.*inet ([0-9.]+).*/\1/p'; then
    {
        # enable port forwarding
        sudo sysctl net.ipv4.ip_forward=1
        # start libvirtd
        sudo systemctl enable libvirtd.service
        sudo systemctl start libvirtd.service
        # start the default network bridge
        sudo virsh net-autostart --network default
        sudo virsh net-start --network default
        # set up the 
    }
}

function start_qemu
{
	qemu-system-x86_64 \
		-device ahci,id=ahci \
		-drive file=${QEMU_IMAGE},media=disk,cache=none,format=raw,if=none,id=disk \
		-device ide-hd,drive=disk,bus=ahci.0 \
		-net nic,model=virtio -net user${PORT_FORWARD} \
		--netdev tap,id=mynet0 -m 512 -nographic -machine type=pc -smp 4
}


