#!/bin/bash
#
DIR=$(dirname $0)

METRICS_DIR=${DIR}/metrics

COLLECT_INTERVAL=15
source ${DIR}/../config

echo "Started $0 at $(date) on node $NODE_NAME
COLLECT_INTERVAL=${COLLECT_INTERVAL}
"

if [[ ! -d "${METRICS_DIR}" ]]; then
   mkdir -p "${METRICS_DIR}"
fi

get_dind_images_lib_count(){

    local METRIC_NAME=${1:-"dind_images_lib_count"}
    local LABELS="desired_images_lib_count=\"${DESIRED_IMAGES_LIB_COUNT}\",min_images_lib_count=\"${MIN_IMAGES_LIB_COUNT}\",sync_interval=\"${SYNC_INTERVAL}\""

    local IMAGES_LIB_CNT=0
    for ii in $(seq -w ${DESIRED_IMAGES_LIB_COUNT})
    do
      DEST_DIR=${DIND_IMAGES_LIBS_DIR}/${LIB_DIR_PREFIX}${ii}
      if [[ -d ${DEST_DIR} ]]; then
        (( IMAGES_LIB_CNT++ ))
      fi
    done
    echo "${METRIC_NAME}{$LABELS} ${IMAGES_LIB_CNT}"
}

METRICS_dind_images_lib_count="${METRICS_DIR}"/dind_images_lib_count.prom
METRICS_TMP_dind_images_lib_count="${METRICS_DIR}"/dind_images_lib_count.prom.tmp.$$
echo "dind_images_lib_count metric collected to ${METRICS_dind_images_lib_count} "

DIND_IMAGES_LIBS_DIR=${BASE_DIR}/images-libs
while true; do
    cat <<EOF > "${METRICS_dind_images_lib_count}"
# TYPE dind_images_lib_count gauge
# HELP dind_images_lib_count - current count of dind_images_lib folder in
EOF

    get_dind_images_lib_count  >> "${METRICS_TMP_dind_images_lib_count}"
    mv "${METRICS_TMP_dind_images_lib_count}" "${METRICS_dind_images_lib_count}"

   sleep $COLLECT_INTERVAL
done
