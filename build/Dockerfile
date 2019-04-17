FROM balenalib/rpi-raspbian:stretch
MAINTAINER rfenouil

# Update repository
RUN apt-get update && apt-get upgrade -y

# Install access point and DHCP servers
RUN apt-get install -y hostapd dnsmasq 

# Copy hostapd file containing path to config file (mounted during container startup)
ADD etc_default_hostapd /etc/default/hostapd


