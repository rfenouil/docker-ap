FROM balenalib/rpi-raspbian:stretch
MAINTAINER rfenouil

# Update the repos
RUN apt-get update && apt-get upgrade -y

# Install access point and DHCP servers
RUN apt-get install -y hostapd dnsmasq 

