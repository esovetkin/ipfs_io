#!/bin/bash

cd $(git rev-parse --show-toplevel)


function set_defaults {
    network_interface="pi0"
    docker_maxmemory=$(echo "scale=2; $(grep MemTotal /proc/meminfo | awk '{print $2}')/1024/1024*0.2" \
                           | bc | awk '{printf "%.2f", $0}')"g"
    what="start"
    ifdry="no"
    ifrestart="yes"
    storage_mnt="$(realpath ./ipfs_storage)"
    ipfs_cluster_config="$(realpath ./ipfs_storage/cluster)"
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
    echo "                    Default: \"${storage_mnt}\""
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
    echo "  --ipfs-profile    IPFS profile. See https://docs.ipfs.io/how-to/default-profile/#available-profiles"
    echo "                    Default: \"${ipfs_profile}\""
    echo
    echo "  --ipfs-swarmkey   IPFS swarm key file path."
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
                storage_mnt="${i#*=}"
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
            echo docker container rm "${ids}"
            return 0
        fi

        docker container rm "${ids}"
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
    ipfs_staging="${storage_mnt}/ipfs/staging"
    ipfs_data="${storage_mnt}/ipfs/data"
    ipaddress=$(get_ip "${network_interface}")

    docommand=$(echo mkdir -p "${ipfs_staging}" "${ipfs_data}")
    docommand=${docommand}"; "$(echo docker run -d \
                                     --name ipfs \
                                     --memory "${docker_maxmemory}" \
                                     $(get_restart) \
                                     -e "IPFS_SWARM_KEY_FILE=${ipfs_swarmkey}" \
                                     -e "IPFS_PROFILE=${ipfs_profile}" \
                                     -v "${ipfs_staging}:/export" \
                                     -v "${ipfs_data}:/data/ipfs" \
                                     -p "4001:4001" \
                                     -p "${ipaddress}:8050:8080" \
                                     -p "${ipaddress}:5001:5001" \
                                     ipfs/go-ipfs)
    echo "${docommand}"
}


function start_ipfs_cluster {
    ipaddress=$(get_ip "${network_interface}")
    cluster_secret=$(jq -r '.cluster.secret' "${ipfs_cluster_servicejson}")

    docommand=""
    docommand+=$(echo mkdir -p "${ipfs_cluster_config}")"; "
    docommand+=$(echo docker run -d \
                      --name ipfs_cluster \
                      --memory "${docker_maxmemory}" \
                      $(get_restart) \
                      -e "CLUSTER_SECRET=${cluster_secret}" \
                      -e "CLUSTER_RESTAPI_HTTPLISTENMULTIADDRESS=/ip4/0.0.0.0/tcp/9094" \
                      -e "CLUSTER_IPFSHTTP_NODEMULTIADDRESS=/ip4/${ipaddress}/tcp/5001" \
                      -p "${ipaddress}:9096:9096" \
                      -p "${ipaddress}:9094:9094" \
                      ipfs/ipfs-cluster:latest)
    echo "${docommand}"
}


set_defaults
parse_args $@

case "${what}" in
    start)
        # determine the docommand
        prune_byname ipfs_cluster
        prune_byname ipfs
        docommand=""
        docommand+=$(start_ipfs)"; "
        docommand+=$(start_ipfs_cluster)"; "
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
