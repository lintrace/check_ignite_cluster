#!/bin/bash

###############################################################################
#
#  Проверка серверов кластера для развертывания Ignite 
#
#  Проверяется:
#  1. Доступность портов со стороны сервера
#     на котором запущен скрипт в сторону узлов кластера
#  2. Размеры ОЗУ и файла подкачки
#  3. Информация о процессоре, виртуализации
#  4. Информация о точках монтирования под нужды ignite при их наличии
#  5. Версия java
#  6. Версия ОС Linux и ядра
#  7. Пользователь ${maintenance_user} (uid, gid, группы, sudo, chage)
#  8. Пользователь ${ignite_user} (uid, gid, группы, sudo, chage)
#  9. Проверка на корректность юнита systemd для ignite
#
###############################################################################

# ports to check
declare -ri ssh_port=22   # SSH port

declare -ra ports_to_check=(
    11211   # JDBC port (and for cli tools like control.sh)
    10800   # thin client port
    47100   # local communication port
    47500   # local discovery port
    49128   # java JMX port
    1099    # java RMI port
    8080    # REST (Web API)
    8443    # Secure REST (https Web API)
)

# УЗ обслуживающего персонала с возможностью подключения по SSH к серверам
declare -r maintenance_user="<admin>"

# Пользователь (владелец) процесса ignite на сервере.
# Т.е. от имени какого пользователя запускается ignite
declare -r ignite_user="<ignite owner>"

# надо ли выполнять sudo под владельца [ignite_user]
# если false, то эскалация привелегий не выполняется, а проверка производится от имени [maintenance_user]
declare -r need_sudo_to_ignite_user=false

# Где искать точки монтирования каталогов под нужды ignite
# Если точек монтирования нет, или проверка не тебуется, оставьте строку пустой ""
# Если точки монтирования в директории /opt/, то и указываем "/opt/"
declare -r fs_mount_points_for_ignite=""

# Глубина поиска в точках монтирования файлов, не принадлежащих пользователю [ignite_user]
declare -r fs_mount_points_not_ignite_user_depth=1

# название юнита systemd для ignite, либо пустая строка, если проверка не требуется
declare -r systemd_ignite_service="ignite-server.service"

# полный путь к pid-файлу для ignite на серверах.
# используется лишь тогда, когда название юнита в [systemd_ignite_service] не пустая строка
declare -r path_to_ignite_pid="/opt/ignite/logs/ignite-server.pid"

###############################################################################

# Рисует строку из указанного символа повторением N
# print_line <символ> <кол-во повторений N>
print_line () {
    local line=""
    for (( i=0; i<$2; i++ )); do
        line=${line}$1
    done
    echo "${line}"
}

# -----------------------------------------------------------------------------

# Проверка пользователя
# user_check <login пользователя> <строка подключения ssh> <строка - критерий поиска grep в выводе sudo -l>  <количество совпадений критерия для успешной проверки>
user_check () {
    local user=$1
    local ssh_conn=$2
    local sudo_check_string=$3
    local sudo_check_matches=$4
    local grep_passwd_out="$(ssh ${ssh_conn} "grep ${user} /etc/passwd")"
    if [ -z "${grep_passwd_out}" ]; then
        echo -e "\n# ВНИМАНИЕ! Пользователя ${user} не существует!"
        return 1
    fi
    local user_uid="$(echo ${grep_passwd_out} | cut -d: -f3)"
    local user_gid="$(echo ${grep_passwd_out} | cut -d: -f4)"
    local user_groups="$(ssh ${ssh_conn_str} "groups ${user}" | cut -d: -f2)"
    if [ $(ssh ${ssh_conn} "chage -l ${user}" | grep -c "never") -ge 3 ]; then
        local user_chage="OK"
    else
        local user_chage="Необходимо сменить пароль и/или отключить срок действия пароля!"
    fi
    if [ $(ssh ${ssh_conn} "sudo -l" | grep -c "${sudo_check_string}") -ge "${sudo_check_matches}" ]; then
        local user_sudo="OK"
    else
        local user_sudo="FAIL! (необходимо проверить вывод sudo -l на соответствие чек-листу)"
    fi
    echo -e  "\n# Пользователь ${user}: chage - ${user_chage}, sudo - ${user_sudo}, UID=${user_uid}, GID=${user_gid}, входит в группы:${user_groups}"
    return 0
}

###############################################################################

args=$#         # Количество переданных аргументов скрипту
server_list=$1  # Переданный файл со списокм адресов для проверки

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
    if ! nc -z ${server} ${ssh_port}; then
        echo -en "\n> Узел ${server} недоступен по порту ${ssh_port} (ssh)"
        if ping -c 1 ${server} 1>/dev/null; then
            echo ", при этом сам узел обнаруживается в сети! Проверьте, запущена ли служба sshd?"
        else
            echo " и не отвечает на ping (!)"
        fi
        print_line '=' 80
        continue
    fi

    echo -e "\n> Узел:  ${server}"
    ssh_conn_str=" -q ${server} -p ${ssh_port} -l ${maintenance_user}"
    
    ps_cmd_out="$( ssh ${ssh_conn_str} "ps aux | grep '[i]gnite.sh.*/libs/\*'")"
    if [ $? -eq 255 ]; then
        echo "Не удалось подключиться через ssh по порту ${ssh_port}! Проверьте логин [maintenance_user] и ключи ssh!"
        print_line '=' 80
        continue
    fi

    # Порт 22 уже проверен, а остальные проверяем только если запущен ignite
    if [ -z "${ps_cmd_out}" ]; then
        echo -ne "\n# Проверка портов: 22-OK. Порты Ignite не проверялись, так как процесс не запущен!"
    else
        # Определяем версию Ignite
        run_ignite_libs_path="$(echo "${ps_cmd_out}" | rev | grep -Po "\*/sbil/[^(\s|:)]+" | rev | cut -d* -f1)"
        run_ignite_version=$(ssh ${ssh_conn_str} "${sudo_str} find ${run_ignite_libs_path} -type f -name ignite-core-*jar 2>/dev/null" | grep -Po '[\d]+\.[\d]+\.[\d]+')
        run_ignite_user="$(echo ${ps_cmd_out} | awk '{print $1}')"
        echo -ne "\n# Запущен Ignite версии ${run_ignite_version} под пользователем ${run_ignite_user}\n# Проверка портов: 22-OK"
        for port in "${ports_to_check[@]}"; do
            if nc -z ${server} "${port}" ; then
                echo -n ", ${port}-OK"
            else
                echo -n ", ${port}-FAILED(!)"
            fi
        done
     fi
     echo ""

     # Проверка ОЗУ и файла подкачки
     free_cmd_out="$(ssh ${ssh_conn_str} "free -h")" 
     ram_total="$(echo "${free_cmd_out}" | grep Mem | awk '{print $2}')"
     swap_total="$(echo "${free_cmd_out}" | grep Swap | awk '{print $2}')"
     echo -e "\n# Память (total) - ОЗУ: ${ram_total}, \tSwap: ${swap_total}"

     # Информация о процессоре
     lscpu_cmd_out="$(ssh ${ssh_conn_str} "lscpu")"
     cpu_core="$( echo "${lscpu_cmd_out}" | grep -E "^CPU\\(" | cut -d: -f2 | xargs )"
     cpu_model="$( echo "${lscpu_cmd_out}" | grep "^Model name" | cut -d: -f2 | xargs )"
     cpu_hyper="$( echo "${lscpu_cmd_out}" | grep "^Hypervisor" | cut -d: -f2 | xargs )"
     cpu_virt="$( echo "${lscpu_cmd_out}" | grep "^Virtualization" | cut -d: -f2 | xargs )"

     echo -en "\n# Ядра: ${cpu_core}, процессор: ${cpu_model}"
     if [ -n "${cpu_hyper}" ]; then
         echo " [виртуальная машина, гипервизор: ${cpu_hyper}, виртуализация: ${cpu_virt}]"
     else
         echo " [BAREMETAL, поддерживаемая виртуализация: ${cpu_virt}]"
     fi

     # Проверка точек монтирования и владельцев
     if [ -n "${fs_mount_points_for_ignite}" ]; then
         lsblk_cmd_out="$(ssh ${ssh_conn_str} "lsblk -o MOUNTPOINT,SIZE" | grep "${fs_mount_points_for_ignite}" | sort -u)"
         echo -en "\n# Точки монтирования в ${fs_mount_points_for_ignite}*"
         if [ -z "${lsblk_cmd_out}" ]; then 
             echo " отсутствуют!"
         else
             echo -e "\n${lsblk_cmd_out}"
             for mount_path in $(echo "${lsblk_cmd_out}" | awk '{print $1}'); do
                 not_ignite_user_files=$(ssh ${ssh_conn_str} "find ${mount_path}  -maxdepth ${fs_mount_points_not_ignite_user_depth} \! -user ${ignite_user} 2>/dev/null")
                 if [ -n "${not_ignite_user_files}" ]; then
                     echo -e "\nВ точке монтирования ${mount_path} обнаружены файлы с владельцем, отличным от ${ignite_user}!"
                     echo ${not_ignite_user_files}
                 fi
             done
         fi
     fi

     # Проверка версии java
     java_version=$(ssh ${ssh_conn_str} "java --version | head -n1")
     echo -e "\n# Используемая java: ${java_version}"

     # Проверка версии OS Linux
     pretty_name_os="$(ssh ${ssh_conn_str} "grep PRETTY_NAME /etc/os-release" | cut -d\" -f2)"
     kernel="$(ssh ${ssh_conn_str} "uname -r")"
     echo -e "\n# Операционная система: ${pretty_name_os}, ядро: ${kernel}"

     # Проверка пользователя [maintenance_user]
     user_check "${maintenance_user}" "${ssh_conn_str}" "\(${ignite_user}\).*NOPASSWD.*ALL" "1"

     # Проверка пользователя [ignite_user]
     user_check "${ignite_user}" "${ssh_conn_str}" "\(ALL\)" "30"

     # Проверка юнита ignite-server ( что pid ищется по правильному пути )
     if [ -n "${systemd_ignite_service}" ]; then
         unit_full_path="/etc/systemd/system/${systemd_ignite_service}"
         if [ $(ssh ${ssh_conn_str} "if [ -e ${unit_full_path} ]; then cat ${unit_full_path}; fi" |  grep -c "${path_to_ignite_pid}" ) -ne 1 ]; then
            echo -e "\n# Внимание! Некорректный юнит ${systemd_ignite_service}! Не использовать запуск через systemctl без правки юнита!"
         fi
     fi

     print_line '=' 80
done
