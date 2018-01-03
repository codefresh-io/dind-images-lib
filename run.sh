#!/bin/bash
#
DIR=$(dirname $0)
BASE_DIR=/dind
DIND_IMAGES_LIB_ETALON_DIR=${BASE_DIR}/images-lib-etalon
mkdir -p ${DIND_IMAGES_LIB_ETALON_DIR}

DIND_IMAGES_LIBS_DIR=${BASE_DIR}/images-libs
LIB_DIR_PREFIX="lib-"

RECREATE_ETALON=${RECREATE_ETALON:-""}
DESIRED_DOCKER_LIB_NUMBER=${DESIRED_DOCKER_LIB_NUMBER:-15}
MIN_DOCKER_LIB_NUMBER=${MIN_DOCKER_LIB_NUMBER:-10}

SYNC_INTERVAL=${SYNC_INTERVAL:-60}

IMAGES_PULL_LIST=${DIR}/images-pull-list
IMAGES_DELETE_LIST=${DIR}/images-delete-list

DOCKERD_PARAMS=${DOCKERD_PARAMS:-'--storage-driver=overlay --storage-opt=[overlay.override_kernel_check=1]'}

sighup_trap(){
   echo -e "\n ############## $(date) - SIGHUP received ####################"
   create_etalon
   rsync_images_libs
   delete_extra_images_libs
}
trap sighup_trap SIGHUP

sigusr1_trap(){
   echo -e "\n ############## $(date) - SIGUSR1 received ####################"

   echo "    set RECREATE_ETALON=1 and call sighup_trap"
   RECREATE_ETALON="1" sighup_trap
}
trap sigusr1_trap SIGUSR1

create_etalon(){
    echo -e "---- Creating etalon image lib dir"
    if [[ "${RECREATE_ETALON}" == "1" ]]; then
      echo "RECREATE_ETALON = ${RECREATE_ETALON} - deleting existing ${DIND_IMAGES_LIB_ETALON_DIR} "
      rm -rf "${DIND_IMAGES_LIB_ETALON_DIR}"
      mkdir -p "${DIND_IMAGES_LIB_ETALON_DIR}"
    fi

    echo "Starting dockerd --data-root = ${DIND_IMAGES_LIB_ETALON_DIR} $DOCKERD_PARAMS "
    dockerd --data-root "${DIND_IMAGES_LIB_ETALON_DIR}" $DOCKERD_PARAMS &>/tmp/dockerd.log <&- &

    while ! test -f /var/run/docker.pid || test -z "$(cat /var/run/docker.pid)" || ! docker ps
    do
      echo "$(date) - Waiting for docker to start"
      sleep 2
    done

    DOCKER_PID=$(cat /var/run/docker.pid)
    echo "Docker daemon has been started with DOCKER_PID = ${DOCKER_PID} "

    if [[ -f "${IMAGES_DELETE_LIST}" ]]; then
        echo -e "\n-------  $(date) \nDeleting images from IMAGES_DELETE_LIST = ${IMAGES_DELETE_LIST} "
        cat ${IMAGES_DELETE_LIST} | while read image
        do
          echo "    Deleting image ${image} "
          docker rmi -f "${image}"
        done
    fi

    echo "\n-------  $(date)  \nPulling images from IMAGES_PULL_LIST = ${IMAGES_PULL_LIST} "
    cat ${IMAGES_PULL_LIST} | while read image
    do
      echo "Pulling image ${image} "
      docker pull "${image}"
    done

    echo -e "\n------- $(date) \nKilling dockerd DOCKER_PID = ${DOCKER_PID}"
    kill ${DOCKER_PID}
    echo "Waiting for dockerd to exit ..."
    local CNT=0
    while pgrep -l docker
    do
       (( CNT++ ))
       echo ".... dockerd is still running - $(date)"
       if (( CNT >= 60 )); then
         echo "Killing dockerd"
         pkill -9 docker
         break
       fi
       sleep 1
    done
}

rsync_images_libs(){
    local DEST_DIR
    local DEST_DIR_TMP
    for ii in $(seq -w ${DESIRED_DOCKER_LIB_NUMBER})
    do
      DEST_DIR=${DIND_IMAGES_LIBS_DIR}/${LIB_DIR_PREFIX}${ii}
      DEST_DIR_TMP=${DEST_DIR}.tmp

      if [[ -d ${DEST_DIR} ]]; then
          echo -e "\n    -- $(date) -- Syncing ${DEST_DIR}"
          rm -rf ${DEST_DIR_TMP}
          mv ${DEST_DIR} ${DEST_DIR_TMP} && \
          rsync -a --delete ${DIND_IMAGES_LIB_ETALON_DIR}/ ${DEST_DIR_TMP}/ && \
          mv ${DEST_DIR_TMP} ${DEST_DIR}
      fi
    done
}

delete_extra_images_libs(){
    local LIB_DIR_NUMBER
    for ii in $(find ${DIND_IMAGES_LIBS_DIR}/ -mindepth 1 -maxdepth 1 -type d -name "${LIB_DIR_PREFIX}*" )
    do
      if [[ "${ii}" =~ ${LIB_DIR_PREFIX}([[:digit:]]*$) ]]; then
         LIB_DIR_NUMBER=$(expr ${BASH_REMATCH[1]} + 0 )
         if (( LIB_DIR_NUMBER > DESIRED_DOCKER_LIB_NUMBER )); then
            echo -e "\n   -- $(date) -- Deleting extra image lib dir ${ii}"
            mv ${ii} ${ii}.delete && \
            rm -rf ${ii}.delete
         fi
      fi
    done
}

echo "Entering $0 at $(date) "

create_etalon
rsync_images_libs
delete_extra_images_libs

echo -e "\n------- $(date) \nStarting to synchronize images lib directories ${DIND_IMAGES_LIBS_DIR}/ with etalon"

while true
do
    # Counting existing directories of image-lib, rsync on first run
    DOCKER_LIB_CNT=0
    for ii in $(seq -w ${DESIRED_DOCKER_LIB_NUMBER})
    do
      DEST_DIR=${DIND_IMAGES_LIBS_DIR}/${LIB_DIR_PREFIX}${ii}
      DEST_DIR_TMP=${DEST_DIR}.tmp

      if [[ -d ${DEST_DIR} ]]; then
        (( DOCKER_LIB_CNT++ ))
      fi
    done

    if (( DOCKER_LIB_CNT >= MIN_DOCKER_LIB_NUMBER )); then
        # Do nothing if there are more than MIN_DOCKER_LIB_NUMBER images lib directories
        echo "There are already ${DOCKER_LIB_CNT} images lib directories >= MIN_DOCKER_LIB_NUMBER=${MIN_DOCKER_LIB_NUMBER} "
    else
        # Creating missing images lib directories to get to DESIRED_DOCKER_LIB_NUMBER
        for ii in $(seq -w ${DESIRED_DOCKER_LIB_NUMBER})
        do
          DEST_DIR=${DIND_IMAGES_LIBS_DIR}/${LIB_DIR_PREFIX}${ii}
          DEST_DIR_TMP=${DEST_DIR}.tmp

          if [[ ! -d ${DEST_DIR} ]]; then
            echo -e "\n   -- $(date) -- Creating image lib dir ${DEST_DIR}"
            rm -rf ${DEST_DIR_TMP}
            mkdir -p ${DEST_DIR_TMP} && \
            cp -a ${DIND_IMAGES_LIB_ETALON_DIR}/ ${DEST_DIR_TMP}/ && \
            mv ${DEST_DIR_TMP} ${DEST_DIR} && \
            echo -e "       $(date) - Successfully created ${DEST_DIR}"
          fi
        done
    fi

    echo "Sleeping ${SYNC_INTERVAL} "
    sleep ${SYNC_INTERVAL}
done











