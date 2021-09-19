#!/usr/bin/env bash

export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_USER=$(gcloud config get-value core/account) # set current user
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export IDNS=${PROJECT_ID}.svc.id.goog # workflow identity domain

export GCP_REGION="us-west1"

export ISTIO_VERSION="1.9.1"
export ISTIO_ARCH="x86_64"

export TEST_OU="msparr"
export TEST_OU_DOMAIN="msparr.com"
export TEST_DOMAIN="secure.msparr.com"

# enable apis
gcloud services enable compute.googleapis.com \
    container.googleapis.com 

# create cluster
gcloud beta container --project $PROJECT_ID clusters create "west" \
    --region $GCP_REGION \
    --no-enable-basic-auth \
    --release-channel "regular" \
    --machine-type "e2-medium" \
    --image-type "COS" \
    --disk-type "pd-standard" \
    --disk-size "100" \
    --metadata disable-legacy-endpoints=true \
    --scopes "https://www.googleapis.com/auth/cloud-platform" \
    --preemptible \
    --num-nodes "1" \
    --enable-stackdriver-kubernetes \
    --enable-ip-alias \
    --network "projects/${PROJECT_ID}/global/networks/default" \
    --subnetwork "projects/${PROJECT_ID}/regions/${GCP_REGION}/subnetworks/default" \
    --default-max-pods-per-node "110" \
    --enable-autoscaling --min-nodes "0" --max-nodes "3" \
    --no-enable-master-authorized-networks \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing,NodeLocalDNS,GcePersistentDiskCsiDriver \
    --enable-autoupgrade --enable-autorepair --max-surge-upgrade 2 --max-unavailable-upgrade 1 \
    --enable-vertical-pod-autoscaling \
    --workload-pool "${PROJECT_ID}.svc.id.goog" \
    --enable-shielded-nodes

# download istio (latest)
curl -L https://istio.io/downloadIstio | ISTION_VERSION=$ISTIO_VERSION TARGET_ARCH=$ISTIO_ARCH sh -
cd istio-${ISTIO_VERSION}
export PATH=$PWD/bin:$PATH # add istioctl to path

# install demo istio
istioctl install --set profile=demo -y

# enable sidecar auto-injection
kubectl label namespace default istio-injection=enabled

# ---------------- SECURE GATEWAY ------------------------
# ref: https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/#before-you-begin
# ref: https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/

# install httpbin demo
kubectl apply -f samples/httpbin/httpbin.yaml

# check IP and ports
kubectl get svc istio-ingressgateway -n istio-system
export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
export TCP_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="tcp")].nodePort}')
export INGRESS_HOST="34.105.102.105"

# enable firewall (delete previous if applicable)
gcloud compute firewall-rules create allow-gateway-http --allow "tcp:$INGRESS_PORT"
gcloud compute firewall-rules create allow-gateway-https --allow "tcp:$SECURE_INGRESS_PORT"

# create root certificate
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
    -subj '/O=example Inc./CN=${TEST_OU_DOMAIN}' -keyout ${TEST_OU_DOMAIN}.key -out ${TEST_OU_DOMAIN}.crt

# create cert/key for httpbin
openssl req -out ${TEST_DOMAIN}.csr -newkey rsa:2048 \
    -nodes -keyout ${TEST_DOMAIN}.key -subj "/CN=${TEST_DOMAIN}/O=${TEST_OU} organization"
openssl x509 -req -days 365 -CA ${TEST_OU_DOMAIN}.crt -CAkey ${TEST_OU_DOMAIN}.key \
    -set_serial 0 -in ${TEST_DOMAIN}.csr -out ${TEST_DOMAIN}.crt

# create secret for ingress gateway
kubectl create -n istio-system secret tls secure-credential \
    --key=${TEST_DOMAIN}.key --cert=${TEST_DOMAIN}.crt

# define TLS ingress gateway
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: secure-gateway
  # namespace: istio-system
spec:
  selector:
    istio: ingressgateway # use istio default ingress gateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: secure-credential # must be the same as secret
    hosts:
    - "*" # ${TEST_DOMAIN}
EOF

# configure routes for ingress
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: httpbin
  # namespace: istio-system
spec:
  hosts:
  - "${TEST_DOMAIN}"
  gateways:
  - secure-gateway
  http:
  - match:
    - uri:
        prefix: /status
    - uri:
        prefix: /delay
    route:
    - destination:
        host: httpbin
        port:
          number: 8000
EOF

# test with secure curl request
curl -v -HHost:${TEST_DOMAIN} --resolve "${TEST_DOMAIN}:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
    --cacert ${TEST_OU_DOMAIN}.crt "https://${TEST_DOMAIN}:$SECURE_INGRESS_PORT/status/418"

# < 

#     -=[ teapot ]=-

#        _...._
#      .'  _ _ `.
#     | ."` ^ `". _,
#     \_;`"---"`|//
#       |       ;/
#       \_     _/
#         `"""`
# * Connection #0 to host ${TEST_DOMAIN} left intact
# * Closing connection 0

# -------------- GKE Ingress ------------------

# create static external IP address
gcloud compute addresses create web-static-ip --global
sleep 10
export STATIC_IP=$(gcloud compute addresses describe web-static-ip --global --format="get(address)")

echo "You must update DNS for ${TEST_DOMAIN} with A record IP ${STATIC_IP}"
echo

# create managed cert
cat <<EOF | kubectl apply -f -
apiVersion: networking.gke.io/v1beta1
kind: ManagedCertificate
metadata:
  name: example-cert
  namespace: istio-system
spec:
  domains:
    - ${TEST_DOMAIN}
EOF

# create backend config for health check
cat <<EOF | kubectl apply -f -
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: http-hc-config
  namespace: istio-system
spec:
  healthCheck:
    checkIntervalSec: 15
    port: 15021
    type: HTTP
    requestPath: /healthz/ready
EOF

# edit the istio-ingressgateway service (change to NodePort and add annotations)
# apiVersion: v1
# kind: Service
# metadata:
#   annotations:
#     cloud.google.com/app-protocols: '{"https":"HTTPS"}'
#     cloud.google.com/backend-config: '{"ports": {"443":"http-hc-config"}}'

# create GKE ingress
cat <<EOF | kubectl apply -f -

apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: secure-ingress
  namespace: istio-system
  annotations:
    kubernetes.io/ingress.allow-http: "false"
    kubernetes.io/ingress.global-static-ip-name: "web-static-ip"
    networking.gke.io/managed-certificates: "example-cert"
spec:
  rules:
  - host: ${TEST_DOMAIN}
    http:
      paths:
      - path: /*
        backend:
          serviceName: istio-ingressgateway
          servicePort: https
EOF

# test traffic via load balancer (may take 10-20 min. before ready)
curl -v "https://${TEST_DOMAIN}/status/418"

# < HTTP/2 418 
# < server: istio-envoy
# < date: Sun, 14 Mar 2021 17:31:28 GMT
# < x-more-info: http://tools.ietf.org/html/rfc2324
# < access-control-allow-origin: *
# < access-control-allow-credentials: true
# < content-length: 135
# < x-envoy-upstream-service-time: 3
# < via: 1.1 google
# < alt-svc: clear
# < 

#     -=[ teapot ]=-

#        _...._
#      .'  _ _ `.
#     | ."` ^ `". _,
#     \_;`"---"`|//
#       |       ;/
#       \_     _/
#         `"""`
# * Connection #0 to host secure.msparr.com left intact
# * Closing connection 0

# --------------- Debug HTTP(S) LB header ----------------
kubectl create deployment echo --image=k8s.gcr.io/echoserver:1.4
kubectl expose deployment echo --type=NodePort --port=8080

cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: echo
  # namespace: istio-system
spec:
  hosts:
  - "${TEST_DOMAIN}"
  gateways:
  - secure-gateway
  http:
  - match:
    - uri:
        prefix: /echo
    route:
    - destination:
        host: echo
        port:
          number: 8080
EOF

echo "Visit: https://${TEST_DOMAIN}/echo in browser and check host in header"


# --------------- NEXT TRY mTLS and different app ---------------
