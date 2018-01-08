#!/bin/bash
#
DIR=$(dirname $0)
source ${DIR}/config
BASE_DIR=${BASE_DIR:-"/dind"}
LOCK_FILE=${BASE_DIR}/run.lock
DIND_IMAGES_LIB_ETALON_DIR=${DIND_IMAGES_LIB_ETALON_DIR:-${BASE_DIR}/images-lib-etalon}
DIND_IMAGES_LIB_ETALON_SAVE=${DIND_IMAGES_LIB_ETALON_SAVE:-${BASE_DIR}/images-lib-etalon.save.tar}
mkdir -p ${DIND_IMAGES_LIB_ETALON_DIR}

DIND_IMAGES_LIBS_DIR=${DIND_IMAGES_LIBS_DIR:-"${BASE_DIR}/images-libs"}
LIB_DIR_PREFIX=${LIB_DIR_PREFIX:-"lib-"}

RECREATE_ETALON=${RECREATE_ETALON:-""}
DESIRED_IMAGES_LIB_COUNT=${DESIRED_IMAGES_LIB_COUNT:-15}
MIN_IMAGES_LIB_COUNT=${MIN_IMAGES_LIB_COUNT:-10}

SYNC_INTERVAL=${SYNC_INTERVAL:-60}

IMAGES_PULL_LIST=${DIR}/images-pull-list
IMAGES_DELETE_LIST=${DIR}/images-delete-list

DOCKERD_PARAMS=${DOCKERD_PARAMS:-'--storage-driver=overlay --storage-opt=[overlay.override_kernel_check=1]'}

debug(){
  if [[ -n "${DEBUG}" &&  ${DEBUG} == "1" ]]; then
    echo -e $1
  fi
}
debug_trap(){
  # Just switch debug on/off on SIGUSR1
  if [[ -z "${DEBUG}" ]]; then
     echo "debug_trap: Switching DEBUG ON"
     DEBUG="1"
  else
     echo "debug_trap: Switching DEBUG OFF"
     unset DEBUG
  fi
}
trap debug_trap SIGUSR1

sigterm_trap(){
  echo -e "\n ############## $(date) - SIGTERM received ####################"
  export EXIT=1
  pkill sleep

  echo "killing MONITOR_PID ${MONITOR_PID}"
  kill $MONITOR_PID

}
trap sigterm_trap SIGTERM

sighup_trap(){
   echo -e "\n ############## $(date) - SIGHUP received ####################"
   source ${DIR}/config
   ensure_no_docker_running
   create_etalon
   sync_images_libs
   delete_extra_images_libs
   ensure_no_docker_running
}
trap sighup_trap SIGHUP

sigusr2_trap(){
   echo -e "\n ############## $(date) - SIGUSR2 received ####################"

   echo "    set RECREATE_ETALON=1 and call sighup_trap"
   RECREATE_ETALON="1" sighup_trap
}
trap sigusr2_trap SIGUSR2

start_docker_on_data_root(){
   # Starting dockerd with known data-root and pidfile
   local DOCKERD_DATA_ROOT=$1
   local DOCKERD_PID_FILE=$2
   local DOCKER_SOCK_FILE=$3

   local DOCKER_PID
   local DOCKER_HOST="unix://${DOCKER_SOCK_FILE}"
   echo -e "  ---- $(date) start_docker_on_data_root on ${DOCKERD_DATA_ROOT} "
   [[ -z "${DOCKERD_DATA_ROOT}" ]] && echo "Error: DOCKERD_DATA_ROOT 1 param is empty" && return 1
   [[ -z "${DOCKERD_PID_FILE}" ]] && echo "Error: DOCKERD_PID_FILE 2 param is empty" && return 1
   [[ -z "${DOCKER_SOCK_FILE}" ]] && echo "Error: DOCKER_SOCK_FILE 3 param is empty" && return 1

    echo "      Starting dockerd --data-root=${DOCKERD_DATA_ROOT} --pidfile=${DOCKERD_PID_FILE} --host=${DOCKER_HOST} $DOCKERD_PARAMS "
    dockerd --data-root=${DOCKERD_DATA_ROOT} --pidfile=${DOCKERD_PID_FILE} --host=${DOCKER_HOST} $DOCKERD_PARAMS <&- &

    local CNT=0
    while ! test -f ${DOCKERD_PID_FILE} || test -z "$(cat ${DOCKERD_PID_FILE})" || ! docker -H ${DOCKER_HOST} ps
    do
      echo "      $(date) - Waiting for docker to start"
      sleep 2
      (( CNT++ ))
      if (( CNT > 30 )); then
        echo "Error: failed to start dockerd"
        DOCKER_PID=$(cat ${DOCKERD_PID_FILE})
        if [[ -n "${DOCKER_PID}" ]]; then
           kill -9 "${DOCKER_PID}"
        fi
        return 1
      fi
    done
    echo "       Successfully started dockerd with --data-root ${DOCKERD_DATA_ROOT} --pidfile ${DOCKERD_PID_FILE} "
}

kill_docker_by_pid(){
    local DOCKER_PID=$1
    echo -e "\n------- $(date) \nKilling dockerd DOCKER_PID = ${DOCKER_PID}"
    [[ -z "${DOCKER_PID}" ]] && echo "Error: DOCKER_PID 1 param is empty" && return 1

    kill ${DOCKER_PID}
    echo "Waiting for dockerd to exit ..."
    local CNT=0
    while ( pstree -p ${DOCKER_PID} | grep dockerd )
    do
       (( CNT++ ))
       echo ".... dockerd is still running - $(date)"
       if (( CNT >= 60 )); then
         echo "Killing dockerd"
         kill -9 ${DOCKER_PID}
         break
       fi
       sleep 1
    done
}

ensure_no_docker_running(){
    echo "ensure_no_docker_running - Waiting for dockerd to exit ..."
    local CNT=0
    while pgrep -l docker
    do
       CNT=$(expr ${CNT} '+' 1)
       echo ".... old dockerd is still running - $(date)"
       if [[ ${CNT} -ge 120 ]]; then
         echo "Killing old dockerd"
         pkill -9 docker
         break
       fi
       sleep 0.5
    done
}

create_etalon(){
    echo -e "---- Creating etalon image lib dir"
    if [[ "${RECREATE_ETALON}" == "1" ]]; then
      echo "RECREATE_ETALON = ${RECREATE_ETALON} - deleting existing ${DIND_IMAGES_LIB_ETALON_DIR} "
      rm -rf "${DIND_IMAGES_LIB_ETALON_DIR}"
      mkdir -p "${DIND_IMAGES_LIB_ETALON_DIR}"
      rm -fv ${DIND_IMAGES_LIB_ETALON_SAVE}
    fi

    local CURRENT_IMAGES_PULL_LIST=${DIND_IMAGES_LIB_ETALON_DIR}/$(basename ${IMAGES_PULL_LIST})
    if [[ -f ${CURRENT_IMAGES_PULL_LIST} && -f ${DIND_IMAGES_LIB_ETALON_SAVE} ]]; then
       diff ${IMAGES_PULL_LIST} ${CURRENT_IMAGES_PULL_LIST} && \
       echo "No need to sync, IMAGES_PULL_LIST is up-to-date" && \
       return 0
    fi
    local DOCKERD_NUM=${RANDOM}
    local DOCKER_PID_FILE=/var/run/docker-${DOCKERD_NUM}.pid
    local DOCKER_SOCK_FILE=/var/run/docker-${DOCKERD_NUM}.sock
    rm -f ${DOCKER_PID_FILE} ${DOCKER_SOCK_FILE}
    echo "calling start_docker_on_data_root ${DIND_IMAGES_LIB_ETALON_DIR} ${DOCKER_PID_FILE} "
    start_docker_on_data_root ${DIND_IMAGES_LIB_ETALON_DIR} ${DOCKER_PID_FILE} ${DOCKER_SOCK_FILE} || return 1

    local DOCKER_PID=$(cat ${DOCKER_PID_FILE})
    [[ -z "${DOCKER_PID}" ]] && echo "Error DOCKER_PID is empty - docker failed to start" && return 1

    local DOCKER_HOST="unix://${DOCKER_SOCK_FILE}"
    echo "Docker daemon has been started with DOCKER_PID = ${DOCKER_PID} and DOCKER_HOST="unix://${DOCKER_SOCK_FILE}""

    #Waiting until docker-hub dns available - on new node start it takes time
    local CNT=0
    while ! docker -H ${DOCKER_HOST} pull hello-world
    do
      echo "      $(date) - Retry to pull hello-world until docker-hub is available ..."
      sleep 5
      (( CNT++ ))
      if (( CNT > 120 )); then
        echo "Error: failed to connect to docker-hub after 10 min - restarting pod"
        exit 1
      fi
    done

    if [[ -f "${IMAGES_DELETE_LIST}" ]]; then
        echo -e "\n-------  $(date) \nDeleting images from IMAGES_DELETE_LIST = ${IMAGES_DELETE_LIST} "
        cat ${IMAGES_DELETE_LIST} | while read image
        do
          if [[ "${image}" =~ ^# ]]; then
            continue
          fi
          echo "    Deleting image ${image} "
          docker -H ${DOCKER_HOST} rmi -f "${image}"
        done
    fi

    echo -e "\n-------  $(date)  \nPulling images from IMAGES_PULL_LIST = ${IMAGES_PULL_LIST} "
    local IMAGES_PULL_SAVE=""
    while read image
    do
      if [[ "${image}" =~ ^# ]]; then
        continue
      fi
      echo "Pulling image ${image} "
      docker -H ${DOCKER_HOST} pull "${image}" && \
      IMAGES_PULL_SAVE="${IMAGES_PULL_SAVE} ${image}"
    done < ${IMAGES_PULL_LIST}

    echo -e "\n     --- $(date) - docker save -o ${DIND_IMAGES_LIB_ETALON_SAVE} ${IMAGES_PULL_SAVE}"
    docker -H ${DOCKER_HOST} save -o ${DIND_IMAGES_LIB_ETALON_SAVE} ${IMAGES_PULL_SAVE}
    local EXIT_CODE=$?
    echo "     docker save completed with status ${EXIT_CODE}"
    if [[ ${EXIT_CODE} == 0 ]]; then
      cp -fv ${IMAGES_PULL_LIST} ${DIND_IMAGES_LIB_ETALON_DIR}/
    fi

    kill_docker_by_pid ${DOCKER_PID}

    return ${EXIT_CODE}
}

load_images_lib(){
    local IMAGES_LIB_DIR="${1}"
    echo -e "\n------- $(date) \nload_images_lib on IMAGES_LIB_DIR = ${IMAGES_LIB_DIR}"

    [[ -z "${IMAGES_LIB_DIR}" ]] && echo "Error: IMAGES_LIB_DIR 1 param is empty" && return 1
    mkdir -p ${IMAGES_LIB_DIR}

    local DOCKERD_NUM=${RANDOM}
    local DOCKER_PID_FILE=/var/run/docker-${DOCKERD_NUM}.pid
    local DOCKER_SOCK_FILE=/var/run/docker-${DOCKERD_NUM}.sock


    rm -f ${DOCKER_PID_FILE} ${DOCKER_SOCK_FILE}

    echo "calling start_docker_on_data_root ${IMAGES_LIB_DIR} ${DOCKER_PID_FILE} "
    start_docker_on_data_root ${IMAGES_LIB_DIR} ${DOCKER_PID_FILE} ${DOCKER_SOCK_FILE} || return 1

    local DOCKER_PID=$(cat ${DOCKER_PID_FILE})
    local DOCKER_HOST="unix://${DOCKER_SOCK_FILE}"

    echo -e "\n     --- $(date) - docker -H ${DOCKER_HOST} load < ${DIND_IMAGES_LIB_ETALON_SAVE}"
    docker -H ${DOCKER_HOST} load < ${DIND_IMAGES_LIB_ETALON_SAVE}
    local EXIT_CODE=$?
    echo "     docker load completed with status ${EXIT_CODE}"
    if [[ ${EXIT_CODE} == 0 ]]; then
      cp -fv ${IMAGES_PULL_LIST} ${IMAGES_LIB_DIR}/
    fi

    kill_docker_by_pid ${DOCKER_PID}
}

sync_images_libs(){
    local DEST_DIR
    local DEST_DIR_TMP
    local CURRENT_IMAGES_PULL_LIST
    for ii in $(seq -w ${DESIRED_IMAGES_LIB_COUNT})
    do
      DEST_DIR=${DIND_IMAGES_LIBS_DIR}/${LIB_DIR_PREFIX}${ii}
      DEST_DIR_TMP=${DEST_DIR}.tmp
      CURRENT_IMAGES_PULL_LIST=${DEST_DIR}/$(basename ${IMAGES_PULL_LIST})
      if [[ -d ${DEST_DIR} ]]; then
          echo -e "\n    -- $(date) -- Syncing ${DEST_DIR}"

          if [[ -f ${CURRENT_IMAGES_PULL_LIST} ]]; then
             diff ${IMAGES_PULL_LIST} ${CURRENT_IMAGES_PULL_LIST} && \
             echo "No need to sync, IMAGES_PULL_LIST is up-to-date" && \
             continue
          fi
          rm -rf ${DEST_DIR_TMP}
          mv ${DEST_DIR} ${DEST_DIR_TMP} && \
          load_images_lib ${DEST_DIR_TMP} && \
          mv ${DEST_DIR_TMP} ${DEST_DIR}
      fi
      if [[ -n "${EXIT}" ]]; then
        echo "Exiting sync_images_libs - EXIT=${EXIT} ..."
        break
      fi
    done
}

delete_extra_images_libs(){
    local LIB_DIR_NUMBER
    for ii in $(find ${DIND_IMAGES_LIBS_DIR}/ -mindepth 1 -maxdepth 1 -type d -name "${LIB_DIR_PREFIX}*" )
    do
      if [[ "${ii}" =~ ${LIB_DIR_PREFIX}([[:digit:]]*$) ]]; then
         LIB_DIR_NUMBER=$(expr ${BASH_REMATCH[1]} + 0 )
         if (( LIB_DIR_NUMBER > DESIRED_IMAGES_LIB_COUNT )); then
            echo -e "\n   -- $(date) -- Deleting extra image lib dir ${ii}"
            mv ${ii} ${ii}.delete && \
            rm -rf ${ii}.delete
         fi
      fi
    done
}

echo "Entering $0 at $(date) "

[[ -f ${LOCK_FILE} ]] && echo "Waiting for another instance to stop - ${LOCK_FILE} exists"
while [[ -f ${LOCK_FILE} ]]
do
  sleep 1
done

date +%s > ${LOCK_FILE}

# Starting monitor
${DIR}/monitor/start.sh  <&- &
MONITOR_PID=$!

create_etalon
sync_images_libs
delete_extra_images_libs
ensure_no_docker_running

echo -e "\n------- $(date) \nStarting to synchronize images lib directories ${DIND_IMAGES_LIBS_DIR}/ with etalon"

while [[ -z "${EXIT}" ]]
do
    # Counting existing directories of image-lib, rsync on first run
    DOCKER_LIB_CNT=0
    for ii in $(seq -w ${DESIRED_IMAGES_LIB_COUNT})
    do
      DEST_DIR=${DIND_IMAGES_LIBS_DIR}/${LIB_DIR_PREFIX}${ii}
      DEST_DIR_TMP=${DEST_DIR}.tmp

      if [[ -d ${DEST_DIR} ]]; then
        (( DOCKER_LIB_CNT++ ))
      fi
    done

    if (( DOCKER_LIB_CNT >= MIN_IMAGES_LIB_COUNT )); then
        # Do nothing if there are more than MIN_IMAGES_LIB_COUNT images lib directories
        debug "There are already ${DOCKER_LIB_CNT} images lib directories >= MIN_IMAGES_LIB_COUNT=${MIN_IMAGES_LIB_COUNT} "
    else
        # Creating missing images lib directories to get to DESIRED_IMAGES_LIB_COUNT
        for ii in $(seq -w ${DESIRED_IMAGES_LIB_COUNT})
        do
          DEST_DIR=${DIND_IMAGES_LIBS_DIR}/${LIB_DIR_PREFIX}${ii}
          DEST_DIR_TMP=${DEST_DIR}.tmp

          if [[ ! -d ${DEST_DIR} ]]; then
            echo -e "\n   -- $(date) -- Creating image lib dir ${DEST_DIR}"
            rm -rf ${DEST_DIR_TMP}
            mkdir -p ${DEST_DIR_TMP} && \
            load_images_lib ${DEST_DIR_TMP} && \
            ensure_no_docker_running && \
            mv ${DEST_DIR_TMP} ${DEST_DIR} && \
            echo -e "       $(date) - Successfully created ${DEST_DIR}"
          fi

          if [[ -n "${EXIT}" ]]; then
            echo "Exiting Creating missing images lib directories - EXIT=${EXIT} ..."
            break
          fi
        done
    fi

    debug "Sleeping ${SYNC_INTERVAL} "
    sleep ${SYNC_INTERVAL}
done

echo "$(date) - removing lock file ${LOCK_FILE} "
rm -fv ${LOCK_FILE}
