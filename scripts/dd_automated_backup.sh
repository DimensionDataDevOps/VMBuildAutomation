#!/bin/bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

backups_help(){
cat <<-END
dd_nimsoft.sh - Install or Uninstall nimsoft from a host

Usage:
------
    -h | --help
      Display this help file
    -i | --install
       Install client
    -u | --uninstall
       Uninstall client
    -c | --clienttype <clienttype>
      Which client type to use (i.e. "FA.Linux")
    -s | --storagepolicy <policy>
      The storage policy to use (i.e. "14 Day Storage Policy")
    -e | --schedulepolicy <policy>
      The schedule policy to use (i.e. "12AM - 6AM")
    -l | --serviceplan <serviceplan>
      The backups service plan to use (i.e "Enterprise")
    -u | --username <user>
      Cloud UI username
    -p | --password <pass>
      Cloud UI password
    -n | --notify
      Email address for notification when backups go bad (i.e. test@example.com)

Example:
-------
Installation:
dd_automated_backup.sh --install -c FA.Linux -s "14 Day Storage Policy" -e "12AM - 6AM" -n jeff.dunham@itaas.dimensiondata.com -l Enterprise -u dduser -p pass

Uninstallation:
dd_automated_backup.sh --uninstall
END
exit 1
}

while [[ $# > 0 ]]
do
key="$1"
case $key in
    -i|--install)
    install=true
    ;;
    --uninstall)
    uninstall=true
    ;;
    -c|--clienttype)
    clienttype="$2"
    shift # past argument
    ;;
    -s|--storagepolicy)
    storagepol="$2"
    shift # past argument
    ;;
    -e|--schedulepolicy)
    schedulepol="$2"
    shift # past argument
    ;;
    -l|--serviceplan)
    serviceplan="$2"
    shift # past argument
    ;;
    -u|--username)
    username="$2"
    shift # past argument
    ;;
    -p|--password)
    password="$2"
    shift # past argument
    ;;
    -n|--notify)
    notify="$2"
    shift # past argument
    ;;
    --installonly)
    installonly=True
    ;;
    -h|--help)
    backups_help
    ;;
    *)
            # unknown option
    ;;
esac
shift # past argument or value
done

get_didata_script(){
    didata=$(which didata)
}

fn_distro(){
  arch=$(uname -m)
  kernel=$(uname -r)
  if [ -f /etc/lsb-release ]; then
    os=$(lsb_release -s -d)
  elif [ -f /etc/debian_version ]; then
    os="Debian $(cat /etc/debian_version)"
  elif [ -f /etc/redhat-release ]; then
    os=`cat /etc/redhat-release`
  else
    os="$(uname -s) $(uname -r)"
  fi
}

yum_install_dependencies(){
    echo "Installing yum dependencies"
    yum install -y git unzip
}

apt_install_dependencies(){
    echo "Installing apt dependencies"
    apt-get update -y
    apt-get install -y git unzip
}

install_pip(){
    echo "Installing pip"
    curl -sL https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python ./get-pip.py
}

install_dependencies(){
    if [[ "$os" =~ "Red Hat" ]]; then
       yum_install_dependencies
    elif [[ "$os" =~ "Cent" ]]; then
       yum_install_dependencies
    elif [[ "$os" =~ "Ubuntu" ]]; then
       apt_install_dependencies
    else
       echo "Could not determine OS type"
       exit 1
    fi
    install_pip
    pip install git+https://github.com/jadunham1/libcloud.git@feature/backups_fixing --upgrade
    pip install git+https://github.com/DimensionDataDevOps/didata_cli.git@develop --upgrade
}

add_backup_client(){
    info=$($didata backup info --serverFilterIpv6 $ipv6_addr)
    if [[ $info == *$clienttype* ]]; then
        echo "Client $clienttype is already set up for $serverid"
        return 0
    fi
    # Sometimes it takes a bit to register so we'll try a few times before failing
    COUNTER=0
    currently_enabling="Backup is currently being enabled for Server"
    while [  $COUNTER -lt 10 ]; do
        output=$(didata backup add_client --serverFilterIpv6 $ipv6_addr --triggerOn ON_FAILURE --notifyEmail "$notify" --clientType "$clienttype" --storagePolicy "$storagepol" --schedulePolicy "$schedulepol")
        rc=$?
        if [[ $rc != 0 ]]; then
            if [[ $output == *$currently_enabling* ]]; then
               echo "Backups are still enabling, retrying adding client in 30 seconds..."
            else
               echo "Something went wrong output $output ... retrying in 30 seconds..."
            fi
            sleep 30
            let COUNTER=COUNTER+1
        else
            echo "Successfully added client $clienttype"
            return 0
        fi
    done
    if [[ $rc != 0 ]]; then
        echo "Attempted to add client $COUNTER times with no success."
        exit 1
    fi
}

get_download_url(){
    COUNTER=0
    while [  $COUNTER -lt 10 ]; do
        download_url=$(didata backup download_url --serverFilterIpv6 $ipv6_addr)
        rc=$?
        if [[ $rc != 0 ]]; then
            sleep 30
            let COUNTER=COUNTER+1
        else
            echo "Found download url $download_url"
            return 0
        fi
    done
    if [[ $rc != 0 ]]; then
        echo "Attempted to find download_url $COUNTER times with no success."
        exit 1
    fi
}

enable_backups(){
    ipv6_addr=$(ip -6 addr | grep global | awk {'print $2'} | cut -d\/ -f1)
    already_enabled_string="Cloud backup for this server is already enabled or being enabled"
    echo "IPv6 Address $ipv6_addr"
    COUNTER=0
    while [  $COUNTER -lt 10 ]; do
        backup_enable=$($didata backup enable --serverFilterIpv6 $ipv6_addr --servicePlan $serviceplan)
        rc=$?
        if [[ $rc != 0 ]]; then
            if [[ $backup_enable == *$already_enabled_string* ]]; then
                echo "Backups are already enabled for $serverid"
                return 0
            fi
            echo "Unable to start backups $backup_enable.  Retrying in 30 seconds..."
            sleep 30
            let COUNTER=COUNTER+1
        else
            echo "Backups enabled for server.  Sleeping 30 seconds after enabling..."
            return 0
        fi
    done
    if [[ $rc != 0 ]]; then
        echo "Attempted to find download_url $COUNTER times with no success."
        exit 1
    fi
}

install_client(){
    date
    if [[ ! -e '/usr/bin/simpana' ]]; then
        echo "Installing backup client"
        get_download_url
        cd /tmp
        mkdir Backup-Client
        cd /tmp/Backup-Client
        curl -L "$download_url" -o backup-client.zip
        unzip -o ./backup-client.zip
        bash ./install.sh
        echo "Sleeping for 30 seconds after installation of the client"
        sleep 30
    else
        echo "Backup client already installed, skipping..."
    fi
    date
}

check_backup(){
    COUNTER=0
    if [ -z $BACKUP_JOB_ID ]; then
        echo "No backup job id found"
        exit 1
    fi
    while [  $COUNTER -lt 10 ]; do
        check_backup_output=$($didata backup info --serverFilterIpv6 $ipv6_addr)
        rc=$?
        if [[ $rc != 0 ]]; then
            sleep 30
            let COUNTER=COUNTER+1
        else
            if [[ $check_backup_output == *$BACKUP_JOB_ID* ]]; then
                break
            fi
            echo "Haven't found job id $BACKUP_JOB_ID attempting again in 30 seconds..."
            sleep 30
            let COUNTER=COUNTER+1
        fi
    done
    if [[ $rc != 0 ]]; then
        echo "Could not get backup information."
        exit 1
    fi

    BACKUP_FINISHED=false
    COUNTER=0
    while [ $COUNTER -lt 500 ]; do
        check_backup_output=$($didata backup info --serverFilterIpv6 $ipv6_addr)
        rc=$?
        if [[ $rc != 0 ]]; then
            echo "Bad output from server $check_backup_output . Retrying in 30 seconds..."
            sleep 30
            let COUNTER=COUNTER+1
        else
            if [[ $check_backup_output != *$BACKUP_JOB_ID* ]]; then
                echo "Finished backup!"
                BACKUP_FINISHED=true
                break
            fi
            PERCENTAGE=$(echo "$check_backup_output" | grep "Percentage Complete" | cut -d' ' -f3)
            echo "Percentage done: $PERCENTAGE"
            sleep 30
            let COUNTER=COUNTER+1
        fi
    done
    if [[ $BACKUP_FINISHED != true ]]; then

        exit 1
    fi

}

do_full_backup(){
    COUNTER=0
    date
    while [  $COUNTER -lt 10 ]; do
        echo -n "Starting full backup... this may take some time... "
        (/opt/simpana/RestoreApp/restoreClient.pl --full-backup-now > /tmp/restore_client_output) &
        spinner
        output=$(cat /tmp/restore_client_output)
        rc=$?
        BACKUP_JOB_ID=$(echo "$output" | grep Started | cut -d' ' -f3 | tr -d '.')
        re='^[0-9]+$'
        if [[ $rc != 0 || ! $BACKUP_JOB_ID =~ $re  ]]; then
            echo "Job failed to start, trying again in 30 seconds"
            sleep 30
            let COUNTER=COUNTER+1
        else
            echo "Backup job successfully started: $BACKUP_JOB_ID"
            break
        fi
    done
    if [[ $rc != 0 ]]; then
        echo "FAILURE: Attempted to start full backup $COUNTER times with no success."
        echo "$output"
        exit 1
    fi
    date
}

spinner(){
    local pid=$!
    local delay=0.75
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

check_variables(){
    if [ "$install" = true ] && [ "$uninstall" = true ]; then
        echo "You can't uninstall and install, please pick one!"
        exit 1
    elif [ ! "$install" = true ] && [ ! "$uninstall" =  true ]; then
        echo "You have to choose either install (--install) or uninstall (--uninstall)"
        exit 1
    fi
    if [ "$install" = true ]; then
        if [ -z $clienttype ]; then
            echo "Need to specify a -c|--clienttype variable (i.e FA.Linux)"
            exit 1
        fi
        if [ -z "$storagepol" ]; then
            echo "Need to specify a -s|--storagepol variable (i.e \"14 Days\")"
            exit 1
        fi
        if [ -z "$schedulepol" ]; then
            echo "Need to specify a -e|--schedulepol variable (i.e \"12AM - 6AM\")"
            exit 1
        fi
        if [ -z "$notify" ]; then
            echo "Need to specify a -n|--notify variable (Email Address)"
            exit 1
        fi
        if [ -z "$username" ]; then
            echo "Need to specify a -u|--username variable (Dimension Data Account Username)"
            exit 1
        fi
        if [ -z "$password" ]; then
            echo "Need to specify a -p|--password variable (Dimension Data Account Password)"
            exit 1
        fi
        if [ -z "$serviceplan" ]; then
            echo "Need to specify a -l|--serviceplan variable (i.e. Enterprise)"
            exit 1
        fi
        export DIDATA_USER=$username
        export DIDATA_PASSWORD=$password
    fi
}

uninstall_backups(){
    if [[ -e '/usr/bin/simpana' ]]; then
        /opt/simpana/simpana/installer/cvpkgrm -silent
    else
        echo "Simpana does not exists on host, no need to uninstall"
    fi
}

check_variables

if [ "$install" = true  ]; then
    echo "Installing backups"
    fn_distro
    get_didata_script
    if [ -z $didata ]; then
        echo "DiData not installed, installing all dependencies"
        install_dependencies
    fi
    get_didata_script
    if [ ! -e $didata ]; then
        echo "didata still not installed something has gone wrong"
        exit 1
    fi
    enable_backups
    add_backup_client
    install_client
    do_full_backup
    check_backup
elif [ "$uninstall" = true ]; then
    echo "Uninstalling backups"
    uninstall_backups
else
    echo "We should never GET HERE"
    exit 1
fi
