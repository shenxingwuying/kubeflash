#!/bin/bash

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

# 帮助信息
function help_info ()
{
    echo "
    命令示例：sh k8sworker_setup.sh -v 1.13.1
    参数说明:
        -v:version      kubernetes版本，默认为1.13.1
        -h:help         帮助命令
    "
}



function reset_env()
{
  # 重置kubeadm
  echo "----------------重置系统环境--------------------"
  echo -e "y\n" | sudo kubeadm reset

  # 重置iptables
  sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
  sudo sysctl net.bridge.bridge-nf-call-iptables=1

  # 重置网卡信息
  sudo ip link del cni0
  sudo ip link del flannel.1

  # 关闭防火墙
  sudo systemctl stop firewalld
  sudo systemctl disable firewalld

  # 禁用SELINUX
  setenforce 0

  # vim /etc/selinux/config
  sudo sed -i "s/SELINUX=.*/SELINUX=disable/g" /etc/selinux/config

  # 关闭系统的Swap方法如下:
  # 编辑`/etc/fstab`文件，注释掉引用`swap`的行，保存并重启后输入:
  sudo swapoff -a #临时关闭swap
  sudo sed -i 's/.*swap.*/#&/' /etc/fstab 
  sudo yum-complete-transaction --cleanup-only
}


function setup_docker()
{

  echo "----------------检查Docker是否安装--------------------"
  sudo yum list installed | grep 'docker'
  if [  $? -ne 0 ];then
    echo "Docker未安装"
    echo "----------------安装 Docker--------------------"
    # 卸载docker
    sudo yum remove -y $(rpm -qa | grep docker)
    # 安装docker
    sudo yum install -y yum-utils device-mapper-persistent-data lvm2
    sudo yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    sudo yum install -y docker-ce
    # 重启docker
    sudo systemctl enable docker
    sleep 10
  else
    echo "Docker已安装"
  fi

  update_docker_daemon_json
}



function update_docker_daemon_json()
{
    sudo sed -i "s/PRIVATE_REGISTRY/${DOCKER_REGISTRY}/g" daemon.json
    sudo mv /etc/docker/daemon.json /etc/docker/daemon.json.bak
    sudo mv daemon.json /etc/docker/daemon.json
    sudo systemctl restart docker
    sleep 10
}

function reset_docker_daemon_json()
{
    sudo mv /etc/docker/daemon.json.bak /etc/docker/daemon.json
    sudo systemctl restart docker
    sleep 10
}


function change_yum_src()
{
  echo "----------------修改yum源--------------------"
  # 修改为aliyun yum源
cat <<EOF > kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

  sudo mv kubernetes.repo /etc/yum.repos.d/
}

function reset_kubenetes()
{
  # 查看可用版本
  # sudo yum list --showduplicates | grep 'kubeadm\|kubectl\|kubelet'
  # 安装 kubeadm, kubelet 和 kubectl
  echo "----------------移除kubelet kubeadm kubectl--------------------"
  sudo yum remove -y kubelet kubeadm kubectl


  echo "----------------删除残留配置文件--------------------"
  # 删除残留配置文件
  modprobe -r ipip
  lsmod
  sudo rm -rf ~/.kube/
  sudo rm -rf /etc/kubernetes/
  sudo rm -rf /etc/systemd/system/kubelet.service.d
  sudo rm -rf /etc/systemd/system/kubelet.service
  sudo rm -rf /usr/bin/kube*
  sudo rm -rf /etc/cni
  sudo rm -rf /opt/cni
  sudo rm -rf /var/lib/etcd
  sudo rm -rf /var/etcd
}


function init_kubelet()
{
  echo "----------------安装 cni/kubelet/kubeadm/kubectl--------------------"
  # 安装 cni/kubelet/kubeadm/kubectl
  sudo yum install -y kubernetes-cni-0.6.0-0.x86_64 kubelet-${KUBE_VERSION} kubeadm-${KUBE_VERSION} kubectl-${KUBE_VERSION} --disableexcludes=kubernetes
  # 重新加载 kubelet.service 配置文件
  sudo systemctl daemon-reload

  echo "----------------启动 kubelet--------------------"
  # 启动 kubelet
  sudo systemctl enable kubelet
  sudo systemctl restart kubelet

}


while getopts ":v:rh" opt
do
    case $opt in
        r)
            DOCKER_REGISTRY=($OPTARG)
            ;;
        v)
            KUBE_VERSION=($OPTARG)
            ;;
        h)
            help_info
            exit 0
            ;;
        ?)
            echo "无效的参数"
            help_info
            exit 1
            ;;
    esac
done


if [ "${KUBE_VERSION}" = "" ];then
  KUBE_VERSION=1.13.1
fi

if [ "${DOCKER_REGISTRY}" = "" ];then
  DOCKER_REGISTRY=registry.cn-beijing.aliyuncs.com
fi

echo "========================================================="
echo "Kubernetes版本： ${KUBE_VERSION}"
echo "Docker注册处：   ${DOCKER_REGISTRY}"
echo "========================================================="

reset_env
check_cmd_result
setup_docker
check_cmd_result
change_yum_src
check_cmd_result
reset_kubenetes
check_cmd_result
init_kubelet
check_cmd_result
# 重置 docker daemon.json
reset_docker_daemon_json