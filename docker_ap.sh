#!/bin/bash        

#title           :docker_ap.sh
#description     :This script will configure a Debian-based system
#                 for running a wireless access point inside a
#                 docker container.
#                 The docker container has unique access to the
#                 physical wireless interface. 
#author          :Fran Gonzalez (2015)
#modifications   :Romain Fenouil (2019)
#github/docker   :rfenouil/docker-ap
#usage           :bash docker_ap <start|stop> [interface]
#dependencies	 :docker, iw, pgrep, grep, iptables, cat, ip,
#                 bridge-utils, rfkill
#=============================================================


# Environment variables
#AP_FORCEDEFAULTROUTE: if "true" (case insensitive), force the use of specified interface even if it is the default route in your system (you will likely lose internet connectivity). Exit with error otherwise.

# WLAN parameters
SSID="ssid_test"
PASSPHRASE="blablabla"
HW_MODE="g"
CHANNEL="0"
WPA_MODE="WPA-PSK"

# Network parameters
IP_AP="192.168.100.1"
SUBNET="192.168.100.0"
NETMASK="/24"
DHCP_START="192.168.100.10"
DHCP_END="192.168.100.100"
DNS_SERVER="8.8.8.8"

# Other parameters
PATHSCRIPT=$(readlink -m ${0%/*})
DOCKER_IMAGE="rfenouil/docker-ap"
DOCKER_NAME="${DOCKER_IMAGE#*/}-container"

# For debug
#git clone https://github.com/rfenouil/docker-ap.git
#cd docker-ap
#PATHSCRIPT=$(pwd)
#IFACE="wlx0013ef801b4e"



#### Helper functions

show_usage () {
    echo -e "Usage: $0 <start|stop> [interface]"
    exit 1
}

if [[ "$1" == "help" ]] || [[ "$#" -eq 0 ]]; then
    show_usage
fi

# Check run as root
if [[ "$UID" -ne "$ROOT_UID" ]]; then
    echo "You must be root to run this script!"
    exit 1
fi

# Argument check
if [[ "$#" -eq 0 ]] || [[ "$#" -gt 2 ]]; then 
    show_usage
fi



#### Init: check/build docker image, check for interface/services and bring it up, generate config files

init () 
{
    ### Interface

    IFACE="$1"
    
    # Check that the requested iface is available
    if ! [[ -e /sys/class/net/"$IFACE" ]]; then
        echo -e "[ERROR] The interface provided does not exist. Exiting..."
        exit 1
    fi
    
    # Check that the given interface is not used by the host as the default route
    if [[ $(ip r | grep default | cut -d " " -f5) == "$IFACE" ]]; then
        echo -en "[INFO] The selected interface is configured as the default route... "
        if [[ "${AP_FORCEDEFAULTROUTE,,}" == "true" ]]; then
            echo -e "Proceeding (AP_FORCEDEFAULTROUTE=true)... You will likely lose internet connectivity."
        else
            echo -e "Exiting... Set env 'AP_FORCEDEFAULTROUTE=true' to override."
            exit 1
        fi    
	fi
    
    # Find the physical interface for the given wireless interface
    PHY=$(cat /sys/class/net/"$IFACE"/phy80211/name)
    
    # Check if hostapd is running in the host
    hostapd_pid=$(pgrep hostapd)
    if [[ ! "$hostapd_pid" == "" ]]; then
       echo -e "[INFO] hostapd service is already running in the system, make sure you use a different wireless interface..."
    fi
    
    # Unblock wifi and bring the wireless interface up
    echo -e "[INFO] Unblocking wifi and setting ${IFACE} up"
    rfkill unblock wifi
    ip link set "$IFACE" up
    
	
    
    ### Generating hostapd.conf file. Gets mounted during docker startup at: '/etc/hostapd/hostapd.conf'
    echo -e "[+] Generating hostapd.conf"
    sed -e "s/_SSID/$SSID/g" -e "s/_IFACE/$IFACE/" -e "s/_HW_MODE/$HW_MODE/g" -e "s/_CHANNEL/$CHANNEL/g" -e "s/_PASSPHRASE/$PASSPHRASE/g" -e "s/_WPA_MODE/$WPA_MODE/g" "$PATHSCRIPT"/templates/hostapd.template > "$PATHSCRIPT"/hostapd.conf
    
    ### Generating dnsmasq.conf file. Gets mounted during docker startup at: '/etc/dnsmasq.conf'
    echo -e "[+] Generating dnsmasq.conf" 
    sed -e "s/_DNS_SERVER/$DNS_SERVER/g" -e "s/_IFACE/$IFACE/" -e "s/_SUBNET_FIRST/$DHCP_START/g" -e "s/_SUBNET_END/$DHCP_END/g" "$PATHSCRIPT"/templates/dnsmasq.template > "$PATHSCRIPT"/dnsmasq.conf
    
	# Check if a AP and DHCP configuration files exist
    #if [[ ! -f "hostapd.conf" ]] || [[ ! -f "dnsmasq.conf" ]]; then
    #    echo -e "[ERROR] Could not find configuration files for access point (hostapd.conf) or DHCP (dnsmasq.conf) servers. Exiting..."
    #    exit 1
    #fi
    
    
    
    ### Docker check/build
    
    # Checking if the docker image has been already pulled/built
    IMG_CHECK=$(docker images -q $DOCKER_IMAGE)
    if [[ -n "$IMG_CHECK" ]]; then
        echo -e "[INFO] Docker image $DOCKER_IMAGE found"
    else
        echo -e "[INFO] Docker image $DOCKER_IMAGE not found"
        echo -e "[+] Building the image $DOCKER_IMAGE (Grab a coffee...)"
        docker build -q -t $DOCKER_IMAGE .
    fi
}



#### Start: Start container and assign physical interface to its network namespace

service_start ()
{
    IFACE="$1"
    echo -e "[+] Starting the docker container with name $DOCKER_NAME"
	# Run docker and put required configuration files in appropriate folders (using volumes)
    docker run -dt --name $DOCKER_NAME --net=bridge --cap-add=NET_ADMIN --cap-add=NET_RAW \
      -v "$PATHSCRIPT"/hostapd.conf:/etc/hostapd/hostapd.conf \
      -v "$PATHSCRIPT"/dnsmasq.conf:/etc/dnsmasq.conf \
      $DOCKER_IMAGE > /dev/null 2>&1
    pid=$(docker inspect -f '{{.State.Pid}}' $DOCKER_NAME)
    
    # Assign phy wireless interface to the container 
    mkdir -p /var/run/netns
    ln -s /proc/"$pid"/ns/net /var/run/netns/"$pid"
    iw phy "$PHY" set netns "$pid"
    
    ### Assign an IP to the wifi interface
    echo -e "[+] Configuring $IFACE with IP address $IP_AP"
    ip netns exec "$pid" ip addr flush dev "$IFACE"
    ip netns exec "$pid" ip link set "$IFACE" up
    ip netns exec "$pid" ip addr add "$IP_AP$NETMASK" dev "$IFACE"
	
    ### iptables rules for NAT (translate/masquerade all addresses going through this interface output)
    echo "[+] Adding natting rule to iptables (container)"
    ip netns exec "$pid" iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    
    ### Enable IP forwarding
    echo "[+] Enabling IP forwarding (container)"
    ip netns exec "$pid" echo 1 > /proc/sys/net/ipv4/ip_forward
    
    ### start hostapd and dnsmasq in the container (started on boot automatically ?)
    #echo -e "[+] Starting hostapd and dnsmasq in the docker container $DOCKER_NAME"
    docker exec "$DOCKER_NAME" service hostapd start
    docker exec "$DOCKER_NAME" service dnsmasq start
    
    # For debug (get an interactive shell in running container):
    #docker exec -it $DOCKER_NAME bash
}



#### Stop: 

service_stop () 
{
    IFACE="$1"
    
    echo -e "[-] Stopping $DOCKER_NAME"
    docker stop $DOCKER_NAME
    echo -e "[-] Removing $DOCKER_NAME"
    docker rm $DOCKER_NAME
     
    echo "[-] Removing IP address in $IFACE"
    ip addr del "$IP_AP$NETMASK" dev "$IFACE"
    # Clean up dangling symlinks in /var/run/netns
    find /var/run/netns -type l -delete
}


if [[ "$1" == "start" ]]; then
    if [[ -z "$2" ]]; then
        echo -e "[ERROR] No interface provided. Exiting..."
        exit 1
    fi
    IFACE=${2}
    service_stop "$IFACE"
    clear
    init "$IFACE"
    service_start "$IFACE"
elif [[ "$1" == "stop" ]]; then
    if [[ -z "$2" ]]; then
        echo -e "[ERROR] No interface provided. Exiting..."
        exit 1
    fi
    IFACE=${2}
    service_stop "$IFACE"
else
    echo "Usage: $0 <start|stop> <interface>"
fi


