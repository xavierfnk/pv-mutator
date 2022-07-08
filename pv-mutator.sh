#!/usr/bin/env bash

set -Eeuo pipefail

TARGET_STORAGECLASS=$CLASS
TARGET_SIZE=$SIZE
SET_TYPE=""

POD_NAME=$(kubectl -n ${NAMESPACE} describe pvc ${PVC_NAME} | grep "Used By:" | rev | cut -d" " -f 1 | rev)

echo
echo "PersistentVolumeClaim found."

if [[ $POD_NAME != "<none>" ]]; then
  SET_NAME=$(kubectl -n ${NAMESPACE} describe pod ${POD_NAME} | grep "Controlled By:" | rev | cut -d" " -f 1 | rev)
  SET_TYPE=$(echo $SET_NAME | cut -d"/" -f 1)
  BASE_REPLICAS=$(kubectl -n ${NAMESPACE} get ${SET_NAME} -o yaml | grep "^  replicas" -m 1 | rev | cut -d" " -f 1)

  if [[ BASE_REPLICAS -gt 0 ]]; then
    echo "Running ${SET_NAME} found with ${BASE_REPLICAS} replicas, using associated PersistentVolume."
    echo "Migrating PersistentVolumes requires to shutdown the application."
    echo
    read -p "Would you like to scale the app to 0 replicas? " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
      echo "Aborting migration."
      exit 1
    else
      echo
      kubectl -n $NAMESPACE scale $SET_NAME --replicas 0
      echo "Waiting for $SET_TYPE to scale down and release PersistentVolumeClaims..."
      RESERVED=1
      while [ $RESERVED -gt 0 ]
      do
        sleep 2
        PVC_RESERVATION=$(kubectl -n ${NAMESPACE} describe pvc ${PVC_NAME} | grep "Used By:" | rev | cut -d" " -f 1 | rev)
        if [[ $PVC_RESERVATION == "<none>" ]]; then
          RESERVED=0
        fi
      done
    fi
  fi
fi

echo
echo "Launching pv-migrate tool to transfer data to new volume..."
echo

### Creation of temporary PVC ###

MIGRATION_TIME=$(date +'%m%d%Y%s')

mkdir ${MIGRATION_TIME}
touch ${MIGRATION_TIME}/temp-pvc-mutator.yaml

yq eval "
  .metadata.name |= \"pv-mutator-$MIGRATION_TIME\" |
  .metadata.namespace |= \"$NAMESPACE\" |
  .spec.resources.requests.storage |= \"$TARGET_SIZE\" |
  .spec.storageClassName |= \"$TARGET_STORAGECLASS\"
" templates/pvc-template.yaml > ${MIGRATION_TIME}/temp-pvc-mutator.yaml

### Migration from old to new PV ###

kubectl -n $NAMESPACE apply -f ${MIGRATION_TIME}/temp-pvc-mutator.yaml
pv-migrate migrate $PVC_NAME pv-mutator-$MIGRATION_TIME -n $NAMESPACE -N $NAMESPACE --helm-values helm/pv-migrate-values.yaml

### Switch to reclaimPolicy - Retain on PVCs ###
echo
echo "Switching reclaimPolicy of volumes to Retain..."
OLD_VOLUME_NAME=$(kubectl -n ${NAMESPACE} describe pvc ${PVC_NAME} | grep "Volume:" | rev | cut -d" " -f 1 | rev)
NEW_VOLUME_NAME=$(kubectl -n ${NAMESPACE} describe pvc pv-mutator-${MIGRATION_TIME} | grep "Volume:" | rev | cut -d" " -f 1 | rev)
kubectl -n ${NAMESPACE} patch pv ${OLD_VOLUME_NAME} --patch '{"spec": {"persistentVolumeReclaimPolicy": "Retain"}}'
kubectl -n ${NAMESPACE} patch pv ${NEW_VOLUME_NAME} --patch '{"spec": {"persistentVolumeReclaimPolicy": "Retain"}}'

### Deleting temporary PVC ###

echo
echo "Deleting temporary PersistentVolumeClaim..."
kubectl -n ${NAMESPACE} delete pvc pv-mutator-${MIGRATION_TIME}

### Switching target PVC to new values and re-patching PV ###

echo
echo "Editing target PersistentVolumeClaim and PersistentVolume..."

yq eval "
  .spec.volumeName |= \"$NEW_VOLUME_NAME\" |
  .metadata.name |= \"$PVC_NAME\" |
  .metadata.namespace |= \"$NAMESPACE\" |
  .spec.resources.requests.storage |= \"$TARGET_SIZE\" |
  .spec.storageClassName |= \"$TARGET_STORAGECLASS\"
" templates/pvc-template.yaml > ${MIGRATION_TIME}/old-pvc-patch.yaml
kubectl -n ${NAMESPACE} delete pvc ${PVC_NAME}
kubectl -n ${NAMESPACE} apply -f ${MIGRATION_TIME}/old-pvc-patch.yaml

RESOURCE_VERSION=$(kubectl -n ${NAMESPACE} get pvc ${PVC_NAME} -o yaml | grep "resourceVersion:" | rev | cut -d" " -f 1 | rev | cut -d"\"" -f 2)
PVC_UID=$(kubectl -n ${NAMESPACE} get pvc ${PVC_NAME} -o yaml | grep "uid:" | rev | cut -d" " -f 1 | rev)
yq eval "
  .spec.claimRef.name |= \"$PVC_NAME\" |
  .spec.claimRef.namespace |= \"$NAMESPACE\" |
  .spec.claimRef.resourceVersion |= \"$RESOURCE_VERSION\" |
  .spec.claimRef.uid |= \"$PVC_UID\"
" templates/new-pv-association.yaml > ${MIGRATION_TIME}/new-pv-patched-association.yaml
kubectl -n ${NAMESPACE} patch pv ${NEW_VOLUME_NAME} --patch-file ${MIGRATION_TIME}/new-pv-patched-association.yaml

### Recreating target STS ###

if [[ $SET_TYPE == "StatefulSet" ]]; then
  echo
  echo "Editing previously detected StatefulSet..."
  touch ${MIGRATION_TIME}/old-sts.yaml
  touch ${MIGRATION_TIME}/new-sts.yaml
  kubectl -n $NAMESPACE get $SET_NAME -o yaml > ${MIGRATION_TIME}/old-sts.yaml
  yq eval "
    .spec.volumeClaimTemplates[0].spec.resources.requests.storage |= \"$TARGET_SIZE\" |
    .spec.volumeClaimTemplates[0].spec.storageClassName |= \"$TARGET_STORAGECLASS\"
  " ${MIGRATION_TIME}/old-sts.yaml > ${MIGRATION_TIME}/new-sts.yaml
  kubectl -n $NAMESPACE delete $SET_NAME
  kubectl -n $NAMESPACE apply -f ${MIGRATION_TIME}/new-sts.yaml
fi

echo
echo "Migration successful!"
echo "You may now scale your ReplicaSet/StatefulSet back up or migrate other volumes."
echo

exit 0