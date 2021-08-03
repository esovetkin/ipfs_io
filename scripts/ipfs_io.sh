#!/bin/bash

cd $(dirname $(realpath "$0"))
cd $(git rev-parse --show-toplevel)


function set_defaults {
    network_interface="pi0"
    docker_maxmemory=$(echo "scale=2; $(grep MemTotal /proc/meminfo | awk '{print $2}')/1024/1024*0.2" \
                           | bc | awk '{printf "%.2f", $0}')"g"
    what="start"
    bootstrap_ipfs="$(realpath ./bootstrap_ipfs.list)"
    bootstrap_cluster="$(realpath ./bootstrap_cluster.list)"
    ifdry="no"
    ifrestart="yes"
    ipfs_storage="$(realpath ./ipfs_storage/ipfs)"
    ipfs_cluster_config="$(realpath ./ipfs_storage/cluster)"
    ipfs_private="yes"
    ipfs_profile="server"
    ipfs_swarmkey="$(realpath secret/swarm.key)"
    ipfs_cluster_servicejson="$(realpath secret/service.json)"
}


function print_help {
    echo "Usage: $0 [--argument=value ...]"
    echo ""
    echo "Start ipfs storage containers"
    echo
    echo "  -h,--help         print this page"
    echo
    echo "  -d,--dry          just echo command, do not execute"
    echo
    echo "  --what            what to run. Either: start, stop, genkey"
    echo "                    Default: \"${what}\""
    echo
    echo "  --bootstrap-ipfs"
    echo "                    filename for ipfs nodes multiaddress to bootstrap from"
    echo "                    Default: \"${bootstrap_ipfs}\""
    echo
    echo "  --bootstrap-cluster"
    echo "                    filename for ipfs-cluster nodes multiaddress to bootstrap from"
    echo "                    Default: \"${bootstrap_cluster}\""
    echo
    echo "  --maxmemory       hard limit on memory"
    echo "                    Default: \"${docker_maxmemory}\""
    echo
    echo "  --network         network interface where to bind ports"
    echo "                    Empty for all. Default: \"${network_interface}\""
    echo
    echo "  --ifrestart       enable restart on docker restart."
    echo "                    Default: \"${ifrestart}\""
    echo
    echo "  --storage         local mount for storage"
    echo "                    Default: \"${ipfs_storage}\""
    echo
    echo "  --ipfs-cluster-config"
    echo "                    ipfs cluster config path"
    echo "                    Default: \"${ipfs_cluster_config}\""
    echo
    echo "  --ipfs-cluster-servicejson"
    echo "                    Path to cluster service.json config."
    echo "                    This file is the same for all nodes."
    echo "                    Default: \"${ipfs_cluster_servicejson}\""
    echo
    echo "  --ipfs-private    If 'yes' ipfs is run in a private mode."
    echo "                    --bootstrap-ipfs must be specified"
    echo
    echo "  --ipfs-profile    IPFS profile. See https://docs.ipfs.io/how-to/default-profile/#available-profiles"
    echo "                    Default: \"${ipfs_profile}\""
    echo
    echo "  --ipfs-swarmkey   IPFS swarm key file path."
    echo "                    Leave empty if do not use it."
    echo "                    Default: \"${ipfs_swarmkey}\""
    echo
}


function parse_args {
    for i in "$@"
    do
        case "${i}" in
            -h|--help)
                print_help
                exit
                ;;
            -d|--dry)
                ifdry="yes"
                ;;
            --what=*)
                what="${i#*=}"
                shift
                ;;
            --bootstrap-ipfs=*)
                bootstrap_ipfs="${i#*=}"
                shift
                ;;
            --bootstrap-cluster=*)
                bootstrap_cluster="${i#*=}"
                shift
                ;;
            --maxmemory=*)
                docker_maxmemory="${i#*=}"
                shift
                ;;
            --network=*)
                network_interface="${i#*=}"
                shift
                ;;
            --ifrestart=*)
                ifrestart="${i#*=}"
                shift
                ;;
            --storage=*)
                ipfs_storage="${i#*=}"
                shift
                ;;
            --ipfs-cluster-config=*)
                ipfs_cluster_config="${i#*=}"
                shift
                ;;
            --ipfs-cluster-servicejson=*)
                ipfs_cluster_servicejson="${i#*=}"
                shift
                ;;
            --ipfs-private=*)
                ipfs_private="${i#*=}"
                shift
                ;;
            --ipfs-profile=*)
                ipfs_profile="${i#*=}"
                shift
                ;;
            --ipfs-swarmkey=*)
                ipfs_swarmkey="${i#*=}"
                shift
                ;;
            *)
                echo "unknown argument!"
                exit
                ;;
        esac
    done
}


function prune_byname {
    expr="$1"
    ids=$(docker container ls -a | \
              grep "${expr}" | \
              awk '{print $1}' | xargs)
    if [ ! -z "${ids}" ]
    then
        if [ "yes" = "${ifdry}" ]
        then
            echo docker container rm ${ids}
            return 0
        fi

        docker container rm ${ids}
        [ "$?" -ne 0 ] && return 1
    fi
    return 0
}


function get_ip {
    interface="$1"
    if [ -z "${interface}" ]
    then
        echo ""
        return
    fi

    bind_ip=$(ip -f inet addr show "${interface}" | awk '/inet/ {print $2}' | cut -d/ -f1)
    echo "${bind_ip}"
}


function get_restart {
    if [ "yes" = "${ifrestart}" ]
    then
        echo " --restart always "
        return
    fi

    echo ""
    return
}


function start_ipfs {
    ipaddress=$(get_ip "${network_interface}")

    # if private and no key, means we just init things
    if [ "${ipfs_private}" = "yes" ]
    then
        args+=" -e LIBP2P_FORCE_PNET=1"
    fi

    docommand=$(echo mkdir -p "${ipfs_storage}")
    docommand+=";"$(echo docker run -d \
                          --name ipfs \
                          --memory "${docker_maxmemory}" \
                          $(get_restart) \
                          ${args} \
                          -e IPFS_PROFILE="${ipfs_profile}" \
                          -v "${ipfs_storage}:/data/ipfs" \
                          -p "4001:4001" \
                          -p "${ipaddress}:8050:8080" \
                          -p "${ipaddress}:5001:5001" \
                          ipfs/go-ipfs)

    echo "${docommand}"
}


function set_private {
    res=$(echo mkdir -p "${ipfs_storage}")
    res+=";"$(echo cp "${ipfs_swarmkey}" "${ipfs_storage}/swarm.key")
    res+=";"$(echo docker run -d \
                   -v "${ipfs_storage}:/data/ipfs" \
                   ipfs/go-ipfs bootstrap rm --all)

    if [ ! -f "${bootstrap_ipfs}" ]
    then
        echo "${res}"
        return 0
    fi

    while read line
    do
        res+=";"$(echo docker run -d \
                       -v "${ipfs_storage}:/data/ipfs" \
                       ipfs/go-ipfs bootstrap add "${line}")

    done <"${bootstrap_ipfs}"

    echo "${res}"
}


function start_ipfs_cluster {
    ipaddress=$(get_ip "${network_interface}")
    cluster_secret=$(jq -r '.cluster.secret' "${ipfs_cluster_servicejson}")

    clusterargs=""
    if [ -f "${bootstrap_cluster}" ]
    then
        clusterargs="daemon --bootstrap $(tr '\n' ',' < ${bootstrap_cluster} | sed 's/,*$//')"
    fi

    docommand=""
    docommand+=$(echo mkdir -p "${ipfs_cluster_config}")
    docommand+=";"$(echo docker run -d \
                      --name ipfs_cluster \
                      --memory "${docker_maxmemory}" \
                      $(get_restart) \
                      -v "${ipfs_cluster_config}:/data/ipfs-cluster" \
                      -e "CLUSTER_SECRET=${cluster_secret}" \
                      -e "CLUSTER_RESTAPI_HTTPLISTENMULTIADDRESS=/ip4/0.0.0.0/tcp/9094" \
                      -e "CLUSTER_IPFSHTTP_NODEMULTIADDRESS=/ip4/${ipaddress}/tcp/5001" \
                      -p "${ipaddress}:9096:9096" \
                      -p "${ipaddress}:9094:9094" \
                      ipfs/ipfs-cluster:latest \
                      ${clusterargs})
    echo "${docommand}"
}


set_defaults
parse_args $@

case "${what}" in
    start)
        # determine the docommand
        prune_byname ipfs
        docommand=""

        if [ "${ipfs_private}" = "yes" ] && [ ! -f "${ipfs_storage}/swarm.key" ]
        then
            docommand+=$(set_private)";"
        fi

        docommand+=$(start_ipfs)
        docommand+=";"$(start_ipfs_cluster)
        ;;
    stop)
        docommand="docker kill ipfs ipfs_cluster"
        ;;
    genkey)
        echo -e "/key/swarm/psk/1.0.0/\n/base16/\n`tr -dc 'a-f0-9' < /dev/urandom | head -c64`" \
             > "${ipfs_swarmkey}"
        ;;
    *)
      echo "unknown value of --what!"
      exit
      ;;
esac

if [ "yes" = "${ifdry}" ]
then
    echo ${docommand} | tr ';' '\n'
    exit 0
fi

eval ${docommand}
