#!/bin/bash

############################################################
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
#  9. Проверка на корректность юнита ignite-server
#
###########################################################

args=$#         # Количество переданных аргументов скрипту
server_list=$1  # Переданный файл со списокм адресов для проверки

print_line () {
    line=""
    for (( i=0; i<$2; i++)); do {
        line=${line}$1
    }
    done
    echo ${line}
}

# ------------------------------------------------------

if [ ${args} -ne 1 ]; then {
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
}
fi

# ------------------------------------------------------

for server in $(cat ${server_list}); do {
    # Проверка доступности по порту 22 (ssh)
    nc -z ${server} 22
    if [ $? -ne 0 ]; then {
        echo -e "\n> Узел  ${server} недоступен!  (!!!)"
        print_line '=' 80
        continue
    }
    fi
    
    echo -e "\n> Узел:  ${server}"
    # Порт 22 уже проверен, а остальные проверяем только если запущен ignite
    ignite_runned=$( ssh -q ${server} "ps aux | grep [i]gnite.sh | wc -l"  ) 
    if [ ${ignite_runned} -eq 0 ]; then { 
        echo -ne "\n# Проверка портов: 22-OK, порты Ignite не проверялись, так как он не запущен!"
    } else {
        # Определяем версию Ignite для стандартных путей
        ignite_version=$(ssh -q ${server} "sudo -u ignite find /opt/ignite/server/libs/ -type f -name ignite-core*.jar 2>/dev/null | grep -Po '[0-9.]+'")
        echo -ne "\n# Обнаружен запущенный Ignite версии ${ignite_version}\n# Проверка портов: 22-OK"
        for port in 11211 10800 1098 1099 8080 8443; do {
            nc -z ${server} ${port}
            if [ $? -eq 0 ] ; then {
                echo -n ", ${port}-OK"
            } else {
                echo -n ", ${port}-FAILED(!)"
            }
            fi
            }
        done
        }
     fi
     echo ""

     # Проверка ОЗУ и файла подкачки
     ram_total=$(ssh -q ${server} "free -h | grep Mem | awk '{print \$2}'")
     swap_total=$(ssh -q ${server} "free -h | grep Swap | awk '{print \$2}'")
     echo -e "\n# Память (total) - ОЗУ: ${ram_total}, \tSwap: ${swap_total}"

     # Информация о процессоре
     cpu_core=$(ssh -q ${server} "lscpu | egrep '^CPU\\(' | awk '{print \$2}' ")
     cpu_model=$(ssh -q ${server} "lscpu | grep '^Model name' | awk '{\$1=\$2=\"\"; print \$0}' ")
     cpu_hyper=$(ssh -q ${server} "lscpu | grep '^Hypervisor' | awk '{print \$3}' ")
     cpu_virt=$(ssh -q ${server} "lscpu | grep '^Virtualization' | awk '{print \$3}' ")

     echo -e "\n# Ядер - ${cpu_core}, процессор: ${cpu_model}, виртуализация ${cpu_hyper}, ${cpu_virt}"

     # Проверка точек монтирования и владельцев
     echo -e "\n\n# Точки монтирования /opt/*"
     ssh -q ${server} "lsblk -o MOUNTPOINT,SIZE | grep '/opt/' | sort -u"

     for mount_path in $(ssh -q ${server} "lsblk -o MOUNTPOINT | grep '/opt/' | sort -u"); do {
         root_files=$(ssh -q ${server} "ls -l ${mount_path} | grep root")
         if [ -n "${root_files}" ]; then { 
             echo -e "\nВ точке монтирования ${mount_path} обнаружены файлы с владельцем  root!"
             echo ${root_files}
         }
         fi
     }
     done

     # Проверка версии java
     java_version=$(ssh -q ${server} "java --version | head -n1")
     echo -e "\n\n# Используемая java: ${java_version}"

     # Проверка версии OS Linux
     pretty_name_os=$(ssh -q ${server} 'grep PRETTY_NAME /etc/os-release | cut -d\" -f2')
     kernel=$(ssh -q ${server} "uname -r")
     echo -e "\n# Операционная система: ${pretty_name_os}, ядро: ${kernel}"

     # Проверка пользователя techstack
     techstack_uid=$(ssh -q ${server} "grep techstack /etc/passwd | cut -d: -f3")
     techstack_gid=$(ssh -q ${server} "grep techstack /etc/passwd | cut -d: -f4")
     techstack_groups=$(ssh -q ${server} "groups techstack | cut -d: -f2")
     if [ $(ssh -q ${server} "chage -l techstack | grep never | wc -l") -eq 3 ]; then {
        techstack_chage="OK"
     } else {
        techstack_chage="Необходимо сменить пароль!"
     }
     fi 
     if [ $(ssh -q ${server} "sudo -l | grep '\(ignite\) NOPASSWD: ALL' | wc -l") -eq 1 ]; then {
        techstack_sudo="OK"
     } else {
        techstack_sudo="FAIL!"
     }
     fi
     echo -e  "\n# Пользователь techstack: chage - ${techstack_chage}, sudo - ${techstack_sudo}, UID=${techstack_uid}, GID=${techstack_gid}, входит в группы:${techstack_groups}"

     # Проверка пользователя ignite
     ignite_uid=$(ssh -q ${server} "grep ignite /etc/passwd | cut -d: -f3")
     ignite_gid=$(ssh -q ${server} "grep ignite /etc/passwd | cut -d: -f4")
     ignite_groups=$(ssh -q ${server} "groups ignite | cut -d: -f2")
     if [ $(ssh -q ${server} "sudo -u ignite chage -l ignite | grep never | wc -l") -eq 3 ]; then {
        ignite_chage="OK"
     } else {
        ignite_chage="Необходимо сменить пароль!"
     }
     fi 
     if [ $(ssh -q ${server} "sudo -u ignite sudo -l | grep '\(ALL\)' | wc -l") -ge 30 ]; then {
        ignite_sudo="OK"
     } else {
        ignite_sudo="FAIL! Необходимо проверить на соответствие новому чек-листу"
     }
     fi
     echo -e  "\n# Пользователь ignite: chage - ${ignite_chage}, sudo - ${ignite_sudo}, UID=${ignite_uid}, GID=${ignite_gid}, входит в группы:${ignite_groups}"

     # Проверка юнита ignite-server ( что pid ищется по правильному пути )
     if [ $(ssh -q ${server} "grep 'PIDFile=/opt/ignite/logs/ignite-server.pid' /etc/systemd/system/ignite-server.service | wc -l" ) -ne 1 ]; then {
        echo -e "\n# Внимание! Некорректный юнит ignite-server.service! Не использовать запуск череез systemctl без правки юнита!"
     }
     fi

     print_line '=' 80
};
done
