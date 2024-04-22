#!/bin/bash

###############################################################################
#
#  Проверка серверов кластера для развертывания Ignite 
#
#  Проверяется:
#  1. Доступность портов со стороны сервера
#     на котором запущен скрипт в сторону узлов кластера
#  2. Размеры ОЗУ и файла подкачки
#  3. Информация о процессоре
#  4. Информация о точках монтирования /opt/*
#  5. Версия java
#  6. Версия ОС Linux и ядра
#  7. Пользователь techstack (uid, gid, группы, sudo, chage)
#  8. Пользователь ignite (uid, gid, группы, sudo, chage)
#  9. Проверка на корректность юнита systemd для ignite
#
###############################################################################

# Variables
# ports to check
declare -ri ssh_port=22   # remote hosts SSH port

declare -ra ports_to_check=(
    11211   # JDBC port (and for cli tools like control.sh)
    10800   # thin client port
    47100   # local communication port
    47500   # local discovery port
    49128   # java JMX port
    49129   # java RMI port
    8080    # REST (Web API)
    8443    # Secure REST (https Web API)
)

declare -r ignite_user="ignite"  # пользователь (владелец) ignite на сервере
declare -r need_sudo_to_ignite_user=false   # надо ли выполнять sudo под владельца ignite
                                            # если false - проверяется под текущим пользователем

declare -r systemd_ignite_service="ignite-server.service" # название юнита systemd для ignite
declare -r path_to_ignite_pid="/opt/ignite/logs/ignite-server.pid" # полный путь к pid-файлу для ignite на серверах


###############################################################################

args=$#         # Количество переданных аргументов скрипту
server_list=$1  # Переданный файл со списокм адресов для проверки

print_line () {
    line=""
    for (( i=0; i<$2; i++)); do
        line=${line}$1
    done
    echo "${line}"
}

# -----------------------------------------------------------------------------

if [ ${args} -ne 1 ]; then 
    echo ""
    print_line '!' 75 
    echo "!  ВНИМАНИЕ!  В  качестве параметра скрипту необходимо  передать файл с   !"
    echo "!  перечнем ip-адресов или FQDN серверных узлов по одному узлу в строке,  !"
    echo "!  либо узлы могут быть перечислены в одну строку через пробел.           !"
    echo "!  Пример:                                                                !"
    echo "!      check_the_cluster.sh /<path_to_your_file>/ip.txt                   !"
    print_line '!' 75 
    echo ""
    exit 1
fi

# -----------------------------------------------------------------------------

if ${need_sudo_to_ignite_user} ; then
    sudo_str="sudo -u ${ignite_user}"
else
    sudo_str=""
fi

for server in $(cat "${server_list}"); do 
    # Проверка доступности по порту SSH
    if ! nc -z "${server}" ${ssh_port}; then
        echo -e "\n> Узел  ${server} недоступен!  (!!!)"
        print_line '=' 80
        continue
    fi

    echo -e "\n> Узел:  ${server}"
    ssh_conn_str=" -q ${server} -p ${ssh_port}"

    # Порт 22 уже проверен, а остальные проверяем только если запущен ignite
    declare -i ignite_runned="$( ssh ${ssh_conn_str} "ps aux | grep [i]gnite.sh | wc -l")"
    if [ ${ignite_runned} -eq "0" ]; then
        echo -ne "\n# Проверка портов: 22-OK. Порты Ignite не проверялись, так как процесс не запущен!"
    else
        # Определяем версию Ignite для стандартных путей
        ignite_version=$(ssh ${ssh_conn_str} "${sudo_str} find /opt/ignite/server/libs/ -type f -name ignite-core*.jar 2>/dev/null | grep -Po '[0-9.]+'")
        echo -ne "\n# Обнаружен запущенный Ignite версии ${ignite_version}\n# Проверка портов: 22-OK"
        for port in ${ports_to_check[@]}; do
            if nc -z ${server} ${port} ; then
                echo -n ", ${port}-OK"
            else
                echo -n ", ${port}-FAILED(!)"
            fi
        done
     fi
     echo ""

     # Проверка ОЗУ и файла подкачки
     ram_total=$(ssh ${ssh_conn_str} "free -h | grep Mem | awk '{print \$2}'")
     swap_total=$(ssh ${ssh_conn_str} "free -h | grep Swap | awk '{print \$2}'")
     echo -e "\n# Память (total) - ОЗУ: ${ram_total}, \tSwap: ${swap_total}"

     # Информация о процессоре
     cpu_core=$(ssh ${ssh_conn_str} "lscpu | egrep '^CPU\\(' | awk '{print \$2}' ")
     cpu_model=$(ssh ${ssh_conn_str} "lscpu | grep '^Model name' | awk '{\$1=\$2=\"\"; print \$0}' ")
     cpu_hyper=$(ssh ${ssh_conn_str} "lscpu | grep '^Hypervisor' | awk '{print \$3}' ")
     cpu_virt=$(ssh ${ssh_conn_str} "lscpu | grep '^Virtualization' | awk '{print \$3}' ")

     echo -e "\n# Ядер - ${cpu_core}, процессор: ${cpu_model}, виртуализация ${cpu_hyper}, ${cpu_virt}"

     # Проверка точек монтирования и владельцев
     echo -e "\n\n# Точки монтирования /opt/*"
     ssh ${ssh_conn_str} "lsblk -o MOUNTPOINT,SIZE | grep '/opt/' | sort -u"

     for mount_path in $(ssh ${ssh_conn_str} "lsblk -o MOUNTPOINT | grep '/opt/' | sort -u"); do
         root_files=$(ssh ${ssh_conn_str} "ls -l ${mount_path} | grep root")
         if [ -n "${root_files}" ]; then
             echo -e "\nВ точке монтирования ${mount_path} обнаружены файлы с владельцем  root!"
             echo ${root_files}
         fi
     done

     # Проверка версии java
     java_version=$(ssh ${ssh_conn_str} "java --version | head -n1")
     echo -e "\n\n# Используемая java: ${java_version}"

     # Проверка версии OS Linux
     pretty_name_os=$(ssh ${ssh_conn_str} 'grep PRETTY_NAME /etc/os-release | cut -d\" -f2')
     kernel=$(ssh ${ssh_conn_str} "uname -r")
     echo -e "\n# Операционная система: ${pretty_name_os}, ядро: ${kernel}"

     # Проверка пользователя techstack
     techstack_uid=$(ssh ${ssh_conn_str} "grep techstack /etc/passwd | cut -d: -f3")
     techstack_gid=$(ssh ${ssh_conn_str} "grep techstack /etc/passwd | cut -d: -f4")
     techstack_groups=$(ssh ${ssh_conn_str} "groups techstack | cut -d: -f2")
     if [ $(ssh ${ssh_conn_str} "chage -l techstack | grep never | wc -l") -eq 3 ]; then
        techstack_chage="OK"
     else
        techstack_chage="Необходимо сменить пароль!"
     fi 
     if [ $(ssh ${ssh_conn_str} "sudo -l | grep '\(ignite\) NOPASSWD: ALL' | wc -l") -eq 1 ]; then
        techstack_sudo="OK"
     else
        techstack_sudo="FAIL!"
     fi
     echo -e  "\n# Пользователь techstack: chage - ${techstack_chage}, sudo - ${techstack_sudo}, UID=${techstack_uid}, GID=${techstack_gid}, входит в группы:${techstack_groups}"

     # Проверка пользователя ignite
     ignite_uid=$(ssh ${ssh_conn_str} "grep ignite /etc/passwd | cut -d: -f3")
     ignite_gid=$(ssh ${ssh_conn_str} "grep ignite /etc/passwd | cut -d: -f4")
     ignite_groups=$(ssh ${ssh_conn_str} "groups ignite | cut -d: -f2")
     if [ $(ssh ${ssh_conn_str} "${sudo_str} chage -l ignite | grep never | wc -l") -eq 3 ]; then
        ignite_chage="OK"
     else
        ignite_chage="Необходимо сменить пароль!"
     fi 
     if [ $(ssh ${ssh_conn_str} "${sudo_str} sudo -l | grep '\(ALL\)' | wc -l") -ge 30 ]; then
        ignite_sudo="OK"
     else
        ignite_sudo="FAIL! Необходимо проверить на соответствие новому чек-листу"
     fi
     echo -e  "\n# Пользователь ignite: chage - ${ignite_chage}, sudo - ${ignite_sudo}, UID=${ignite_uid}, GID=${ignite_gid}, входит в группы:${ignite_groups}"

     # Проверка юнита ignite-server ( что pid ищется по правильному пути )
     if [ $(ssh ${ssh_conn_str} "grep '${path_to_ignite_pid}' /etc/systemd/system/${systemd_ignite_service} | wc -l" ) -ne 1 ]; then
        echo -e "\n# Внимание! Некорректный юнит ${systemd_ignite_service}! Не использовать запуск череез systemctl без правки юнита!"
     fi

     print_line '=' 80
done
