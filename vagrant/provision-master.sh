#!/bin/bash

set -ex
source $(dirname $0)/provision-config.sh

OPENSHIFT_SDN=$4

# Setup hosts file to support ping by hostname to each minion in the cluster from apiserver
node_list=""
minion_ip_array=(${MINION_IPS//,/ })
for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
  minion=${MINION_NAMES[$i]}
  node_list="${node_list},${minion}"
  ip=${minion_ip_array[$i]}
  if [ ! "$(cat /etc/hosts | grep $minion)" ]; then
    echo "Adding $minion to hosts file"
    echo "$ip $minion" >> /etc/hosts
  fi
done
node_list=${node_list:1}

# Install the required packages
yum install -y docker-io git golang e2fsprogs hg net-tools bridge-utils

# Build openshift
echo "Building openshift"
pushd /vagrant
  ./hack/build-go.sh
  cp _output/local/go/bin/openshift /usr/bin
  ./hack/install-etcd.sh
popd

# Initialize certificates
echo "Generating certs"
pushd /vagrant
  /usr/bin/openshift admin create-all-certs --overwrite=false --master=https://${MASTER_IP}:8443 --hostnames=${MASTER_IP},${MASTER_NAME} --nodes=${node_list}
popd

# Start docker
systemctl enable docker.service
systemctl start docker.service

# Create systemd service
cat <<EOF > /usr/lib/systemd/system/openshift-master.service
[Unit]
Description=OpenShift Master
Requires=docker.service network.service
After=network.service

[Service]
ExecStart=/usr/bin/openshift start master --master=${MASTER_IP} --nodes=${node_list}
WorkingDirectory=/vagrant/

[Install]
WantedBy=multi-user.target
EOF

# Start the service
systemctl daemon-reload
systemctl start openshift-master.service

# if SDN requires service on master, then set it up
if [ "${OPENSHIFT_SDN}" != "ovs-gre" ]; then
  export ETCD_CA=/vagrant/openshift.local.certificates/ca/cert.crt
  export ETCD_CLIENT_CERT=/vagrant/openshift.local.certificates/master/etcd-client.crt
  export ETCD_CLIENT_KEY=/vagrant/openshift.local.certificates/master/etcd-client.key
  $(dirname $0)/provision-master-sdn.sh $@
fi

# Set up the KUBECONFIG environment variable for use by osc
echo 'export KUBECONFIG=/vagrant/openshift.local.certificates/admin/.kubeconfig' >> /root/.bash_profile
echo 'export KUBECONFIG=/vagrant/openshift.local.certificates/admin/.kubeconfig' >> /home/vagrant/.bash_profile
