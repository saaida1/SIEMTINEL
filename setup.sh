#!/bin/bash

# Function to detect the Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
    elif type lsb_release >/dev/null 2>&1; then
        DISTRO=$(lsb_release -si)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DISTRO=$DISTRIB_ID
    elif [ -f /etc/debian_version ]; then
        DISTRO='Debian'
    else
        DISTRO='Unknown'
    fi
    echo $DISTRO
}
# Function to install suricata and copy the suricata.yml file
install_suricata() {
    DISTRO=$(detect_distro)
    sudo apt install wget curl nano software-properties-common dirmngr apt-transport-https gnupg gnupg2 ca-certificates lsb-release ubuntu-keyring unzip -y
    sudo add-apt-repository ppa:oisf/suricata-stable -y
    sudo apt-get update
    sudo apt-get install suricata -y
    sudo systemctl enable suricata
    sudo systemctl stop suricata
    # community-id: true in /etc/suricata/suricata.yaml
    sudo sed -i 's/# community-id: false/community-id: true/g' /etc/suricata/suricata.yaml
    # find the line pcap: and under it, set the value of the variable interface to the device name for your system
    sudo sed -i 's/# pcap:/pcap:/g' /etc/suricata/suricata.yaml
    #replace the eth0 with the interface variable chosen by the user in the sensor_setup_info() function
    sudo sed -i "s/interface: eth0/interface: $interface/g" /etc/suricata/suricata.yaml
    # #use-mmap: yes
    sudo sed -i 's/# use-mmap: yes/use-mmap: yes/g' /etc/suricata/suricata.yaml
    # enable capture-settings
    sudo suricata-update
    sudo suricata-update list-sources
    #TODO add the wazuuh rules
    sudo suricata-update enable-source tgreen/hunting
    sudo suricata -T -c /etc/suricata/suricata.yaml -v
    sudo systemctl start suricata
}


suricata_network_setup(){
    # interface configuration
    sudo ip link set $interface multicast off
    sudo ip link set $interface promisc on
    sudo ip link set $interface up
}
is_valid_interface() {
    local interface="$1"
    ip link show "$interface" >/dev/null 2>&1
}

sensor_setup_info(){
    # using whiptail to list all intefaces and make the user choose one to use as sniffer 
    interfaces=$(ip link show | awk -F': ' '/state UP/ {print $2}')
    # choose an interface to use as sniffer
    echo "Available network interfaces:"
    select interface in $interfaces; do
        if is_valid_interface "$interface"; then
            echo "Interface chosen: $interface"
            break
        else
            echo "Invalid interface. Please try again."
        fi
    done

    # If a valid interface is chosen, proceed with the script
    if [ -n "$interface" ]; then
        # Your script logic here
        echo "Continuing with interface: $interface"
    else
        echo "No valid interface selected. Exiting."
        exit 1
    fi
    # ask for the IP address of the controller
    CONTROLLER_IP=$(whiptail --inputbox "Enter the IP address of the controller" 8 78 --title "Controller IP" 3>&1 1>&2 2>&3)
    echo "Controller IP: $CONTROLLER_IP"
    # ask for the username of the controller and the password
    CONTROLLER_USERNAME=$(whiptail --inputbox "Enter the username of the controller" 8 78 --title "Controller Username" 3>&1 1>&2 2>&3)
    echo "Controller Username: $CONTROLLER_USERNAME"
    CONTROLLER_PASSWORD=$(whiptail --passwordbox "Enter the password of the controller" 8 78 --title "Controller Password" 3>&1 1>&2 2>&3)
    # password as **
    echo "Controller Password: **"
}


# Function to install Docker
install_docker() {
    DISTRO=$(detect_distro)
    case "$DISTRO" in
        "ubuntu" | "debian")
            sudo apt-get update
            sudo apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
            sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose
            ;;
        "centos" | "rhel")
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io
            ;;
        "fedora")
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io
            ;;
        *)
            echo "Unsupported distribution: $DISTRO"
            exit 1
            ;;
    esac
}

install_latest_filebeat() {
    # get the version of filebeat from .env file 
    DISTRO=$(detect_distro)
    VERSION=$(grep ELASTIC_VERSION .env | cut -d '=' -f2)
    case "$DISTRO" in
        "ubuntu" | "debian")
            curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-$VERSION-amd64.deb
            sudo dpkg -i filebeat-$VERSION-amd64.deb
            ;;
        "centos" | "rhel")
            curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-$VERSION-x86_64.rpm
            sudo rpm -vi filebeat-$VERSION-x86_64.rpm
            ;;
        "fedora")
            curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-$VERSION-x86_64.rpm
            sudo rpm -vi filebeat-$VERSION-x86_64.rpm
            ;;
        *)
            echo "Unsupported distribution: $DISTRO"
            exit 1
            ;;
    esac
}

interactive_setup_filebeat() {
    sudo cp filebeat/filebeat.yml /etc/filebeat/filebeat.yml

    sudo sed -i "s/CONTROLLER_IP/$CONTROLLER_IP/g" /etc/filebeat/filebeat.yml
    # replace CONTROLLER_USERNAME in filebeat/filebeat.yml with the actual username
    sudo sed -i "s/CONTROLLER_USERNAME/$CONTROLLER_USERNAME/g" /etc/filebeat/filebeat.yml
    # replace CONTROLLER_PASSWORD in filebeat/filebeat.yml with the actual password
    sudo sed -i "s/CONTROLLER_PASSWORD/$CONTROLLER_PASSWORD/g" /etc/filebeat/filebeat.yml
    # add /var/log/suricata/eve.json to the paths in filebeat/filebeat.yml
    sudo sed -i 's/# paths:/paths:/g' /etc/filebeat/filebeat.yml
    sudo sed -i 's/#   - \/var\/log\/*.log/   - \/var\/log\/suricata\/eve.json/g' /etc/filebeat/filebeat.yml
    # enable and start the filebeat service
    sudo systemctl enable filebeat
    # enable the suricata module
    sudo filebeat modules enable suricata
    # setup the suricata module
    sudo filebeat setup
    # start the filebeat service
    sudo systemctl start filebeat

}

start_project() {
    sudo docker compose up setup
    sudo docker compose up -d
}


install_kafka() {
    # install java
    sudo apt-get update
    sudo apt-get install openjdk-8-jdk -y
    #install zookeeper 
    sudo apt-get install zookeeperd -y
    # download and extract kafka
    wget https://downloads.apache.org/kafka/3.7.0/kafka_2.12-3.7.0.tgz
    tar -xzf kafka_2.13-3.7.0.tgz
    cd kafka_2.13-3.7.0
    # start zookeeper
    bin/zookeeper-server-start.sh config/zookeeper.properties
    # start kafka
    bin/kafka-server-start.sh config/server.properties

    # create a topic
    bin/kafka-topics.sh --create --topic siemtinel --bootstrap-server localhost:9092
    # list the topics
   
}

main() {
    choice=$(whiptail --title "Machine Type" --menu "Is this machine a controller or a sensor?" 15 60 2 \
        "1" "Controller" \
        "2" "Sensor" \
        3>&1 1>&2 2>&3)
        case $choice in
            1)
                install_docker
                start_project
                ;;
            2)
                sensor_setup_info
                install_suricata
                suricata_network_setup
                install_latest_filebeat
                interactive_setup_filebeat
                #install_kafka
                ;;
            *)
                echo "Invalid choice"
                ;;
        esac
}

main
