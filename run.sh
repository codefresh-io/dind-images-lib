#!/bin/bash
#
BASE_DIR=/dind
DIND_IMAGES_LIB_ETALON_DIR=${BASE_DIR}/images-lib-etalon
mkdir -p ${DIND_IMAGES_LIB_ETALON_DIR}

DIND_IMAGES_LIBS_DIR=${BASE_DIR}/images-libs
DIND_IMAGES_LIB_DIR_PREFIX="lib-"

RECREATE_ETALON=${RECREATE_ETALON:-""}
DESIRED_DOCKER_LIB_NUMBER=15
MIN_DOCKER_LIB_NUMBER=10

IMAGES_PULL_LIST=${DIR}/images-pull-list
IMAGES_DELETE_LIST=${DIR}/images-delete-list

echo "Entering $0 at $(date) "

if [[ "${RECREATE_ETALON}" = "1" ]]; then
  echo "RECREATE_ETALON = ${RECREATE_ETALON} - deleting existing ${DIND_IMAGES_LIB_ETALON_DIR} "
  rm -rf "${DIND_IMAGES_LIB_ETALON_DIR}"
  mkdir -p "${DIND_IMAGES_LIB_ETALON_DIR}"
fi


echo "Starting dockerd with --data-root = ${DIND_IMAGES_LIB_ETALON_DIR} "
dockerd --data-root "${DIND_IMAGES_LIB_ETALON_DIR}" &>/tmp/dockerd.log <&- &

while ! test -f /var/run/docker.pid || test -z "$(cat /var/run/docker.pid)" || ! docker ps
do
  echo "$(date) - Waiting for docker to start"
  sleep 2
done

DOCKER_PID=$(cat /var/run/docker.pid)
echo "Docker daemon has been started with DOCKER_PID = ${DOCKER_PID} "

echo "\n-------  $(date)  \nPulling images from IMAGES_PULL_LIST = ${IMAGES_PULL_LIST} "
cat ${IMAGES_PULL_LIST} | while read image
do
  echo "Pulling image ${image} "
  docker pull "${image}"
done

if [[ -f "${IMAGES_DELETE_LIST}" ]]; then
    echo -e "\n-------  $(date) \nDeleting images from IMAGES_DELETE_LIST = ${IMAGES_DELETE_LIST} "
    cat ${IMAGES_DELETE_LIST} | while read image
    do
      echo "    Deleting image ${image} "
      docker rmi -f "${image}"
    done
fi

echo -e "\n------- $(date) \nKilling dockerd DOCKER_PID = ${DOCKER_PID}"
kill ${DOCKER_PID}
echo "Waiting for dockerd to exit ..."
CNT=0
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

echo -e "\n------- $(date) \nStarting to synchronize images lib directories ${DIND_IMAGES_LIBS_DIR}/ with etalon"

















