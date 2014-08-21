#!/usr/bin/env bash

############################################################################################
# MySQL Maint : A bash script that performs backups and maintenance on your MySQL servers. #
#                                                                                          #
# Copyright (C) 2009-2013  Maxime Mérian <maxime.merian@gmail.com>                         #
#                                                                                          #
# This program is free software: you can redistribute it and/or modify                     #
# it under the terms of the GNU General Public License as published by                     #
# the Free Software Foundation, either version 3 of the License, or                        #
# (at your option) any later version.                                                      #
#                                                                                          #
# This program is distributed in the hope that it will be useful,                          #
# but WITHOUT ANY WARRANTY; without even the implied warranty of                           #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                            #
# GNU General Public License for more details.                                             #
#                                                                                          #
# You should have received a copy of the GNU General Public License                        #
# along with this program.  If not, see <http://www.gnu.org/licenses/>.                    #
############################################################################################

##############################################################
# Edit configuration variables in the code,                  #
# or override them with command-line options                 #
#                                                            #
# The script performs 4 different backups :                  #
#                                                            #
# - current : performed each time the script is started      #
# - daily : performed once a day                             #
# - weekly : performed one a week (weekday configurable)     #
# - monthly : performed once a month (monthday configurable) #
##############################################################

###############################
# Part 1 : Script parameters  #
###############################

#################################
# Server connection settings    #
#                               #
# Change these settings to suit #
# your server configuration     #
#################################
DB_HOST=127.0.0.1
DB_USER=root
DB_PASS=admin
DB_PORT=3306
DB_SOCKET=

# If we're running on a Debian family we can use the maintenance account.
if [[ -f /etc/mysql/debian.cnf && -r /etc/mysql/debian.cnf ]]; then
    DB_HOST=$(grep host /etc/mysql/debian.cnf | head -n1 | sed -r 's/^.+=\s*//')
    DB_USER=$(grep user /etc/mysql/debian.cnf | head -n1 | sed -r 's/^.+=\s*//')
    DB_PASS=$(grep password /etc/mysql/debian.cnf | head -n1 | sed -r 's/^.+=\s*//')
    DB_SOCKET=$(grep socket /etc/mysql/debian.cnf | head -n1 | sed -r 's/^.+=\s*//')
fi

# Weekly backup day
# (result of 'date %u')
DOW='7'

# Monthly backup day
# (result of 'date %d')
DOM='01'

# Backup folder
# /!\ Don't add a trailing slash
BACKUP_DIR="${HOME}/backup/mysql"

# Server name
# The backups will go to ${BACKUP_DIR}/${BACKUP_HOST_NAME}/<db-name>
# defaults to $DB_HOST
BACKUP_HOST_NAME=""

# Sould a copy of the latest backup be placed
# in $BACKUP_HOST_NAME/<db-name> ?
SAVE_LATEST=yes

# Should this copy be a symlink
# instead of a hard copy ?
LINK_LATEST=yes

# Backups lifetime.
# lifetimes are written in days,
# except the 'current' backups lifetime
# that is in minutes

# 'current'
DELETE_BACKUP_OLDER_THAN_MIN=1440
# 'daily'
D_DELETE_BACKUP_OLDER_THAN_DAYS=6
# 'weekly'
W_DELETE_BACKUP_OLDER_THAN_DAYS=30

# Dates format for naming backups
DATE_FORMAT="%Y-%m-%d_%H-%M" # current
D_DATE_FORMAT="%Y-%m-%d" # daily
W_DATE_FORMAT="%Y-%m-%d" # weekly
M_DATE_FORMAT="%Y-%m-%d" # monthly

# Backup folders names
CURRENT_FOLDER='01_current'
DAILY_FOLDER='02_daily'
WEEKLY_FOLDER='03_weekly'
MONTHLY_FOLDER='04_monthly'

# Database that souldn't be maintained
IGNORE_MAINTENANCE_DATABASES="mysql information_schema performance_schema"

# Databases that souldn't be backed up
IGNORE_BACKUP_DATABASES="information_schema mysql performance_schema"

# Databases that sould only be backed up / maintainted.
# Overrides prevous setting
ONLY_BACKUP_DATABASES=""
ONLY_MAINTAIN_DATABASES=""

# Enable logging ?
LOG=yes
LOG_FILE_BACKUP_NAME="backup.log"
LOG_FILE_MAINTENANCE_NAME="maintenance.log"
LOG_DATE_FORMAT='%b %d %H:%M:%S'
LOG_MAXSIZE=102400 # Log max size before rotation

# Temporary file used by the script
TEMP_FILE=/tmp/mysql_maint.tmp

# Should SQL errors be ignored (adds -f options to mysql commands) ?
IGNORE_SQL_ERRORS=no

# Should communications with the server be compressed (adds -c to mysql commands) ?
USE_COMPRESSION=yes

# Path
export PATH='/usr/local/bin:/usr/local/mysql/bin:/usr/bin:/bin'

MYSQL_BIN=mysql
MYSQLDUMP_BIN=mysqldump
SED_BIN=sed
GZIP_BIN=gzip
BZIP2_BIN=bzip2
DATE_BIN=date
FIND_BIN=find
RM_BIN=rm
LN_BIN=ln
CP_BIN=cp
MKDIR_BIN=mkdir
GREP_BIN=grep
CUT_BIN=cut
STAT_BIN=stat
CAT_BIN=cat

# Client version
MYSQL_CLIENT_VERSION=`${MYSQL_BIN} -V|${SED_BIN} -e 's/.*Distrib \([0-9.]*\).*/\1/'`

# Command line options
#
# Note :
# -f will be added if IGNORE_SQL_ERRORS is "yes"
# -C will be added if USE_COMPRESSION is "yes"
MYSQL_OPTS="-B -r -N"
MYSQLDUMP_OPTS="--opt --skip-comments"
if [ "${MYSQL_CLIENT_VERSION}" \> "5" ]; then
	MYSQLDUMP_OPTS="$MYSQLDUMP_OPTS --routines --triggers"
fi
RM_OPTS="-f"
LN_OPTS="-s"
CP_OPTS=""
MKDIR_OPTS="-p"
DATE_OPTS=""
GZIP_OPTS="-9"
BZIP2_OPTS="-9"

# Script pid file
# Will avoid concurrent script executions
PID_FILE="/tmp/mysql_maint.pid"

# Dave Null
TRASH="/dev/null"

# Configuration file
CONFIG_FILE=''

# What should the script do ?
# don't modify here, use -b (backup) or -m (maintenance) command-line options
DO_MAINTENANCE=0
DO_BACKUP=0

##############################
# Check if running GNU/Linux #
##############################
PLATFORM_IS_LINUX=yes
if [ -f '/proc/version' ]; then
    systemName="`cat /proc/version`"
else
    systemName="`uname -a`"
fi
linuxCheck="`expr "$systemName" : ".*\(Linux\).*"`"
if [ -z "$linuxCheck" ]; then
	# uname -a didn't return a string that contains 'Linux'
	PLATFORM_IS_LINUX=no
fi

#############################
# End of script parameters #
#############################

# Script version
VERSION="1.1"

# File that is being written by the script. Will be deleted
# on receiving SIGINT or SIGTERM, since it won't be valid
CURRENT_FILE=""
# Database being backed up / maintained
CURRENT_DATABASE=""

# Colorize output
ECHO_CMD="echo "
OK_COLOR=""
FAIL_COLOR=""
T_RESET=""
if [ -n "$BASH" ]; then
	OK_COLOR="\033[32m"
	FAIL_COLOR="\033[31m"
	T_RESET="\033[0m"

	ECHO_CMD()
	{
		echo -e $*
	}

	ECHO_OK()
	{
		ECHO_CMD "${OK_COLOR}$*${T_RESET}"
	}
	ECHO_FAIL()
	{
		ECHO_CMD "${FAIL_COLOR}$*${T_RESET}"
	}
else
	ECHO_CMD()
	{
		echo $*
	}
	ECHO_OK()
	{
		ECHO_CMD $*
	}
	ECHO_FAIL()
	{
		ECHO_CMD $*
	}
fi

###############
# Error codes #
###############
E_OK=0              # no error
E_PID_EXISTS=1      # pid file exists, script already running
E_CONNECT_FAILED=2  # unable to connect to MySQL Server
E_WRITE_PERM=3      # couldn't create a file/folder due to permissions
E_PARSE_CONFIG=4	# error parsing config file

################
# Trap signals #
################

####################################################
# Ends the script.                                 #
# optionnal argument : return code (defaults to 0) #
####################################################
end_script()
{
	local return_value=0
	if [ ! -z $1 ]; then
		return_value=$1
	fi

	if [ -n "$CURRENT_FILE" ]; then
		ECHO_CMD "${FAIL_COLOR}File $CURRENT_FILE was being written when signal received, deleting it.${T_RESET}"
		${RM} $CURRENT_FILE
	fi

	if [ -e ${TEMP_FILE} ]; then
		${RM} ${TEMP_FILE}
	fi

	if [ -e ${PID_FILE} ]; then
		${RM} $PID_FILE
	fi

	exit $return_value
}

trap_sigint()
{
	end_script $E_OK
}

trap_sigterm()
{
	end_script $E_OK
}

trap_exit()
{
	end_script $E_OK
}

#trap 'trap_sigint' SIGINT
#trap 'trap_sigterm' SIGTERM
trap 'trap_exit' EXIT

###########################
# Part 2 : Help functions #
###########################
print_usage()
{
	ECHO_OK "================================="
	ECHO_OK "== MySQL Maintainer ${VERSION} =="
	ECHO_OK "================================="
	echo ""
	echo "Usage : $0 <options>"
	echo ""
	echo "Command-line options override the script variables"
	echo ""
	echo "-b : Perform a backup"
	echo "-m : Perform maintenance"
	echo "-H [host] : IP address or DNS name of the MySQL server (default: 127.0.0.1)"
	echo "-u [login] : Login (default: root)"
	echo "-p [password] : Password (default: admin)"
	echo "-P [port] : MySQL port (default: 3306)"
	echo "-S [socket] : MySQL socket (default: no socket defined)"
	echo "-d [directory] : Backups folder (default: ${HOME}/backup/mysql)"
	echo "-n [name] : Backups folder for this server (defaults to server name)"
	echo "-l : Keep a copy of the latest backup for each database (default: yes)"
}

print_version()
{
	echo "MySQL Maintainer version ${VERSION}"
}

#########################################
# Part 3 : Process command-line options #
#########################################
while getopts "bmhvlH:S:u:p:P:d:n:c" option
do
	case $option in
		v)	# Version
			print_version
			exit $E_OK
			;;
		h)	# Help
			print_usage
			exit $E_OK
			;;
		c)	# Config file
			CONFIG_FILE=$OPTARG
			;;
		b)	# Backup
			DO_BACKUP=1
			;;
		m)	# Maintenance
			DO_MAINTENANCE=1
			;;
		H)	# Server
			DB_HOST=$OPTARG
			;;
		u)	# Login
			DB_USER=$OPTARG
			;;
		p)	# Password
			DB_PASS=$OPTARG
			;;
		S)	# Socket
			DB_SOCKET=$OPTARG
			;;
		P)	# Port
			DB_PORT=$OPTARG
			;;
		d)	# Backups folder
			BACKUP_DIR=$OPTARG
			;;
		n)	# Server folder name
			BACKUP_HOST_NAME=$OPTARG
			;;
		l)	# Keep a copy of the latest backup
			SAVE_LATEST=yes
			;;
	esac
done

# Parse config file if necessary
if [ -e "$CONFIG_FILE" -a -r "$CONFIG_FILE" ]; then
	source $CONFIG_FILE &> $TRASH
	if [ "0" -ne "$?" ]; then
		ECHO_FAIL "Failed to parse $CONFIG_FILE"
		end_script E_PARSE_CONFIG
	fi
fi

if [ -z ${BACKUP_HOST_NAME} ]; then
	BACKUP_HOST_NAME=$DB_HOST
fi

BACKUP_BASE=${BACKUP_DIR}/${BACKUP_HOST_NAME}

# IGNORE_SQL_ERRORS
if [ ${IGNORE_SQL_ERRORS} = "yes" ]; then
	MYSQL_OPTS="${MYSQL_OPTS} -f"
	MYSQLDUMP_OPTS="${MYSQLDUMP_OPTS} -f"
fi;

# USE_COMPRESSION
if [ ${USE_COMPRESSION} = "yes" ]; then
	MYSQL_OPTS="${MYSQL_OPTS} -C"
	MYSQLDUMP_OPTS="${MYSQLDUMP_OPTS} -C"
fi;

# Store MySQL password and port in environment variables
export MYSQL_PWD=${DB_PASS}
export MYSQL_TCP_PORT=${DB_PORT}

#IDENT_OPTS="-h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER} -p${DB_PASS}"
IDENT_OPTS=" -u ${DB_USER}"
if [ -n "${DB_SOCKET}" ]; then
	IDENT_OPTS="${IDENT_OPTS} --socket=${DB_SOCKET} "
else
    IDENT_OPTS="${IDENT_OPTS} -h ${DB_HOST} "
fi;

if [ -n "${DB_PASS}" ]; then
    IDENT_OPTS="${IDENT_OPTS} -p${DB_PASS} "
fi

MYSQL_OPTS="${MYSQL_OPTS} ${IDENT_OPTS}"
MYSQLDUMP_OPTS="${MYSQLDUMP_OPTS} ${IDENT_OPTS}"

# Shortcuts
MYSQL="${MYSQL_BIN} ${MYSQL_OPTS}"
MYSQLDUMP="${MYSQLDUMP_BIN} ${MYSQLDUMP_OPTS}"
RM="${RM_BIN} ${RM_OPTS}"
LN="${LN_BIN} ${LN_OPTS}"
CP="${CP_BIN} ${CP_OPTS}"
MKDIR="${MKDIR_BIN} ${MKDIR_OPTS}"
GREP="${GREP_BIN}"
CUT="${CUT_BIN}"
DATE="${DATE_BIN} ${DATE_OPTS}"
SED="${SED_BIN}"
CAT="${CAT_BIN}"
GZIP="${GZIP_BIN} ${GZIP_OPTS}"

# Use pbzip2 instead of bzip2
# if possible. The -c option
# asks pbzip2 to output to stdout.
type pbzip2 &> $TRASH
if [ "0" = "$?" ]; then
	BZIP2_BIN=pbzip2
	BZIP2_OPTS="$BZIP2_OPTS -c"
fi

BZIP2="${BZIP2_BIN} ${BZIP2_OPTS}"

#########################################
# Part 4 : Functions used by the script #
#########################################

################################
# Checks connection parameters #
################################
check_parameters()
{
	${MYSQL} -e "" &> ${TRASH}
	local retval=$?
	local str="Checking connection parameters..."
	if [ $retval -eq 0 ]; then
		str="${str} ${OK_COLOR}success :)${T_RESET}"
		ECHO_CMD "$str"
	else
		str="${str} ${FAIL_COLOR}failed :(${T_RESET}"
		ECHO_CMD "$str"
		ECHO_CMD "Unable to connect to ${DB_USER}@${DB_HOST}:${DB_PORT}"
		ECHO_CMD "Please check login/password/server/port"
		end_script $E_CONNECT_FAILED
	fi
}

#####################
# Logging functions #
#####################

#######################################################
# Returns the current folder where the logs should go #
#######################################################
log_folder()
{
	local log_folder="${BACKUP_DIR}/${BACKUP_HOST_NAME}"
	if [ ! -z "${CURRENT_DATABASE}" ]; then
		log_folder="${log_folder}/${CURRENT_DATABASE}"
	fi
	echo $log_folder
}

#######################################
# Returns the current backup log file #
#######################################
log_backup_file()
{
	echo "`log_folder`/${LOG_FILE_BACKUP_NAME}"
}

############################################
# Returns the current maintenance log file #
############################################
log_maintenance_file()
{
	echo "`log_folder`/${LOG_FILE_MAINTENANCE_NAME}"
}

############################
# Logs a message in a file #
#                          #
# $1 : log file            #
# $2 : message             #
############################
log_message()
{
	if [ $LOG = "yes" ]; then
		local log_file=$1
		local message=$2
		local log_date="`date +"${LOG_DATE_FORMAT}"`"

		if [ ! -e "$log_file" ]; then
			local log_file_folder=`dirname "$log_file"`
			if [ ! -e "${log_file_folder}" ]; then
				mkdir -p ${log_file_folder} 2> ${TRASH}
				local res=$?
				if [ "$res" != "0" ]; then
					ECHO_FAIL "unable to create ${log_file_folder}"
					end_script $E_WRITE_PERM
				fi
			fi
			echo > $1
		fi

		echo "${log_date} ${message}" >> $log_file
	fi
}

#########################
# Logs a backup message #
#                       #
# $1 : message          #
#########################
log_b()
{
	local message=$1
	log_message "`log_backup_file`" "${message}"
}

##############################
# Logs a maintenance message #
#                            #
# $1 : message               #
##############################
log_m()
{
	local message=$1
	log_message "`log_maintenance_file`" "${message}"
}

###########################
# Gets the server version #
###########################
server_version()
{
	echo `${MYSQL} -e "SELECT VERSION()"`
}

##############################################
# Checks if the MySQL server version is >= 5 #
##############################################
is_mysql_5()
{
	local sv=`server_version`
	if [ "${sv}" \< "5" ]; then
		return 1
	else
		return 0
	fi
}

###########################
# Lists all the databases #
###########################
show_all_databases()
{
	echo `${MYSQL} -e "SHOW DATABASES"`
}

##########################################################
# Gets the list of the databases that will be maintained #
##########################################################
show_maintenance_databases()
{
	if [ ! -z "${ONLY_MAINTAIN_DATABASES}" ]; then
		echo "${ONLY_MAINTAIN_DATABASES}"
	else
		local databases=`show_all_databases`
		local db=''
		for db in ${IGNORE_MAINTENANCE_DATABASES}; do
			databases=`echo ${databases}|${SED} "s/${db}//g"`
		done;
		echo $databases
	fi
}

#########################################################
# Gets the list of the databases that will be backed-up #
#########################################################
show_backup_databases()
{
	if [ ! -z "${ONLY_BACKUP_DATABASES}" ]; then
		echo "${ONLY_BACKUP_DATABASES}"
	else
		local databases=`show_all_databases`
		local db=''
		for db in ${IGNORE_BACKUP_DATABASES}; do
			databases=`echo ${databases}|${SED} "s/${db}//g"`
		done;
		echo $databases
	fi
}

##################################
# Lists all tables in a database #
#                                #
# $1 : database name             #
##################################
show_tables()
{
	local database=$1

	is_mysql_5
	if [ $? -eq 0 ]; then
		echo `${MYSQL} -e "SELECT TABLE_NAME FROM TABLES WHERE TABLE_SCHEMA = '${database}' AND TABLE_TYPE = 'BASE TABLE'" information_schema`
	else
		echo `${MYSQL} -e "SHOW TABLES" ${database}`
	fi
}

########################################################
# Quotes an identifier (a table name or database name) #
#                                                      #
# $1 : the identifier                                  #
########################################################
quote_identifier()
{
	echo '`'$1'`'
}

####################################
# Starts maintenance on a database #
# $1 : database name               #
####################################
db_maintenance()
{
	local database=$1
	log_m "Maintenance started on database ${database}"
	for i in `show_tables $database`; do
			local quotedTableName=`quote_identifier $i`
			local msg_text=`${MYSQL} -e "CHECK TABLE $quotedTableName" -E $1|${GREP} Msg_text |${CUT} -d' ' -f2`
			echo "	$i : ${msg_type} ...${msg_text}"
			local log_message="Checking table ${i}..."
			if [ "$msg_text" != "OK" ]; then
				log_message="${log_message} ${msg_text}"
				echo "		Repairing table $i"
				${MYSQL} -e "REPAIR TABLE $quotedTableName EXTENDED" $1 &> ${TRASH}
			else
				log_message="${log_message} OK"
			fi;
			log_m "${log_message}"
			log_m "Optimizing table $i"
			${MYSQL} -e "OPTIMIZE TABLE $quotedTableName" $1 > ${TRASH}

			log_m "Analyzing table $i"
			${MYSQL} -e "ANALYZE TABLE $quotedTableName" $1 > ${TRASH}
	done
	log_m "Maintenance complete on database ${database}"
}

###################################################################
# Performs maintenance on all databases that should be maintained #
###################################################################
do_maintenance()
{
	for db in `show_maintenance_databases`; do
		CURRENT_DATABASE=$db
		ECHO_OK "======== Maintenance started on database $db ========"
		db_maintenance $db
		rotate_maintenance_log
		CURRENT_DATABASE=""
	done;
}

######################
# Backup a database  #
# $1 : database name #
######################
db_backup()
{
	local database=$1
	log_b "Backup started on database ${database}"
	local dir=${BACKUP_BASE}/${database}
	ECHO_OK "======== Backing up database $database ========"
	# Create backup folder is necessary
	if [ ! -d $dir ]; then
		${MKDIR} $dir
	fi

	if [ ! -w $dir ]; then
		ECHO_FAIL "Unable to write to ${dir}. Cancelling backup for ${database}"
		end_script $E_WRITE_PERM
	fi

	local currentdir="${BACKUP_BASE}/${database}/${CURRENT_FOLDER}"
	local dailydir="${BACKUP_BASE}/${database}/${DAILY_FOLDER}"
	local weeklydir="${BACKUP_BASE}/${database}/${WEEKLY_FOLDER}"
	local monthlydir="${BACKUP_BASE}/${database}/${MONTHLY_FOLDER}"

	for i in $currentdir $dailydir $weeklydir $monthlydir; do
		if [ ! -d $i ]; then
			mkdir -p $i
		fi
	done

	local filename="${currentdir}/${database}_`${DATE} +"$DATE_FORMAT"`.sql.bz2"
	local dailyfile="${dailydir}/${database}_`${DATE} +"$D_DATE_FORMAT"`.sql.bz2"
	local weeklyfile="${weeklydir}/${database}_`${DATE} +"$W_DATE_FORMAT"`.sql.bz2"
	local monthlyfile="${monthlydir}/${database}_`${DATE} +"$M_DATE_FORMAT"`.sql.bz2"

	# current
	CURRENT_FILE=$filename
	${MYSQLDUMP} $db > ${TEMP_FILE} 2> ${TRASH}
	if [ "0" -eq "$?" ]; then
		cat ${TEMP_FILE}|${BZIP2} > $filename

		CURRENT_FILE=''

		local latest=${dir}/${database}.latest.sql.bz2

		# Delete old 'latest' copy
		if [ -e "$latest" ]; then
			${RM} $latest
		fi

		# Perform 'latest' copy if necessary
		if [ $SAVE_LATEST = "yes" ]; then
			CURRENT_FILE=$latest
			if [ $LINK_LATEST = "yes" ]; then
				${LN} $filename $latest
			else
				${CP} $filename $latest
			fi
			CURRENT_FILE=''
		fi

		# Daily backup
		if [ ! -e $dailyfile ]; then
			CURRENT_FILE=$dailyfile
			${CP} $filename $dailyfile
			CURRENT_FILE=''
		fi

		# Weekly backup
		if [ "`${DATE} +"%u"`" = "$DOW" ]; then
			if [ ! -e $weeklyfile ]; then
				CURRENT_FILE=$dailyfile
				${CP} $filename $weeklyfile
				CURRENT_FILE=''
			fi
		fi

		# Monthly backup
		if [ "`${DATE} +"%d"`" = "$DOM" ]; then
			if [ ! -e $monthlyfile ]; then
				CURRENT_FILE=$dailyfile
				${CP} $filename $monthlyfile
				CURRENT_FILE=''
			fi
		fi
		log_b "Backup completed on database ${database}"
		echo "	*** Deleting old backup of database ${database} ***"
		delete_old_backups $database
	else
		CURRENT_FILE=''
		ECHO_FAIL "An error occurred while backing up ${db}"
		log_b "An error occurred while backing up $db"
	fi
}

#################################################
# Backup all databases that should be backed up #
#################################################
do_backup()
{
	for db in `show_backup_databases`; do
		CURRENT_DATABASE=$db
		db_backup $db
		rotate_backup_log
		CURRENT_DATABASE=""
	done;
}

#######################
# Deletes old backups #
# $1 : database name  #
#######################
delete_old_backups()
{
	local database=$1
	local currentdir="${BACKUP_BASE}/${database}/${CURRENT_FOLDER}"
	local dailydir="${BACKUP_BASE}/${database}/${DAILY_FOLDER}"
	local weeklydir="${BACKUP_BASE}/${database}/${WEEKLY_FOLDER}"
	local monthlydir="${BACKUP_BASE}/${database}/${MONTHLY_FOLDER}"

	log_b "Deleting old backups on database ${database}"

	${FIND_BIN} ${currentdir} -name "*.sql.bz2" -mmin +${DELETE_BACKUP_OLDER_THAN_MIN} -type f -print -exec rm -f {} \;
	${FIND_BIN} ${dailydir} -name "*.sql.bz2" -mtime +${D_DELETE_BACKUP_OLDER_THAN_DAYS} -type f -print -exec rm -f {} \;
	${FIND_BIN} ${weeklydir} -name "*.sql.bz2" -mtime +${W_DELETE_BACKUP_OLDER_THAN_DAYS} -type f -print -exec rm -f {} \;
}


##############################
# Returns the size of a file #
##############################
sizeof_file()
{
	if [ "$PLATFORM_IS_LINUX" != "yes" ]; then
		eval "`${STAT_BIN} -s "$1"`"
		echo $st_size
	else
		echo `${STAT_BIN} -c%s "$1"`
	fi
}

#####################
# Rotates log files #
#####################
rotate_logs()
{
	if [ -e $1 ]; then
		local log_file=$1
		if [ `sizeof_file $1` -gt $LOG_MAXSIZE ]; then
			local logfiles=`ls ${log_file}*.gz 2> ${TRASH}`
			local lognum=0
			for logfile in $logfiles; do
				local current_log_num=`echo "${logfile}"|${SED} -e 's/^.*\.\([0-9]*\)\.gz$/\1/'`
				if [ "$current_log_num" -gt "$lognum" ]; then
					lognum=$current_log_num
				fi
			done
			lognum=$(($lognum + 1))
			${CAT} $log_file |${GZIP} > ${log_file}.${lognum}.gz
			${RM} $log_file
		fi
	fi
}

rotate_maintenance_log()
{
	rotate_logs "`log_maintenance_file`"
}

rotate_backup_log()
{
	rotate_logs "`log_backup_file`"
}

################################
# Start maintenance and backup #
################################
if [ -e $PID_FILE ]; then
	ECHO_FAIL "MySQL Maint is already running (pid `cat ${PID_FILE}`)."
	ECHO_FAIL "If it isn't please delete ${PID_FILE}"
	exit $E_PID_EXISTS
fi

echo $$ > $PID_FILE

check_parameters

running=0

if [ "$DO_MAINTENANCE" -eq "1" ]; then
	running=1
	echo "	*************************************"
	echo "	******** Maintenance started ********"
	echo "	*************************************"
	do_maintenance
fi

if [ "$DO_BACKUP" -eq "1" ]; then
	running=1
	echo "	********************************"
	echo "	******** Backup started ********"
	echo "	********************************"
	do_backup
fi

if [ "$running" -eq "0" ]; then
	echo "To perform backup, run $0 -b"
	echo "To perform maintenance, run $0 -m"
fi
