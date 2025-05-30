#!/bin/bash

while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    --mysql-user)
    MYSQL_USER=$2
    shift
    shift
    ;;
    --mysql-password)
    MYSQL_PASSWORD=$2
    shift
    shift
    ;;
    --donor-ip)
    DONOR_IP=$2
    shift
    shift
    ;;
    --additional-primary)
    ADDITIONAL_PRIMARY=$2
    shift
    shift
    ;;
    --scenario)
    SCENARIO=$2
    shift
    shift
    ;;
    --diagnostic)
    diagnostic=YES
    shift
    ;;
    --check-corrupts)
    check_corrupts=YES
    shift
    ;;
    --debug)
    debug=YES
    shift
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done

usage() {
SCRIPTNAME=$(basename "$BASH_SOURCE")
echo "    USAGE:"
echo "        COMMAND RUN:  "
echo "             $SCRIPTNAME --mysql-user 'MYSQL USER NAME' --mysql-password 'MYSQL USER PASSWORD' --replica-password 'PASSWORD FOR REPLICA' --donor-ip 'MYSQL PRIMARY IP ADDRESS' --scenario [SCENARIO NAME]"
echo "             Diagnostic Run Example: $SCRIPTNAME --diagnostic"
echo "             Database Corruption Run Example: $SCRIPTNAME --check-corrupts"
echo "             Restore Run Example: $SCRIPTNAME --donor-ip '192.168.0.1' --scenario restore_primary_from_primary"
echo "             Init Run Example: $SCRIPTNAME --mysql-user 'mysql-12445' --mysql-password 'password123' --scenario init"
echo "        ARGUMENTS:    "
echo "              --mysql-user - MySQL user with the LOCK TABLES privileges [USED FOR INIT ONLY]"
echo "              --mysql-password - MySQL user password [USED FOR INIT ONLY]"
echo "              --donor-ip - IP address of the operable MySQL server from which the failed node will be restored"
echo "                           In the case of Galera cluster recovery, skip this parameter"
echo "              --additional-primary - IP address of additional primary MySQL server. This parameter should be used in multi slave configuration"
echo "              --scenario - Restoration scenario; the following arguments are supported:"
echo "                           restore_primary_from_primary - restore failed primary node from another primary"
echo "                           restore_secondary_from_primary - restore secondary node from primary"
echo "                           restore_primary_from_secondary - restore primary node from secondary"
echo "                           restore_galera - restore Galera cluster"
echo "                           promote_new_primary - promote new primary form secondary node"
echo "              --diagnostic - Run node diagnostic only (without recovery)"
echo "              --check-corrupts - Run database corruption check"
echo "              --debug - Run the script in detailed output mode"
echo "        NOTICE:"
echo "              - The restore_primary_from_primary, restore_secondary_from_primary, and restore_primary_from_secondary scenarios should be run from a node that should be restored."
echo "                For example, we run the script in the diagnostic mode for the primary-secondary topology, and it returns a result that secondary replication is broken."
echo "                We run a restoration scenario from the secondary node and set the --donor-ip parameter as the MySQL primary node IP."
echo "              - There are no such restrictions for the Galera scenario - the restoration can be run from any node."
echo
}


if [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ]; then
  [[ -z "${REPLICA_USER}" ]] && { echo "Environment variable REPLICA_USER do not set"; exit 1; }
  [[ -z "${REPLICA_PSWD}" ]] && { echo "Environment variable REPLICA_PSWD do not set"; exit 1; }
  MYSQL_USER=${REPLICA_USER}
  MYSQL_PASSWORD=${REPLICA_PSWD}
fi

if [[ "${diagnostic}" != "YES" ]] && [[ "${check_corrupts}" != "YES" ]]; then
  [ "${SCENARIO}" == "init" ] && DONOR_IP='localhost'
  [ "${SCENARIO}" == "promote_new_primary" ] && DONOR_IP='localhost'
  if [ -z "${DONOR_IP}" ] || [ -z "${SCENARIO}" ]; then
      echo "Not all arguments passed!"
      usage
      exit 1;
  fi
  if [[ "${DONOR_IP}" != "galera" && "${DONOR_IP}" != "localhost" && ! "${DONOR_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "Invalid donor-ip specified: '${DONOR_IP}'. Allowed values: 'galera', 'localhost' or a valid IP address."
      exit 1
  fi
fi

RUN_LOG="/var/log/db_recovery.log"
PRIVATE_KEY='/root/.ssh/id_rsa_db_monitoring'
SSH="timeout 300 ssh -i ${PRIVATE_KEY} -T -o StrictHostKeyChecking=no"
PRIMARY_CONF='/etc/mysql/conf.d/master.cnf'
SECONDARY_CONF='/etc/mysql/conf.d/slave.cnf'
GALERA_CONF='/etc/mysql/conf.d/galera.cnf'
REPLICATION_INFO='/var/lib/mysql/primary-position.info'

SUCCESS_CODE=0
FAIL_CODE=99
AUTHORIZATION_ERROR_CODE=701
CORRUPT_CHECK_FAIL_CODE=97
SERVICE_FAIL_CODE=96
SERVICE_FAIL_MESSAGE="mysql or mariadb command not found"

#NODE_ADDRESS=$(ifconfig | grep 'inet' | awk '{ print $2 }' |grep -E '^(192\.168|10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.)')
NODE_ADDRESS=$(host $(hostname) | awk '/has.*address/{print $NF; exit}')

if command -v mariadb &> /dev/null; then
  MYSQL="mariadb"
else
  if command -v mysql &> /dev/null; then
    MYSQL="mysql"
  else
    echo "{result: $SERVICE_FAIL_CODE, error: \"$SERVICE_FAIL_MESSAGE\"}"
    exit 0
  fi
fi

source /etc/jelastic/metainf.conf

COMPUTE_TYPE_FULL_VERSION_FORMATTED=$(sed -re 's/^([[:digit:]]+)\.([[:digit:]]+).*/\1\2/' <<< ${COMPUTE_TYPE_FULL_VERSION} )

if [[ ("$COMPUTE_TYPE" == "mysql" || "$COMPUTE_TYPE" == "percona") && "$COMPUTE_TYPE_FULL_VERSION_FORMATTED" -ge "81" ]]; then
  STOP_SLAVE="STOP REPLICA"
  START_SLAVE="START REPLICA"
  RESET_SLAVE="RESET REPLICA"
  RESET_SLAVE_ALL="RESET REPLICA ALL"
  CHANGE_MASTER="CHANGE REPLICATION SOURCE"
  MASTER_USER="SOURCE_USER"
  MASTER_PASSWORD="SOURCE_PASSWORD"
  MASTER_HOST="SOURCE_HOST"
  MASTER_LOG_FILE="SOURCE_LOG_FILE"
  MASTER_LOG_POS="SOURCE_LOG_POS"
  SHOW_MASTER_STATUS="SHOW BINARY LOG STATUS"
  SHOW_SLAVE_STATUS="SHOW REPLICA STATUS"
  GET_MASTER_PUBLIC_KEY="GET_SOURCE_PUBLIC_KEY"

elif [[ "$COMPUTE_TYPE" == "mariadb" && "$COMPUTE_TYPE_FULL_VERSION_FORMATTED" -ge "110" ]]; then
  STOP_SLAVE="STOP REPLICA"
  START_SLAVE="START REPLICA"
  RESET_SLAVE="RESET REPLICA"
  RESET_SLAVE_ALL="RESET REPLICA ALL"
  START_ALL_SLAVES="START ALL REPLICAS"
  STOP_ALL_SLAVES="STOP ALL REPLICAS"
  CHANGE_MASTER="CHANGE MASTER"
  MASTER_USER="MASTER_USER"
  MASTER_PASSWORD="MASTER_PASSWORD"
  MASTER_HOST="MASTER_HOST"
  MASTER_LOG_FILE="MASTER_LOG_FILE"
  MASTER_LOG_POS="MASTER_LOG_POS"
  SHOW_MASTER_STATUS="SHOW BINLOG STATUS"
  SHOW_SLAVE_STATUS="SHOW REPLICA STATUS"
  SHOW_ALL_SLAVES_STATUS="SHOW ALL REPLICAS STATUS"
  GET_MASTER_PUBLIC_KEY="GET_SOURCE_PUBLIC_KEY"

else
  STOP_SLAVE="STOP SLAVE"
  START_SLAVE="START SLAVE"
  RESET_SLAVE="RESET SLAVE"
  RESET_SLAVE_ALL="RESET SLAVE ALL"
  START_ALL_SLAVES="START ALL SLAVES"
  STOP_ALL_SLAVES="STOP ALL SLAVES"
  CHANGE_MASTER="CHANGE MASTER"
  MASTER_USER="MASTER_USER"
  MASTER_PASSWORD="MASTER_PASSWORD"
  MASTER_HOST="MASTER_HOST"
  MASTER_LOG_FILE="MASTER_LOG_FILE"
  MASTER_LOG_POS="MASTER_LOG_POS"
  SHOW_MASTER_STATUS="SHOW MASTER STATUS"
  SHOW_SLAVE_STATUS="SHOW SLAVE STATUS"
  SHOW_ALL_SLAVES_STATUS="SHOW ALL SLAVES STATUS"
  GET_MASTER_PUBLIC_KEY="GET_MASTER_PUBLIC_KEY"  
fi


mysqlCommandExec(){
  command="$1"
  server_ip=$2
  MYSQL_PWD=${MYSQL_PASSWORD} $MYSQL -u${MYSQL_USER} -h${server_ip} -e "$command"
}

mysqlNoTablesCommandExec(){
  command="$1"
  server_ip=$2
  MYSQL_PWD=${MYSQL_PASSWORD} $MYSQL -u${MYSQL_USER} -h${server_ip} -sNe "$command"
}

mysqlCommandExec2(){
  command="$1"
  server_ip=$2
  MYSQL_PWD=${MYSQL_PASSWORD} $MYSQL -u${MYSQL_USER} -h${server_ip} -sNe "$command"
}

log(){
  local message="$1"
  local timestamp
  timestamp=`date "+%Y-%m-%d %H:%M:%S"`
  echo -e "[${timestamp}]: ${message}" >> ${RUN_LOG}
  [[ "$debug" != "YES" ]] || >&2 echo -e "[${timestamp}]: ${message}"
}


cleanSyncData(){
  local mysql_src_ip=$1
  rsync -e "ssh -i ${PRIVATE_KEY} -o StrictHostKeyChecking=no" -Sa \
    --progress \
    --delete  \
    --exclude=auto.cnf \
    --exclude=mysqld.pid \
    --exclude=mysql.sock \
    --exclude=mysql-bin.* \
    root@${mysql_src_ip}:/var/lib/mysql/ /var/lib/mysql/
}


resyncData(){
  local mysql_src_ip=$1
  rsync -e "ssh -i ${PRIVATE_KEY} -o StrictHostKeyChecking=no" -Sa \
    --progress \
    --exclude=auto.cnf \
    --exclude=mysqld.pid \
    --exclude=mysql.sock \
    --exclude=mysql-bin.* \
    root@${mysql_src_ip}:/var/lib/mysql/ /var/lib/mysql/
}


getNodeType(){
  [[ -f ${PRIMARY_CONF} ]] && { echo "primary"; return ${SUCCESS_CODE}; }
  [[ -f ${SECONDARY_CONF} ]] && { echo "secondary"; return ${SUCCESS_CODE}; }
  [[ -f ${GALERA_CONF} ]] && { echo "galera"; return ${SUCCESS_CODE}; }
  return ${FAIL_CODE}
}


checkAuth(){
  local cluster_hosts
  local nodeType
  #
  nodeType=$(getNodeType)
  if [[ "${nodeType}" == "galera" ]]; then
    cluster_hosts=$(grep wsrep_cluster_address ${GALERA_CONF} |awk -F '/' '{print $3}'|xargs -d ',')
  else
    cluster_hosts="${DONOR_IP:=localhost}"
  fi

  for host in ${cluster_hosts}
  do
    check_count=$((check_count+1))
    stderr=$( { mysqlCommandExec "exit" "${host}"; } 2>&1 ) && return ${SUCCESS_CODE}
    [[ x"$(echo ${stderr}| grep 'ERROR 1045')" != x ]] && { echo ${stderr}; return ${FAIL_CODE}; }
  done

  if [[ "${nodeType}" == "galera" ]]; then
    log "Authentication check: There are no hosts with running MySQL, can't check. Set check result as OK...done"
    return ${SUCCESS_CODE}
  else
    [[ "${diagnostic}" != "YES" ]] || return ${SUCCESS_CODE}
    echo "Can't connect to MySQL server on host ${cluster_hosts}"
    return ${FAIL_CODE}
  fi

}


execResponse(){
  local result=$1
  local error=$2
  response=$(jq -cn --argjson  result "$result" --arg scenario "${SCENARIO}" --arg address "${NODE_ADDRESS}" --arg error "$error" '{result: $result, scenario: $scenario, address: $address, error: $error}')
  echo "${response}"
}


execSshAction(){
  local action="$1"
  local message="$2"
  local result=${FAIL_CODE}

  action_to_base64=$(echo $action|base64 -w 0)
  stderr=$( { sh -c "$(echo ${action_to_base64}|base64 -d)"; } 2>&1 ) && { log "${message}...done"; } || {
    error="${message} failed, please check ${RUN_LOG} for details"
    execResponse "${result}" "${error}"
    log "${message}...failed\n==============ERROR==================\n${stderr}\n============END ERROR================";
    exit 0
  }
}


execSshReturn(){
  local action="$1"
  local message="$2"
  local result=${FAIL_CODE}

  action_to_base64=$(echo $action|base64 -w 0)
  stdout=$( { sh -c "$(echo ${action_to_base64}|base64 -d)"; } 2>&1 ) && { echo ${stdout}; log "${message}...done"; } || {
    error="${message} failed, please check ${RUN_LOG} for details"
    execResponse "${result}" "${error}"
    log "${message}...failed\n==============ERROR==================\n${stdout}\n============END ERROR================";
    exit 0
  }
}


execAction(){
  local action="$1"
  local message="$2"
  local result=${FAIL_CODE}

  [[ "${action}" == 'checkAuth' ]] && result=${AUTHORIZATION_ERROR_CODE}
  [[ "${action}" == 'liveMysqlCheck' ]] && result=${CORRUPT_CHECK_FAIL_CODE}
  [[ "${action}" == 'offlineMysqlCheck' ]] && result=${CORRUPT_CHECK_FAIL_CODE}
  stderr=$( { ${action}; } 2>&1 ) && { log "${message}...done"; } || {
    error="${message} failed, please check ${RUN_LOG} for details"
    execResponse "${result}" "${error}"
    log "${message}...failed\n==============ERROR==================\n${stderr}\n============END ERROR================";
    exit 0
  }
}


setPrimaryReadonly(){
  local mysql_src_ip=$1
  mysqlCommandExec 'flush tables with read lock;' "${mysql_src_ip}"
}

getUserAuthPlugin(){
  local node=$1
  local user=$2
  local plugin
  plugin=$(mysqlNoTablesCommandExec "SELECT plugin FROM mysql.user WHERE User = '$user' and Host = '%';" ${node})
  echo $plugin
}

setReplicaUserFromEnv(){
  local nodeType
  nodeType=$(getNodeType)
  [[ "${nodeType}" != "secondary" ]] && { echo "Note type is not secondary"; return ${SUCCESS_CODE}; }
  [[ -z "${REPLICA_USER}" ]] && { echo "Environment variable REPLICA_USER do not set"; return ${FAIL_CODE}; }
  [[ -z "${REPLICA_PSWD}" ]] && { echo "Environment variable REPLICA_PSWD do not set"; return ${FAIL_CODE}; }
  mysqlCommandExec "${STOP_SLAVE}; ${RESET_SLAVE}; ${CHANGE_MASTER} TO ${MASTER_USER} = '${REPLICA_USER}', ${MASTER_PASSWORD} = '${REPLICA_PSWD}'; ${START_SLAVE};" "localhost"
  local plugin="$(getUserAuthPlugin 'localhost' ${REPLICA_USER})"
  if [[ x$plugin == *"caching_sha2_password"* ]]; then
    mysqlCommandExec "${STOP_SLAVE}; ${CHANGE_MASTER_TO} ${GET_MASTER_PUBLIC_KEY}=1; ${START_SLAVE};" "localhost"}
  fi
}

getPrimaryPosition(){
  local node=$1
  local masterName=$2
  echo "File=$(mysqlCommandExec "${SHOW_MASTER_STATUS}\G;" ${node} |grep 'File'|cut -d ':' -f2|sed 's/ //g')" > ${REPLICATION_INFO}
  echo "Position=$(mysqlCommandExec "${SHOW_MASTER_STATUS}\G;" ${node}|grep 'Position'|cut -d ':' -f2|sed 's/ //g')" >> ${REPLICATION_INFO}
  if [[ -n "${ADDITIONAL_PRIMARY}" ]]; then
    echo "ReportHost=${node}" >> ${REPLICATION_INFO}
  else
    echo "ReportHost=$(mysqlCommandExec 'show variables like "report_host" \G;' ${node}|grep 'Value'|cut -d ':' -f2|sed 's/ //g')" >> ${REPLICATION_INFO}
  fi
  echo "ReplicaUser=${REPLICA_USER}" >> ${REPLICATION_INFO}
  echo "ReplicaPassword=${REPLICA_PSWD}" >> ${REPLICATION_INFO}
  echo "MasterName=${masterName}" >> ${REPLICATION_INFO}
}

getSecondaryStatus(){
  local node=$1
  local secondary_running_values
  local SHOW_SLAVE_COMMAND="${SHOW_ALL_SLAVES_STATUS}\G;"

  mysqlCommandExec "${SHOW_SLAVE_COMMAND}" ${node} > /dev/null 2>&1
  [[ $? != 0 ]] && SHOW_SLAVE_COMMAND="${SHOW_SLAVE_STATUS}\G;"


  slave_ok=$(mysqlCommandExec "${SHOW_SLAVE_COMMAND}" ${node} |grep -E 'Slave_IO_Running:|Slave_SQL_Running:' |wc -l)
  secondary_running_values=$(mysqlCommandExec "${SHOW_SLAVE_COMMAND}" ${node} |grep -E 'Slave_IO_Running:|Slave_SQL_Running:' |grep -i yes|wc -l)

  if [[ ${secondary_running_values} != ${slave_ok} ]]; then
    echo "failed"
    log "[Node: ${node}]: Secondary is not running...failed\n ${secondary_running_values}"
    return ${FAIL_CODE}
  fi
  echo "ok"
  log "[Node: ${node}]: Secondary is running...done"
}



removeSecondaryFromPrimary(){
  local node=$1
  mysqlCommandExec "${STOP_SLAVE}; ${RESET_SLAVE_ALL};" ${node}
}


getPrimaryStatus(){
  local node=$1
  local is_primary_have_binlog
  local is_primary_have_secondary
  local status="failed"

  is_primary_have_binlog=$(mysqlCommandExec "${SHOW_MASTER_STATUS}\G" "${node}" |grep -E 'File|Position'|wc -l)
  is_primary_have_secondary=$(mysqlCommandExec "${SHOW_SLAVE_STATUS}\G" "${node}" |grep -E 'Slave_IO_Running:|Slave_SQL_Running:'|wc -l)
  if [[ ${is_primary_have_binlog} == 2 ]] && [[ ${is_primary_have_secondary} == 0 ]]; then
    echo 'ok'
    log "[Node: ${node}]: Primary status...ok"
    return ${SUCCESS_CODE}
  elif [[ ${is_primary_have_binlog} == 2 ]] && [[ ${is_primary_have_secondary} == 2 ]]; then
    status=$(getSecondaryStatus "${node}")
    echo "${status}"
    return ${SUCCESS_CODE}
  fi
  echo "${status}"
  log "[Node: ${node}]: Looks like primary not configured, ${SHOW_MASTER_STATUS} command returned empty result...failed"
}


getGaleraStatus(){
  local node=$1
  local wsrep_cluster_status
  local status='ok'

  wsrep_cluster_status=$(galeraGetClusterStatus "${node}")
  if [[ ${wsrep_cluster_status} != "Primary" ]]; then
    status='failed'
    echo ${status}
    log "Galera node status is ${wsrep_cluster_status}...failed"
    return ${SUCCESS_CODE}
  fi
  echo ${status}
  log "[Node: ${node}]: Galera node status is ${wsrep_cluster_status}...ok";
}


setPrimaryWriteMode(){
  local node=$1
  mysqlCommandExec "unlock tables;" ${node}
}

restoreSecondaryPosition(){
  local node=$1
  source ${REPLICATION_INFO};
  rm -f ${REPLICATION_INFO}
  mysqlCommandExec "${STOP_SLAVE}; ${RESET_SLAVE}; ${CHANGE_MASTER} TO ${MASTER_HOST}='${ReportHost}', ${MASTER_USER}='${ReplicaUser}', ${MASTER_PASSWORD}='${ReplicaPassword}', ${MASTER_LOG_FILE}='${File}', ${MASTER_LOG_POS}=${Position}; ${START_SLAVE};" ${node}
  
  local plugin="$(getUserAuthPlugin ${node} ${ReplicaUser})"
  if [[ x$plugin == *"caching_sha2_password"* ]]; then
    mysqlCommandExec "${STOP_SLAVE}; ${CHANGE_MASTER} TO ${GET_MASTER_PUBLIC_KEY}=1; ${START_SLAVE};" ${node}
  fi
}

getMysqlServerName(){
  local serverName
  local mysql_version=$(mysqld --version)

  if [[ $mysql_version == *"MySQL"* ]]; then
    serverName=mysql
  elif [[ $mysql_version == *"Percona"* ]]; then
    serverName=percona
  else
    serverName=mariadb
  fi  
  echo $serverName
}

restoreMultiSecondaryPosition(){
  local node=$1
  local primNane=$2
  local serverName="$(getMysqlServerName)"
  local plugin="$(getUserAuthPlugin ${node} ${ReplicaUser})"
  source ${REPLICATION_INFO};
  rm -f ${REPLICATION_INFO}
  if [[ "${serverName}" == "mariadb" ]]; then
    mysqlCommandExec "${CHANGE_MASTER} '${MasterName}' TO ${MASTER_HOST}='${ReportHost}', ${MASTER_USER}='${ReplicaUser}', ${MASTER_PASSWORD}='${ReplicaPassword}', ${MASTER_LOG_FILE}='${File}', ${MASTER_LOG_POS}=${Position};" ${node}
    if [[ x$plugin == *"caching_sha2_password"* ]]; then
      mysqlCommandExec "${CHANGE_MASTER} '${MasterName}' TO ${GET_MASTER_PUBLIC_KEY}=1;" ${node}
    fi
  else
    mysqlCommandExec "${CHANGE_MASTER} TO ${MASTER_HOST}='${ReportHost}', ${MASTER_USER}='${ReplicaUser}', ${MASTER_PASSWORD}='${ReplicaPassword}', ${MASTER_LOG_FILE}='${File}', ${MASTER_LOG_POS}=${Position} FOR CHANNEL '${primNane}';" ${node}
    if [[ x$plugin == *"caching_sha2_password"* ]]; then
      mysqlCommandExec "${CHANGE_MASTER} TO ${GET_MASTER_PUBLIC_KEY}=1 FOR CHANNEL '${primNane}';" ${node}
    fi
  fi
}

stopAllSlaves(){
  local node=$1
  local serverName="$(getMysqlServerName)"
  if [[ "${serverName}" == "mariadb" ]]; then
    mysqlCommandExec "${STOP_ALL_SLAVES}; ${RESET_SLAVE_ALL};" ${node}
  else
    mysqlCommandExec "${STOP_SLAVE}; ${RESET_SLAVE_ALL};" ${node}
  fi
}

startAllSlaves(){
  local node=$1
  local serverName="$(getMysqlServerName)"
  if [[ "${serverName}" == "mariadb" ]]; then
    mysqlCommandExec "${START_ALL_SLAVES};" ${node}
  else
    mysqlCommandExec "${START_SLAVE};" ${node}
  fi
}


checkMysqlServiceStatus(){
  local node=$1
  stderr=$( { timeout 20 mysqladmin -u${MYSQL_USER} -p${MYSQL_PASSWORD} -h ${node} status; } 2>&1 ) || {
    log "[Node: ${node}]: MySQL Service down...failed\n==============ERROR==================\n${stderr}\n============END ERROR================";
    echo "down"
    return ${FAIL_CODE}
  }
  log "[Node: ${node}]: MySQL Service up...ok"
  echo "up"
}


galeraCheckClusterSize(){
  local nodes_count_in_conf
  local nodes_count_status

  nodes_count_in_conf=$(grep wsrep_cluster_address ${GALERA_CONF} |awk -F '/' '{print $3}'| tr ',' ' ' | wc -w)
  [[ "${nodes_count_in_conf}" == "0" ]] && { echo 'failed'; log "Can't detect galera hosts in ${GALERA_CONF}"; return ${FAIL_CODE}; }
  nodes_count_status=$(mysqlCommandExec "show global status like 'wsrep_cluster_size'\G;" localhost|grep -i value|awk -F ':' '{print $2}'|xargs)
  if [[ "${nodes_count_in_conf}" != "${nodes_count_status}" ]]; then
    echo "failed"
    log "[Node: localhost]: Galera cluster size check failed, wsrep_cluster_size=${nodes_count_status}, that is lower then physical nodes count: ${nodes_count_in_conf}...failed"
    return ${SUCCESS_CODE}
  fi
  echo "ok"
  log "[Node: localhost]: Galera cluster size...ok"
}


stopMysqlService(){
  local node=$1

  local command="${SSH} ${node} \"/usr/bin/jem service stop\""
  local message="[Node: ${node}]: Stop MySQL service"
  execSshAction "$command" "$message" || return ${FAIL_CODE}

  command="${SSH} ${node} \"pkill 'mariadb|mysql|mysqld'\"|| exit 0"
  message="[Node: ${node}]: Detect and kill non closed mysql process"
  execSshAction "$command" "$message"
}


startMysqlService(){
  local node=$1
  local command="${SSH} ${node} \"/usr/bin/jem service start\""
  local message="[Node: ${node}]: Start MySQL service"
  execSshAction "$command" "$message"
}

checkMysqlOperable(){
  local node=$1
  for retry in $(seq 1 10)
  do
    stderr=$( { mysqlCommandExec "exit" "${node}"; } 2>&1 ) && return ${SUCCESS_CODE}
    log "[Node: ${node}]: [Retry: ${retry}/10] MySQL service operable check...waiting"
    sleep 5
  done
  echo -e ${stderr}
  return ${FAIL_CODE}
}

galeraSetBootstrap(){
  local node=$1
  local num=$2
  local command="${SSH} ${node} \"[[ -f /var/lib/mysql/grastate.dat ]] && { sed -i 's/safe_to_bootstrap.*/safe_to_bootstrap: ${num}/g' /var/lib/mysql/grastate.dat; } || { exit 0; }\""  
  local message="[Node: ${node}] Set safe_to_bootstrap: ${num}"
  execSshAction "$command" "$message"
}


galeraFixWithActivePrimary(){
  local nodes_to_fix=("$@")
  for node in "${nodes_to_fix[@]}"
  do
      [[ "${node}" == "${NODE_ADDRESS}" ]] && node="localhost"
      stopMysqlService "${node}"
      galeraSetBootstrap "${node}" 0
      startMysqlService "${node}"
  done
}


galeraGetClusterStatus(){
  local node=$1
  local wsrep_cluster_status='undefined'

  service_status=$(checkMysqlServiceStatus "${node}")
  if [[ ${service_status} == "up" ]]; then
    wsrep_cluster_status=$(mysqlCommandExec "show global status like 'wsrep_cluster_status'\G;" "${node}" |grep -i value|awk -F ':' '{print $2}'|xargs)
    log "[Node: ${node}]: wsrep_cluster_status=${wsrep_cluster_status}"
  else
    log "[Node: ${node}]: Can't define wsrep_cluster_status, mysql service is down"
  fi

  echo "${wsrep_cluster_status}"
}


galeraGetPrimaryNode(){
  local nodes_to_fix=("$@")
  local seq_num=0
  local primary_node='undefined'
  local primary_node_by_seq
  local serverName="$(getMysqlServerName)"
  local wsrep_recover_log='/tmp/wsrep_recover.log'
  for node in "${nodes_to_fix[@]}"
  do
      [[ "${node}" == "${NODE_ADDRESS}" ]] && node="localhost"
      command="${SSH} ${node} 'grep safe_to_bootstrap /var/lib/mysql/grastate.dat'"
      safe_bootstrap=$(execSshReturn "$command" "[Node: ${node}]: Get safe_to_bootstrap"|awk -F : '{print $2}'|xargs )
      log "[Node: ${node}]: safe_to_bootstrap=${safe_bootstrap}"
      if [[ ${safe_bootstrap} == 1 ]]; then
        primary_node="${node}"
        stopMysqlService "${node}"
      else
        stopMysqlService "${node}"
        [[ ${primary_node} == 'undefined' ]] || continue
 
        if [[ "${serverName}" == "mariadb" ]]; then
          command="${SSH} ${node} 'mysqld --wsrep-recover --log-error=${wsrep_recover_log} > /dev/null 2>&1 && tail -2 ${wsrep_recover_log} |grep \"Recovered position\"'"
        else
          command="${SSH} ${node} 'mysqld --wsrep-recover --user=root --log-error=${wsrep_recover_log} > /dev/null 2>&1 && tail -2 ${wsrep_recover_log} |grep \"Recovered position\"'"
        fi
        cur_seq_num=$(execSshReturn "$command" "[Node: ${node}]: Get seqno"|awk -F 'Recovered position:' '{print $2}'|awk -F : '{print $2}' )
        [[ -f ${wsrep_recover_log} ]] && rm -f ${wsrep_recover_log}
	log "[Node: ${node}]: seqno=${cur_seq_num}"
      fi

      if [[ "${seq_num}" -lt "${cur_seq_num}" ]]; then
        primary_node_by_seq=${node}
        seq_num=${cur_seq_num}
      fi
  done

  [[ ${primary_node} == 'undefined' ]] && primary_node=${primary_node_by_seq}
  log "[Node: ${primary_node}]: Set as primary...done"
  echo "${primary_node}"
}

galeraMyisamCheck(){
  local node=$1
  local sql="SELECT CONCAT(table_schema,'.',table_name) as MyISAM_Db_Tables FROM information_schema.tables WHERE engine='MyISAM' AND table_schema NOT IN ('information_schema','mysql','performance_schema');"
  stdout=$( { mysqlCommandExec "${sql}" "${node}"; } 2>&1 ) || { log "${stdout}"; return ${FAIL_CODE}; }
  if [[ -z ${stdout} ]]; then
    log "[Node: ${node}]: MyISAM tables not found...ok"
    echo "ok"
  else
    log "[Node: ${node}]: MyISAM tables exist...warning\n==============WARNING==================\n${stdout}\n============END WARNING================";
    echo "warning"
  fi
  return ${SUCCESS_CODE}
}


getGaleraNodes(){
  local list_nodes=''
  list_nodes=$(grep wsrep_cluster_address ${GALERA_CONF} | awk -F '/' '{print $3}' | xargs -d ',')
  [[ -z "${list_nodes}" ]] && { log "Can't detect galera hosts in ${GALERA_CONF}"; return ${FAIL_CODE}; }
  echo "${list_nodes}"
}


galeraFix(){
  local primary_nodes=()
  local nodes_to_fix=()
  local primary_node

  local list_nodes=$(getGaleraNodes) || return ${FAIL_CODE}
  
  for node in ${list_nodes}; do
    [[ "${node}" == "${NODE_ADDRESS}" ]] && node="localhost"
    wsrep_cluster_status=$(galeraGetClusterStatus ${node})
    [[ ${wsrep_cluster_status} == "Primary" ]] && primary_nodes+=("${node}") || nodes_to_fix+=("${node}")
  done

  if [[ ${#primary_nodes[@]} == 0 ]]; then
    primary_node=$(galeraGetPrimaryNode "${nodes_to_fix[@]}")
    galeraSetBootstrap "${primary_node}" 1
    startMysqlService ${primary_node}
    galeraFixWithActivePrimary ${nodes_to_fix[@]/$primary_node}
  else
    galeraFixWithActivePrimary ${nodes_to_fix[@]}
  fi
}

galeraRecoverFromDonor() {
  local donor_ip="$1"
  local list_nodes=$(getGaleraNodes) || return ${FAIL_CODE}

  if [[ ! " ${list_nodes} " =~ (^|[[:space:]])"${donor_ip}"($|[[:space:]]) ]]; then
    log "Donor IP '${donor_ip}' is not part of the Galera nodes!"
    return ${FAIL_CODE}
  fi

  for node in ${list_nodes}; do
    if [[ "${node}" == "${donor_ip}" || "${node}" == "${NODE_ADDRESS}" ]]; then
      log "[Node: ${node}]: Skipping donor node (${donor_ip})."
      continue
    fi

    log "[Node: ${node}]: Stopping MySQL service..."
    stopMysqlService "${node}"

    log "[Node: ${node}]: Removing grastate.dat..."
    local command="${SSH} ${node} 'rm -f /var/lib/mysql/grastate.dat'"
    execSshReturn "$command" "[Node: ${node}]: Remove grastate.dat"
  done
  
  for node in ${list_nodes}; do
    if [[ "${node}" == "${donor_ip}" || "${node}" == "${NODE_ADDRESS}" ]]; then
      log "[Node: ${node}]: Skipping donor node (${donor_ip})."
      continue
    fi
    log "[Node: ${node}]: Starting MySQL service..."
    startMysqlService "${node}"
  done
  
  log "Cluster recovery using donor node '${donor_ip}' is complete."
}


diagnosticResponse(){
  local result=$1
  local node_type=$2
  local service_status=$3
  local status=$4
  local galera_size_status=$5
  local galera_myisam=$6
  local error=$7
  response=$( jq -cn \
                  --argjson  result "$result" \
                  --arg node_type "$node_type" \
                  --arg address "${NODE_ADDRESS}" \
                  --arg service_status "$service_status" \
                  --arg status "$status" \
                  --arg galera_size "$galera_size_status" \
                  --arg galera_myisam "$galera_myisam" \
                  --arg error "$error" \
                  '{result: $result, node_type: $node_type, address: $address, service_status: $service_status, status: $status, galera_size: $galera_size, galera_myisam: $galera_myisam, error: $error}' )
  echo "${response}"
}

checkSelfRestoreLoop(){
  local error="Current node address:[${NODE_ADDRESS}] is the same as donor IP:[${DONOR_IP}]"

  if [[ "${NODE_ADDRESS}" == "${DONOR_IP}" ]]; then
    log "${error}"
    return ${FAIL_CODE}
  fi
  return ${SUCCESS_CODE}
}

nodeDiagnostic(){
  local node_type=''
  local service_status=''
  local status='failed'
  local galera_size_status=''
  local galera_myisam=''
  local result=0
  local error=''

  node_type=$(getNodeType) || {
    error='Current node does not have master.cnf,slave.cnf or galera.cnf'
    result=${FAIL_CODE}
    diagnosticResponse "$result" "$node_type" "$service_status" "$status" "$galera_size_status" "$galera_myisam" "$error"
    log "${error}"
    return ${SUCCESS_CODE}
  }
  log "[Node: localhost]: Detected node type: ${node_type}...done"

  service_status=$(checkMysqlServiceStatus 'localhost') || {
      diagnosticResponse "$result" "$node_type" "$service_status" "$status" "$galera_size_status" "$galera_myisam" "$error"
      return ${SUCCESS_CODE};
  }
  
  if [[ "${node_type}" == "secondary" ]] && [[ "${service_status}" == "up" ]]; then
    status=$(getSecondaryStatus "localhost")
  elif [[ "${node_type}" == "primary" ]] && [[ "${service_status}" == "up" ]]; then
    status=$(getPrimaryStatus "localhost")
  elif [[ "${node_type}" == "galera" ]] && [[ "${service_status}" == "up" ]]; then
    galera_size_status=$(galeraCheckClusterSize) || { result=${FAIL_CODE}; error="Can't detect galera hosts in ${GALERA_CONF}"; }
    status=$(getGaleraStatus "localhost")
    galera_myisam=$(galeraMyisamCheck "localhost")
  fi
  diagnosticResponse "$result" "$node_type" "$service_status" "$status" "$galera_size_status" "$galera_myisam" "$error"
}

restore_secondary_from_primary(){
  execAction "checkAuth" 'Authentication check'
  stopMysqlService "localhost"
  execAction "cleanSyncData ${DONOR_IP}" "[Node: localhost] Sync data from donor ${DONOR_IP} with delete flag"
  execAction "setPrimaryReadonly ${DONOR_IP}" "[Node: ${DONOR_IP}] Set primary readonly"
  execAction "resyncData ${DONOR_IP}" "[Node: localhost] Resync data after donor ${DONOR_IP} lock"
  execAction "setPrimaryWriteMode ${DONOR_IP}" "[Node: ${DONOR_IP}] Set donor to read write mode"
  startMysqlService "localhost"
  execAction "checkMysqlOperable localhost" "[Node: localhost] Mysql service operable check"
  if [[ -n "${ADDITIONAL_PRIMARY}" ]]; then
    execAction "stopAllSlaves localhost" '[Node: localhost] Stop all slaves'
    execAction "getPrimaryPosition ${DONOR_IP} PRIM1" "[Node: ${DONOR_IP}] Get primary PRIM1 position"
    execAction 'restoreMultiSecondaryPosition localhost PRIM1' '[Node: localhost] Restore primary PRIM1 position on self node'
    execAction "getPrimaryPosition ${ADDITIONAL_PRIMARY} PRIM2" "[Node: ${ADDITIONAL_PRIMARY}] Get primary PRIM2 position"
    execAction 'restoreMultiSecondaryPosition localhost PRIM2' '[Node: localhost] Restore primary PRIM2 position on self node'
    execAction "startAllSlaves localhost" '[Node: localhost] Start all slaves'
  else
    execAction "getPrimaryPosition ${DONOR_IP}" "[Node: ${DONOR_IP}] Get primary position"
    execAction 'restoreSecondaryPosition localhost' '[Node: localhost] Restore primary position on self node'
  fi
}

restore_primary_from_secondary(){
  execAction "checkAuth" 'Authentication check'
  stopMysqlService "localhost"
  execAction "cleanSyncData ${DONOR_IP}" "[Node: localhost]: Sync data from donor ${DONOR_IP} with delete flag"
  stopMysqlService "${DONOR_IP}"
  execAction "resyncData ${DONOR_IP}" "[Node: localhost]: Resync data after donor ${DONOR_IP} service stop"
  startMysqlService "localhost"
  execAction "checkMysqlOperable localhost" "[Node: localhost]: Mysql service operable check"
  startMysqlService "${DONOR_IP}"
  execAction "checkMysqlOperable ${DONOR_IP}" "[Node: ${DONOR_IP}]: Mysql service operable check"
  execAction "getPrimaryPosition localhost" '[Node: localhost]: Get primary position'
  execAction "removeSecondaryFromPrimary localhost" '[Node: localhost]: Disable secondary'
  execAction "restoreSecondaryPosition ${DONOR_IP}" "[Node: ${DONOR_IP}]: Restore primary position on donor"
}

configure_node_as_primary(){
  nodeType=$(getNodeType)
  if [[ "x${nodeType}" == "xsecondary" ]]; then
    cp ${SECONDARY_CONF} ${SECONDARY_CONF}.backup
    mv ${SECONDARY_CONF} ${PRIMARY_CONF}
    grep -q "binlog_format" ${PRIMARY_CONF} && { sed -i "s/binlog_format.*/binlog_format = mixed/" ${PRIMARY_CONF}; } || { echo "binlog_format = mixed" >> ${PRIMARY_CONF}; }
    grep -q "log-bin" ${PRIMARY_CONF} && { sed -i "s/log-bin.*/log-bin = mysql-bin/" ${PRIMARY_CONF}; } || { echo "log-bin = mysql-bin" >> ${PRIMARY_CONF}; }
    grep -q "log-slave-updates" ${PRIMARY_CONF} && { sed -i "s/log-slave-updates.*/log-slave-updates = OFF/" ${PRIMARY_CONF}; } || { echo "log-slave-updates = OFF" >> ${PRIMARY_CONF}; }
    grep -q "read_only" ${PRIMARY_CONF} && { sed -i "s/read_only.*/read_only = 0/" ${PRIMARY_CONF}; } || { echo "read_only = 0" >> ${PRIMARY_CONF}; }
    execAction "removeSecondaryFromPrimary localhost" '[Node: localhost]: Disable secondary'
    stopMysqlService "localhost"
    startMysqlService "localhost"
    return ${SUCCESS_CODE}
  else
    log "[Node: localhost]: This node cant be configured as primary"
    return ${FAIL_CODE}
  fi
}

promote_new_primary(){
  execAction "configure_node_as_primary" '[Node: localhost]: Configure node as Primary'
}

restore_primary_from_primary(){
  restore_secondary_from_primary
  execAction "getPrimaryPosition localhost" '[Node: localhost]: Get self primary position'
  execAction "restoreSecondaryPosition ${DONOR_IP}" "[Node: ${DONOR_IP}]: Restore primary position on donor"
}

restore_galera(){
  execAction 'checkAuth' 'Authentication check'
  if [[ "${DONOR_IP}" == "galera" ]]; then
    galeraFix
  else
    galeraRecoverFromDonor "${DONOR_IP}"
  fi
}

init(){
  execAction 'checkAuth' 'Authentication check'
  execAction 'setReplicaUserFromEnv' 'Set replica user from environment variables'
}

liveMysqlCheck(){
  local databases
  local tables
  local hasCorrupts=0
  local retValue=0
  databases=$(mysqlNoTablesCommandExec 'SHOW DATABASES' 'localhost')
  log "[Node: localhost]: ##### Live check with mysqlcheck utility #####";
  for db in ${databases};
  do
    log "[Node: localhost]: Checking database [$db]...progress";
    tables=$(mysqlNoTablesCommandExec "use $db;show tables" 'localhost')
    [[ -z "${tables}" ]] && { log "[Node: localhost]: Database [$db] have no tables...skipped"; continue; }
    hasCorrupts=0
    for tb in ${tables};
      do
        stderr=$( { mysqlcheck -u${REPLICA_USER} -p${REPLICA_PSWD} -c $db $tb; } 2>&1 )
	      if [[ "x$(echo -e $stderr |grep -iE 'error +: +Corrupt')" != "x" ]]; then
          echo -e "${db}.${tb}\n${stderr}"
          log "[Node: localhost]: Checking ${db}.${tb}...failed";
          hasCorrupts=1
          retValue=1
        fi
    done;
    [[ $hasCorrupts == 0 ]] && log "[Node: localhost]: Checking database [$db]...ok" || log "[Node: localhost]: Checking database [$db]...failed"
  done;
  return ${hasCorrupts}
}

offlineMysqlCheck(){
  local retValue=0
  log "[Node: localhost]: ##### Offline check with innochecksum utility #####";
  stopMysqlService "localhost"
  for dbdFile in $(find /var/lib/mysql -name "*.ibd" | sort -h);
  do
    stderr=$( { innochecksum ${dbdFile}; } 2>&1 ) || {
      echo -e "File: ${dbdFile}\n${stderr}"
      log "[Node: localhost]: Checking ${dbdFile}...failed";
      retValue=1
    }
  done;
  startMysqlService "localhost"
  return ${retValue}
}

nodeCorruptionCheck(){
  execAction 'liveMysqlCheck' 'Online corruption check'
  execAction 'offlineMysqlCheck' 'Offile corruption check'
  execResponse "0" ""
}

which jq >/dev/null 2>&1 || { yum -q -y --disablerepo='*' --enablerepo='epel' install jq >/dev/null 2>&1 || echo '{"result":99,"scenario":"init","address":"","error":"Install jq utility failed"}'; }

if [[ "${diagnostic}" == "YES" ]]; then
  log ">>>BEGIN DIAGNOSTIC"
  execAction "checkAuth" 'Authentication check'
  nodeDiagnostic
  log ">>>END DIAGNOSTIC"
elif [[ "${check_corrupts}" == "YES" ]]; then
  log ">>>BEGIN CORRUPTION CHECK"
  execAction "checkAuth" 'Authentication check'
  nodeCorruptionCheck
  log ">>>END CORRUPTION CHECK"
else
  log ">>>BEGIN RESTORE SCENARIO [${SCENARIO}]"
  if [[ "${SCENARIO}" != "restore_galera" ]]; then
    execAction "checkSelfRestoreLoop" 'Check Self Restore Loop'
  fi
  $SCENARIO
  sleep 10
  nodeDiagnostic
  log ">>>END RESTORE SCENARIO [${SCENARIO}]"
fi
