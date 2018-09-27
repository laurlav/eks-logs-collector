#!/usr/bin/env bash

# Copyright 2017 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may
# not use this file except in compliance with the License. A copy of the
# License is located at
#
#       http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.
#
# This script generates a file in go with the license contents as a constant

# Set language to C to make sorting consistent among different environments.

export LANG="C"
export LC_ALL="C"

# Global options
PROGRAM_VERSION="0.0.1"
PROGRAM_SOURCE="https://github.com/awslabs/amazon-eks-ami"
PROGRAM_NAME="$(basename "$0" .sh)"
PROGRAM_DIR="/opt/log-collector"
COLLECT_DIR="/tmp/${PROGRAM_NAME}"
DAYS_7=$(date -d "-7 days" '+%Y-%m-%d %H:%M')
INSTANCE_ID=""
INIT_TYPE=""
PACKAGE_TYPE=""

COMMON_DIRECTORIES=(
  kernel
  system
  docker
  storage
  var_log
  networking
  ipamd # eks
  sysctls # eks
  kubelet # eks
  cni # eks
)

COMMON_LOGS=(
  syslog
  messages
  aws-routed-eni # eks
  containers # eks
  pods # eks
  cloud-init.log
  cloud-init-output.log
  audit
)

# L-IPAMD introspection data points
IPAMD_DATA=(
  enis
  pods
  networkutils-env-settings
  ipamd-env-settings
  eni-configs
)

# Sysctls datapoints
STSCTLS_DATA=(
  all
  default
  eth0
)

# Kubelet datapoints
KUBELET_DATA=(
  pods
  stats
  eth0
)

help() {
  echo "USAGE: ${PROGRAM_NAME} --mode=collect|enable_debug"
  echo "       ${PROGRAM_NAME} --help"
  echo ""
  echo "OPTIONS:"
  echo "     --mode  Sets the desired mode of the script. For more information,"
  echo "             see the MODES section."
  echo "     --help  Show this help message."
  echo ""
  echo "MODES:"
  echo "     collect       Gathers basic operating system, Docker daemon, and Amazon"
  echo "                 EKS related config files and logs. This is the default mode."
  echo "     enable_debug  Enables debug mode for the Docker daemon"
}

version_output() {
  echo -e "\n\tThis is version ${PROGRAM_VERSION}. New versions can be found at ${PROGRAM_SOURCE}\n"
}

systemd_check() {
  if [[ -L "/sbin/init" ]]; then
      INIT_TYPE="systemd"
    else
      INIT_TYPE="other"
    fi
}

parse_options() {
  local count="$#"

  for i in $(seq "${count}"); do
    eval arg="\$$i"
    param="$(echo "${arg}" | awk -F '=' '{print $1}' | sed -e 's|--||')"
    val="$(echo "${arg}" | awk -F '=' '{print $2}')"

    case "${param}" in
      mode)
        eval "${param}"="${val}"
        ;;
      help)
        help && exit 0
        ;;
      *)
        echo "Command not found: '--$param'"
        help && exit 1
        ;;
    esac
  done
}

ok() {
  echo
}

info() {
  echo "$*"
}

try() {
  local action=$*
  echo -n "Trying to $action... "
}

warning() {
  local reason=$*
  echo -e "\n\n\tWarning: $reason "
}

die() {
  echo "ERROR: $*.. exiting..."
  exit 1
}

is_root() {
  try "check if the script is running as root"

  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root!"
  fi

  ok
}

create_directories() {
    # Make sure the directory the script lives in is there. Not an issue if
  # the EKS AMI is used, as it will have it.
  mkdir --parents "${PROGRAM_DIR}"
  
  # Common directors creation 
  for directory in ${COMMON_DIRECTORIES[*]}; do
    mkdir --parents "${COLLECT_DIR}"/"${directory}"
  done
}

instance_metadata() {
  try "resolve instance-id"

  local curl_bin
  curl_bin="$(command -v curl)"

  if [[ -z "${curl_bin}" ]]; then
      warning "Curl not found, please install curl. You can still view the logs in the collect folder."
      INSTANCE_ID=$(hostname)
      echo "${INSTANCE_ID}" > "${COLLECT_DIR}"/system/instance-id.txt
    else
      INSTANCE_ID=$(curl --max-time 3 --silent http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
      echo "${INSTANCE_ID}" > "${COLLECT_DIR}"/system/instance-id.txt
  fi

  ok
}

is_diskfull() {
  try "check disk space usage"

  local threshold
  local result
  threshold=1500000
  result=$(df / | grep --invert-match "Filesystem" | awk '{ print $4 }')

  if [[ "${result}" -lt "${threshold}" ]]; then
    die "Less than $((threshold>>10))MB, please ensure adequate disk space to collect and store the log files."
  fi

  ok
}

cleanup() {
  rm --recursive --force "${COLLECT_DIR}" >/dev/null 2>&1
}

init() {
  version_output
  is_root
  create_directories
  instance_metadata
  systemd_check
}

collect() {
  init
  is_diskfull
  get_common_logs
  get_kernel_logs
  get_mounts_info
  get_selinux_info
  get_iptables_info
  get_pkgtype
  get_pkglist
  get_system_services
  get_docker_info
  get_eks_logs_and_configfiles
  get_ipamd_info
  get_sysctls_info
  get_networking_info
  get_cni_config
  get_kubelet_info
  get_containers_info
  get_docker_logs
}

enable_debug() {
  init
  enable_docker_debug
}

pack() {
  try "archive gathered log information"

  local TAR_BIN
  TAR_BIN="$(command -v tar)"

  if [[ -z "${TAR_BIN}" ]]; then
      warning "TAR archiver not found, please install a TAR archiver to create the collection archive. You can still view the logs in the collect folder."
    else
      ${TAR_BIN} --create --verbose --gzip --file "${PROGRAM_DIR}"/eks_"${INSTANCE_ID}"_"$(date --utc +%Y-%m-%d_%H%M-%Z)"_"${PROGRAM_VERSION}".tar.gz --directory="${COLLECT_DIR}" . > /dev/null 2>&1
  fi

  ok
}

finished() {
  if [[ "${mode}" == "collect" ]]; then
      echo -e "\n\tDone... your bundled logs are located in ${PROGRAM_DIR}/eks_${INSTANCE_ID}_$(date --utc +%Y-%m-%d_%H%M-%Z)_${PROGRAM_VERSION}.tar.gz\n"
    else
      echo -e "\n\tDone... debug is enabled\n"
  fi
}

get_mounts_info() {
  try "get mount points and volume information"
  mount > "${COLLECT_DIR}"/storage/mounts.txt
  echo >> "${COLLECT_DIR}"/storage/mounts.txt
  df --human-readable >> "${COLLECT_DIR}"/storage/mounts.txt
  lsblk > "${COLLECT_DIR}"/storage/lsblk.txt

  if [[ -e /sbin/lvs ]]; then
    lvs > "${COLLECT_DIR}"/storage/lvs.txt
    pvs > "${COLLECT_DIR}"/storage/pvs.txt
    vgs > "${COLLECT_DIR}"/storage/vgs.txt
  fi

  ok
}

get_selinux_info() {
  try "check SELinux status"

  local GETENFORCE_BIN
  local SELINUX_STATUS
  GETENFORCE_BIN="$(command -v getenforce)"
  SELINUX_STATUS="$(${GETENFORCE_BIN})" 2>/dev/null
  
  if [[ -z "${SELINUX_STATUS}" ]]; then
      echo -e "SELinux mode:\n\t Not installed" > "${COLLECT_DIR}"/system/selinux.txt
    else
      echo -e "SELinux mode:\n\t ${SELINUX_STATUS}" > "${COLLECT_DIR}"/system/selinux.txt
  fi

  ok
}

get_iptables_info() {
  try "get iptables list"

  iptables --numeric --verbose --list --table filter > "${COLLECT_DIR}"/networking/iptables-filter.txt
  iptables --numeric --verbose --list --table nat > "${COLLECT_DIR}"/networking/iptables-nat.txt
  iptables-save > "${COLLECT_DIR}"/networking/iptables-save.out

  ok
}

get_common_logs() {
  try "collect common operating system logs"

  for entry in ${COMMON_LOGS[*]}; do
    if [[ -e "/var/log/${entry}" ]]; then
      cp --force --recursive /var/log/"${entry}" "${COLLECT_DIR}"/var_log/
    fi
  done

  ok
}

get_kernel_logs() {
  try "collect kernel logs"

  if [[ -e "/var/log/dmesg" ]]; then
      cp --force /var/log/dmesg "${COLLECT_DIR}/kernel/dmesg.boot"
  fi
  dmesg > "${COLLECT_DIR}/kernel/dmesg.current"

  ok
}

get_docker_logs() {
  try "collect Docker daemon logs"

  case "${INIT_TYPE}" in
    systemd)
      journalctl --unit=docker --since "${DAYS_7}" > "${COLLECT_DIR}"/docker/docker.log
      ;;
    other)
      for entry in docker upstart/docker; do
        if [[ -e "/var/log/${entry}" ]]; then
          cp --force --recursive /var/log/"${entry}" "${COLLECT_DIR}"/docker/
        fi
      done
      ;;
    *)
      warning "The current operating system is not supported."
      ;;
  esac

  ok
}

get_eks_logs_and_configfiles() {
  try "collect Amazon EKS container agent logs"

  case "${INIT_TYPE}" in
    systemd)
      timeout 75 journalctl --unit=kubelet --since "${DAYS_7}" > "${COLLECT_DIR}"/kubelet/kubelet.log
      timeout 75 journalctl --unit=kubeproxy --since "${DAYS_7}" > "${COLLECT_DIR}"/kubelet/kubeproxy.log
      timeout 75 kubectl config view --output yaml > "${COLLECT_DIR}"/kubelet/kubeconfig.yaml

      for entry in kubelet kube-proxy; do
        if [[ -e "/etc/systemd/system/${entry}.service" ]]; then
          cp --force --recursive "/etc/systemd/system/${entry}.service" "${COLLECT_DIR}"/kubelet/
        fi
      done
      ;;
    *)
      warning "The current operating system is not supported."
      ;;
  esac

  ok
}

get_ipamd_info() {
  try "collect L-IPAMD information"

  for entry in ${IPAMD_DATA[*]}; do
      curl --max-time 3 --silent http://localhost:61678/v1/"${entry}" >> "${COLLECT_DIR}"/ipamd/"${entry}".txt
  done

  curl --max-time 3 --silent http://localhost:61678/metrics > "${COLLECT_DIR}"/ipamd/metrics.txt 2>&1

  ok
}

get_sysctls_info() {
  try "collect sysctls information"

  for entry in ${STSCTLS_DATA[*]}; do
      cat /proc/sys/net/ipv4/conf/"${entry}"/rp_filter >> "${COLLECT_DIR}"/sysctls/"${entry}".txt
  done 

  ok
}

get_networking_info() {
  try "collect networking infomation"

  # ifconfig
  timeout 75 ifconfig > "${COLLECT_DIR}"/networking/ifconfig.txt

  # ip rule show
  timeout 75 ip rule show > "${COLLECT_DIR}"/networking/iprule.txt
  timeout 75 ip route show table all >> "${COLLECT_DIR}"/networking/iproute.txt

  ok
}

get_cni_config() {
  try "collect CNI configuration information"

    if [[ -e "/etc/cni/net.d/" ]]; then
        cp --force --recursive /etc/cni/net.d/* "${COLLECT_DIR}"/cni/
    fi  

  ok
}

get_kubelet_info() {
  try "collect Kubelet information"

  for entry in ${KUBELET_DATA[*]}; do
      curl --max-time 3 --silent http://localhost:10255/"${entry}" >> "${COLLECT_DIR}"/kubelet/"${entry}".json
  done 

  ok
}

get_pkgtype() {
  try "detect package manager"

  if [[ "$(command -v rpm )" ]]; then
    PACKAGE_TYPE=rpm
  elif [[ "$(command -v deb )" ]]; then
    PACKAGE_TYPE=deb
  else
    PACKAGE_TYPE='unknown'
  fi

  ok
}

get_pkglist() {
  try "detect installed packages"

  case "${PACKAGE_TYPE}" in
    rpm)
      rpm -qa > "${COLLECT_DIR}"/system/pkglist.txt 2>&1
      ;;
    deb)
      dpkg --list > "${COLLECT_DIR}"/system/pkglist.txt 2>&1
      ;;
    *)
      warning "Unknown package type."
      ;;
  esac

  ok
}

get_system_services() {
  try "detect active system services list"

  case "${INIT_TYPE}" in
    systemd)
      systemctl list-units > "${COLLECT_DIR}"/system/services.txt 2>&1
      ;;
    other)
      /sbin/initctl list | awk '{ print $1 }' | xargs -n1 initctl show-config > "${COLLECT_DIR}"/system/services.txt 2>&1
      printf "\n\n\n\n" >> "${COLLECT_DIR}"/services.txt 2>&1
      /usr/bin/service --status-all >> "${COLLECT_DIR}"/services.txt 2>&1
      ;;
    *)
      warning "Unable to determine active services."
      ;;
  esac

  timeout 75 top -b -n 1 > "${COLLECT_DIR}"/system/top.txt 2>&1
  timeout 75 ps fauxwww > "${COLLECT_DIR}"/system/ps.txt 2>&1
  timeout 75 netstat -plant > "${COLLECT_DIR}"/system/netstat.txt 2>&1

  ok
}

get_docker_info() {
  try "gather Docker daemon information"

  if [[ "$(pgrep dockerd)" -ne 0 ]]; then
    timeout 75 docker info > "${COLLECT_DIR}"/docker/docker-info.txt 2>&1 || echo "Timed out, ignoring \"docker info output \" "
    timeout 75 docker ps --all --no-trunc > "${COLLECT_DIR}"/docker/docker-ps.txt 2>&1 || echo "Timed out, ignoring \"docker ps --all --no-truc output \" "
    timeout 75 docker images > "${COLLECT_DIR}"/docker/docker-images.txt 2>&1 || echo "Timed out, ignoring \"docker images output \" "
    timeout 75 docker version > "${COLLECT_DIR}"/docker/docker-version.txt 2>&1 || echo "Timed out, ignoring \"docker version output \" "

    ok

  else
    die "The Docker daemon is not running."
  fi
}

get_containers_info() {
  try "inspect running Docker containers and gather container data"

    for i in $(docker ps -q); do
      timeout 75 docker inspect "${i}" > "${COLLECT_DIR}"/docker/container-"${i}".txt 2>&1
    done

    ok
}

enable_docker_debug() {
  try "enable debug mode for the Docker daemon"

  case "${PACKAGE_TYPE}" in
    rpm)

      if [[ -e /etc/sysconfig/docker ]] && grep -q "^\s*OPTIONS=\"-D" /etc/sysconfig/docker
      then
        info "Debug mode is already enabled."
      else

        if [[ -e /etc/sysconfig/docker ]]; then
          echo "OPTIONS=\"-D \$OPTIONS\"" >> /etc/sysconfig/docker

          try "restart Docker daemon to enable debug mode"
          /sbin/service docker restart
        fi

        ok

      fi
      ;;
    *)
      warning "The current operating system is not supported."
      ;;
  esac
}

parse_options "$@"

if [[ -z "${mode}" ]]; then
 mode="collect"
fi

case "${mode}" in
  collect)
    collect
    pack
    cleanup
    finished
    ;;
  enable_debug)
    get_pkgtype
    enable_debug
    finished
    ;;
  *)
    help && exit 1
    ;;
esac
