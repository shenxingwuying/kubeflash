#!/bin/bash

# 帮助信息
function help_info ()
{
    echo "
    命令示例：sh k8smaster_setup.sh -m \"10.120.200.1,10.120.200.2,10.120.200.3\" \
                                   -n \"10.120.200.4,10.120.200.5,10.120.200.6\" \
                                   -p 123456 -v 1.13.1 -a yes
    参数说明:
        -a:admin        生成管理员账户，可选值：yes,no，默认为no
        -m:masters      master IP列表，用逗号分隔
        -n:nodes        node IP列表，用逗号分隔 
        -p:password     用户密码，如果不设置密码，则默认使用ssh建立机器互信
        -v:version      kubernetes版本，默认为1.13.1
        -h:help         帮助命令
    "
}

# 检查命令执行是否成功
function check_cmd_result ()
{
    if [ $? -ne 0 ];then
        echo "执行失败，退出程序~"
        exit 1
    else
        echo "执行成功!"
    fi
}


function easy_connect()
{

  echo "----------------配置免密登录--------------------"
  if [ ! -f "${RSA_PATH}" ];then
    ssh-keygen -t rsa -N '' -f ${RSA_PATH} -C "k8s-key"
  fi
  for host in ${K8S_MASTER_LIST[@]}; do
      expect rsa_copy.sh ${RSA_PATH} ${KUBE_USER} ${PASSWD} ${host}
  done

  for host in ${K8S_NODE_LIST[@]}; do
      expect rsa_copy.sh ${RSA_PATH} ${KUBE_USER} ${PASSWD} ${host}
  done
}

# 安装 Pip
function setup_pip()
{
  echo "----------------检查 Pip 是否安装--------------------"
  sudo yum list installed | grep 'python2-pip'
  if [  $? -ne 0 ];then
    echo "Pip未安装"
    echo "----------------安装 Pip--------------------"
    sudo sudo yum -y install python-pip
  else
    echo "Pip 已安装"
  fi
}

# 安装 sshpass
function setup_sshpass()
{
  echo "----------------检查 sshpass 是否安装--------------------"
  sudo yum list installed | grep 'sshpass'
  if [  $? -ne 0 ];then
    echo "sshpass 未安装"
    echo "----------------安装 sshpass--------------------"
    sudo sudo yum -y install sshpass
  else
    echo "sshpass 已安装"
  fi
}

function setup_ansible()
{
  echo "----------------检查Ansible是否安装--------------------"
  sudo yum list installed | grep 'ansible'
  if [  $? -ne 0 ];then
    echo "Ansible未安装"
    echo "----------------安装 Ansible--------------------"
    sudo yum install -y ansible
    setup_sshpass
    if [ ! -f "/usr/lib/python2.7/site-packages/ansible/plugins/vars/__init__.py" ];then
      setup_pip
      sudo pip install ansible --upgrade
    fi
  else
    echo "Ansible已安装"
  fi

  rm -f k8s_hosts
  echo "[${ANSIBLE_K8S_MASTERS}]" >> k8s_hosts
  for host in ${K8S_MASTER_LIST[@]}; do
    if [ "${host}" != "${IP}" ];then
      if [ "${PASSWD}" = "" ];then
        echo ${host} ansible_ssh_user=${KUBE_USER} ansible_ssh_port=22 ansible_ssh_private_key_file=${RSA_PATH} >> k8s_hosts
      else
        echo ${host} ansible_ssh_user=${KUBE_USER} ansible_ssh_port=22 ansible_ssh_pass=${PASSWD} >> k8s_hosts
      fi
    fi
  done

  echo "" >> k8s_hosts

  echo "[${ANSIBLE_K8S_NODES}]" >> k8s_hosts
  for host in ${K8S_NODE_LIST[@]}; do
    if [ "${PASSWD}" = "" ];then
        echo ${host} ansible_ssh_user=${KUBE_USER} ansible_ssh_port=22 ansible_ssh_private_key_file=${RSA_PATH} >> k8s_hosts
      else
        echo ${host} ansible_ssh_user=${KUBE_USER} ansible_ssh_port=22 ansible_ssh_pass=${PASSWD} >> k8s_hosts
      fi
  done

  echo "/etc/ansible/hosts 内容如下："
  cat k8s_hosts
  sudo mv k8s_hosts /etc/ansible/hosts
  sudo sed -i 's/.*\(host_key_checking\)/\1/' /etc/ansible/ansible.cfg
}


function config_cni()
{
  echo "----------------配置cni--------------------"
  # 配置cni
  sudo mkdir -p /etc/cni/net.d/

cat <<EOF > 10-flannel.conflist
{
  "name": "cbr0",
  "plugins": [
    {
      "type": "flannel",
      "delegate": {
        "hairpinMode": true,
        "isDefaultGateway": true
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      }
    }
  ]
}
EOF
  sudo mv 10-flannel.conflist /etc/cni/net.d/
}


function init_kubeadm()
{
  echo "----------------配置 kubeadm--------------------"
  # 生成配置文件
  kubeadm config print init-defaults ClusterConfiguration > kubeadm.conf 

  # 修改配置文件
  # 修改镜像仓储地址
  sed -i "s#imageRepository: .*#imageRepository: ${DOCKER_IMAGE_PATH}#g" kubeadm.conf
  # 修改版本号
  # echo "controlPlaneEndpoint: ${IP}:8443" >> kubeadm.conf
  sed -i "s/controlPlaneEndpoint: .*/controlPlaneEndpoint: ${IP}:6443/g" kubeadm.conf
  sed -i "s/kubernetesVersion: .*/kubernetesVersion: v1.13.1/g" kubeadm.conf
  sed -i "s/advertiseAddress: .*/advertiseAddress: ${IP}/g" kubeadm.conf
  sed -i "s/podSubnet: .*/podSubnet: \"10.244.0.0\/16\"/g" kubeadm.conf

  # 拉取镜像
  sudo kubeadm config images pull --config kubeadm.conf

  echo "----------------初始化 kubeadm--------------------"
  # 初始化master节点
  rm -f k8s_init.log
  sudo kubeadm init --config kubeadm.conf | tee k8s_init.log
  KUBEADM_JOIN_CMD=`grep 'kubeadm join' k8s_init.log`

  echo "----------------重启 API Server--------------------"
  # 修改配置文件
  sudo sed -i "s/insecure-port=0/insecure-port=8080/g" /etc/kubernetes/manifests/kube-apiserver.yaml
  # 重启docker镜像
  sleep 10
  # sudo docker ps |grep 'kube-apiserver_kube-apiserver'|awk '{print $1}'|head -1|xargs sudo docker restart
}

function copy_files()
{
  echo "----------------分发证书--------------------"
  # 分发证书
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m command -a 'sudo mkdir -p /etc/kubernetes/pki/etcd' --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/pki/ca.crt dest=/etc/kubernetes/pki/ca.crt" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/pki/ca.key dest=/etc/kubernetes/pki/ca.key" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/pki/sa.key dest=/etc/kubernetes/pki/sa.key" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/pki/sa.pub dest=/etc/kubernetes/pki/sa.pub" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/pki/front-proxy-ca.crt dest=/etc/kubernetes/pki/front-proxy-ca.crt" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/pki/front-proxy-ca.key dest=/etc/kubernetes/pki/front-proxy-ca.key" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/pki/etcd/ca.crt dest=/etc/kubernetes/pki/etcd/ca.crt" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/pki/etcd/ca.key dest=/etc/kubernetes/pki/etcd/ca.key" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=/etc/kubernetes/admin.conf dest=/etc/kubernetes/admin.conf" --sudo
}

function install_masters()
{
  sudo ansible ${ANSIBLE_K8S_NODES} -u ${KUBE_USER} -m copy -a "src=docker-daemon.cfg dest=~/docker-daemon.json" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m copy -a "src=k8sworker_setup.sh dest=~/k8sworker_setup.sh" --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m command -a 'sh ~/k8sworker_setup.sh' --sudo
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m command -a "sed -i 's#insecure-port=0#insecure-port=8080#g' /etc/kubernetes/manifests/kube-apiserver.yaml" --sudo
}

function install_nodes()
{
  sudo ansible ${ANSIBLE_K8S_NODES} -u ${KUBE_USER} -m copy -a "src=k8sworker_setup.sh dest=~/k8sworker_setup.sh" --sudo
  sudo ansible ${ANSIBLE_K8S_NODES} -u ${KUBE_USER} -m copy -a "src=docker-daemon.cfg dest=~/docker-daemon.json" --sudo
  sudo ansible ${ANSIBLE_K8S_NODES} -u ${KUBE_USER} -m command -a 'sh ~/k8sworker_setup.sh' --sudo
}

function masters_join()
{
  sudo ansible ${ANSIBLE_K8S_MASTERS} -u ${KUBE_USER} -m command -a "${KUBEADM_JOIN_CMD} --experimental-control-plane" --sudo
}

function nodes_join()
{
  sudo ansible ${ANSIBLE_K8S_NODES} -u ${KUBE_USER} -m command -a "${KUBEADM_JOIN_CMD}" --sudo
}

function create_token()
{
  echo "----------------生成 Token--------------------"
  KUBE_TOKEN=`sudo kubeadm token list | awk '{print $1}' | tail -1`
  TOKEN_TTL=`sudo kubeadm token list | awk '{print $2}' | tail -1`
  # 判断 token 是否已过期
  if [[ "${KUBE_TOKEN}" = "" ]] || [[ "${TOKEN_TTL}" = "" ]] || [[ "${TOKEN_TTL}" = "0h" ]] ;then
    echo "----------------Token 已过期，重新生成 Token--------------------"
    KUBE_TOKEN=`sudo kubeadm token create`
  fi
  KUBE_CERT_HASH=`openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'`

  # kubeadm join 10.120.200.2:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:965f3dd4c9c0c1d3e2258383360d1efe4f5285a05f48587ab49463d4b526145b
  KUBEADM_JOIN_CMD="kubeadm join ${IP}:6443 --token ${KUBE_TOKEN} --discovery-token-ca-cert-hash sha256:${KUBE_CERT_HASH}"
}

function install_kube_dashboard()
{
  echo "----------------安装 kubernetes-dashboard --------------------"
  # 创建Dashboard UI
  sed -i "s#k8s.gcr.io#${DOCKER_IMAGE_PATH}#g" kubernetes-dashboard.yaml
  sudo kubectl create -f kubernetes-dashboard.yaml
  sudo kubectl -n kube-system get service kubernetes-dashboard
}

function create_dashboard_admin()
{
  if [ "${CREATE_ADMIN_SA}" = "yes" ];then
    echo "----------------生成管理员账户--------------------"
    kubectl create -f admin-sa.yaml
    ADMIN_TOKEN_NAME=`kubectl get secret -n kube-system|grep admin-token | awk '{print $1}'`
    ADMIN_SA_TOKEN=`kubectl get secret ${ADMIN_TOKEN_NAME} -o jsonpath={.data.token} -n kube-system |base64 -d`
  fi
}

function install_calico()
{
  echo "----------------安装 Calico 网络插件--------------------"
  sudo docker pull ${DOCKER_IMAGE_PATH}/ctl:v1.10.0
  sudo docker pull ${DOCKER_IMAGE_PATH}/kube-policy-controller:v0.7.0
  sudo docker pull ${DOCKER_IMAGE_PATH}/node:v2.5.1
  sudo kubectl apply -f rbac.yaml
  sed -i "s/etcd_endpoints: .*/etcd_endpoints: ${IP}:2379/g" calico.yaml
  sed -i "s#quay.io/calico#${DOCKER_IMAGE_PATH}#g" calico.yaml
  sudo kubectl apply -f calico.yaml
}

function install_flannel()
{
  echo "----------------安装 Flannel 网络插件 --------------------"
  sudo kubectl apply -f rbac.yaml
  sudo sysctl net.bridge.bridge-nf-call-iptables=1
  sed -i "s#quay.io/coreos#${DOCKER_IMAGE_PATH}#g" kube-flannel.yml
  sudo kubectl apply -f kube-flannel.yml
}


OLD_IFS="$IFS" 
IFS="," 
while getopts "a:d:m:n:p:u:vh" opt
do
    case $opt in
        a)
            CREATE_ADMIN_SA="yes"
            ;;
        d)
            NEED_KUBE_DASHBOARD=($OPTARG)
            ;;
        m)
            K8S_MASTER_LIST=($OPTARG)
            ;;
        n)
            K8S_NODE_LIST=($OPTARG)
            ;;
        p)
            PASSWD=($OPTARG)
            ;;
        v)
            KUBE_VERSION=($OPTARG)
            ;;
        h)
            IFS="$OLD_IFS"
            help_info
            exit 0
            ;;
        ?)
            echo "无效的参数"
            IFS="$OLD_IFS"
            help_info
            exit 1
            ;;
    esac
done
IFS="$OLD_IFS"

# cd ~

IP=`ip addr | grep 'state UP' -A2 | grep -v 'veth\|link\|inet6\|cni\|--' | tail -n1 | awk '{print $2}' | cut -f1 -d '/'`
if [ "${KUBE_USER}" = "" ];then
  KUBE_USER=`whoami`
fi

ANSIBLE_K8S_MASTERS=k8s_masters
ANSIBLE_K8S_NODES=k8s_nodes
RSA_PATH="/home/${KUBE_USER}/.ssh/k8s_rsa"

# docker 镜像地址
DOCKER_IMAGE_PATH=docker2.yidian.com:5000/k8simages
if [ "${DOCKER_IMAGE_PATH}" = "" ];then
  DOCKER_IMAGE_PATH=registry.cn-beijing.aliyuncs.com/imcto
fi

DOCKER_REGISTRY=`echo ${DOCKER_IMAGE_PATH%/*}`



if [ "${KUBE_VERSION}" = "" ];then
  KUBE_VERSION=1.13.1
fi

echo ""
echo "=============================================================="
echo "Kubernetes版本：${KUBE_VERSION}"
echo "本机IP：        ${IP}"
echo "用户：          ${KUBE_USER}"
echo "密码：          ${PASSWD}"
echo "rsa文件目录：    ${RSA_PATH}"
echo "Docker注册处：  ${DOCKER_REGISTRY}"
echo ""
echo "Master 节点列表："
for host in ${K8S_MASTER_LIST[@]}; do
    echo ${host}
    if [ "${host}" = "${IP}" ];then
      INIT_KUBEADM=true
    fi
done
echo ""
echo "Node 节点列表："
for host in ${K8S_NODE_LIST[@]}; do
    echo ${host}
done
echo "=============================================================="

sudo yum list installed | grep 'expect'
if [  $? -ne 0 ];then
  sudo yum install -y expect
fi

# 配置ssh免密登录
if [ "${PASSWD}" = "" ];then
  easy_connect
  check_cmd_result
fi

setup_ansible
check_cmd_result

# 如果 master 列表中包含本机IP，则初始化本机 kubernetes 环境
if [ "${INIT_KUBEADM}" = "true" ];then
  # 安装本机
  sh k8sworker_setup.sh -v ${KUBE_VERSION} -r ${DOCKER_REGISTRY}

  init_kubeadm
  check_cmd_result

  install_kube_dashboard
  install_flannel
else
  create_token
fi

# 如果不包含，则获取 token，拼接 kubeadm join 命令
echo ${KUBEADM_JOIN_CMD}

# 部署 master 节点
install_masters
check_cmd_result
copy_files
check_cmd_result
masters_join

# 部署 node 节点
install_nodes
check_cmd_result
nodes_join
check_cmd_result
# 清理hosts文件，保护用户隐私
sudo rm -f /etc/ansible/hosts
# 输出kubernetes-dashboard信息
sudo kubectl -n kube-system get service kubernetes-dashboard

# 生成管理员账户
create_dashboard_admin
if [ "${ADMIN_SA_TOKEN}" != "" ];then
  echo "管理员账户 Token 为："
  echo ""
  echo ${ADMIN_SA_TOKEN}
  echo ""
fi

echo "集群节点列表："
kubectl get nodes