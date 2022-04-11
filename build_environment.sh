#!/bin/bash

set -eu

CLUSTER_LOCATION="asia-northeast1-b"
REGION="asia-northeast1"

echo -n "Project ID: "
read PROJECT_ID

# Initialize a timer
SECONDS=0
echo "##### Set a default project as ${PROJECT_ID} #####"

gcloud config set project ${PROJECT_ID}

echo
echo "##### Enable required APIs #####"
gcloud services enable container.googleapis.com compute.googleapis.com

echo
echo "##### Create two VPCs for GKE clusters"
for num in 01 02; do
  gcloud compute networks create vpc${num} \
    --subnet-mode=auto \
    --bgp-routing-mode=regional
done

echo
echo "##### Create two GKE clusters #####"
for num in 01 02; do
  gcloud container clusters create cluster${num} \
    --zone=${CLUSTER_LOCATION} \
    --machine-type=e2-standard-4 \
    --num-nodes=2 \
    --workload-pool=${PROJECT_ID}.svc.id.goog \
    --release-channel regular
    --enable-ip-alias \
    --network "projects/${PROJECT_ID}/global/networks/vpc${num}" \
    --subnetwork "projects/${PROJECT_ID}/regions/${REGION}/subnetworks/vpc${num}" \
    --async
done

set +e
while true; do
  ACTIVE_CLUSTER=$(gcloud container clusters list | grep -c RUNNING)
  if [ ${ACTIVE_CLUSTER} -eq 2 ]; then
    echo "Successfully created 2 GKE clusters"
    break
  fi
  echo "waiting for GKE clusters to be ready..."
  sleep 30
done

set -e
echo
echo "##### Get authentication credentials of GKE clusters #####"
for num in 01 02
do
  gcloud container clusters get-credentials cluster${num} \
    --zone=${CLUSTER_LOCATION}
  kubectl config rename-context gke_${PROJECT_ID}_${CLUSTER_LOCATION}_cluster${num} cluster${num}
done

echo
echo "##### Download asmcli"
curl https://storage.googleapis.com/csm-artifacts/asm/asmcli_1.13 > asmcli
chmod +x asmcli

echo
echo "##### Install Anthos Service Mesh"
for num in 01 02; do
  ./asmcli install \
    --project_id ${PROJECT_ID} \
    --cluster_name cluster${num} \
    --cluster_location ${CLUSTER_LOCATION} \
    --output_dir asm_output${num} \
    --enable_all \
    --ca mesh_ca
done

echo
echo "##### Deploy istio ingress-gateways"
for num in 01 02; do
  kubectl config use-context cluster${num}
  kubectl create namespace ingressgateway-ns
  REVISION=$(kubectl get deploy -n istio-system -l app=istiod -o jsonpath={.items[*].metadata.labels.'istio\.io\/rev'}'{"\n"}')
  kubectl label namespace ingressgateway-ns istio.io/rev=${REVISION} --overwrite
  kubectl apply -n ingressgateway-ns -f asm_output${num}/samples/gateways/istio-ingressgateway
done

echo
echo "##### Deploy Online Boutique applications"
for num in 01 02; do
  kubectl config use-context cluster${num}
  REVISION=$(kubectl get deploy -n istio-system -l app=istiod -o jsonpath={.items[*].metadata.labels.'istio\.io\/rev'}'{"\n"}')
  kubectl apply -f asm_output${num}/samples/online-boutique/kubernetes-manifests/namespaces
  for ns in ad cart checkout currency email frontend loadgenerator payment product-catalog recommendation shipping; do
    kubectl label namespace $ns istio.io/rev=${REVISION} --overwrite
  done
  kubectl apply -f asm_output${num}/samples/online-boutique/kubernetes-manifests/deployments
  kubectl apply -f asm_output${num}/samples/online-boutique/kubernetes-manifests/services
  kubectl apply -f asm_output${num}/samples/online-boutique/istio-manifests/allow-egress-googleapis.yaml
  kubectl apply -f asm_output${num}/samples/online-boutique/istio-manifests/frontend-gateway.yaml
done

echo "Successfully deployed Online Boutique applications per GKE cluster with Anthos Service Mesh 🎉🎉"

echo
cat << EOM
What's next?
- Confirm services status on ASM dashboard
  https://console.cloud.google.com/anthos/services?project=${PROJECT_ID}
- Confirm ASM(Istio) related metrics from Metrics Explorer on Cloud Monitoring
  https://console.cloud.google.com/monitoring/metrics-explorer?project=${PROJECT_ID}
EOM

# Print the duration of this script
duration=$SECONDS
echo
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."
